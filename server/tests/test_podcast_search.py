"""FT-655 (R-A93, block B-5): podcast search by title.

User types a title — server queries public podcast directory
(iTunes Search, keyless) and returns a list: title, author, feed URL,
cover image. Subscription uses the feed URL (different card).

The directory is external: response can be anything. Directory failure — single exception
without query text; "nothing found" — empty list. Query text is absent
from both logs and exceptions. httpx at INFO level logs entire request URL —
module raises its log level to WARNING itself, like `app/lastfm.py`.

Contract of `app/podcast_search.py` module:
- `await search(query, *, client, limit=20) -> list[FoundPodcast]`;
- `FoundPodcast(title, author, feed_url, image, episodes)`;
- `PodcastSearchUnavailable` — directory did not respond properly;
- constants `SEARCH_URL`, `MAX_QUERY = 200`, `MIN_QUERY = 2`, `MAX_LIMIT = 50`,
  `MAX_BYTES = 1 MiB`, `TIMEOUT_S`.
"""

from __future__ import annotations

import asyncio
import tracemalloc
import time
import gzip
import dataclasses
import json
import logging
from typing import Any

import httpx
import pytest

from app import podcast_search
from app.podcast_search import FoundPodcast, PodcastSearchUnavailable, search

SECRET_QUERY = "тайный запрос xyzzy"


def row(**over: Any) -> dict[str, Any]:
    base: dict[str, Any] = {
        "wrapperType": "track",
        "kind": "podcast",
        "collectionName": "Музыкальный подкаст",
        "artistName": "Автор",
        "feedUrl": "https://feeds.example.org/music.xml",
        "artworkUrl100": "https://is1-ssl.mzstatic.com/a/100x100bb.jpg",
        "artworkUrl600": "https://is1-ssl.mzstatic.com/a/600x600bb.jpg",
        "trackCount": 42,
    }
    base.update(over)
    return {k: v for k, v in base.items() if v is not ...}


class Directory:
    def __init__(self, rows: list[Any] | None = None, *, respond: Any = None) -> None:
        self.rows = rows if rows is not None else [row()]
        self.respond = respond
        self.requests: list[httpx.Request] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.respond is not None:
            return self.respond(request)
        return httpx.Response(
            200, json={"resultCount": len(self.rows), "results": self.rows}
        )


def run(query: str, directory: Directory, **kwargs: Any) -> list[FoundPodcast]:
    async def go() -> list[FoundPodcast]:
        async with httpx.AsyncClient(
            transport=httpx.MockTransport(directory)
        ) as client:
            return await search(query, client=client, **kwargs)

    return asyncio.run(go())


# --- query ----------------------------------------------------------------


def test_request_shape() -> None:
    directory = Directory()
    run("  рок   подкаст ", directory)
    (request,) = directory.requests
    assert request.method == "GET"
    assert (
        str(request.url).split("?")[0]
        == podcast_search.SEARCH_URL
        == "https://itunes.apple.com/search"
    )
    assert dict(request.url.params) == {
        "media": "podcast",
        "entity": "podcast",
        "term": "рок подкаст",
        "limit": "20",
    }


@pytest.mark.parametrize("query", ["", " ", "я", " a ", "\n\t"])
def test_too_short_query_asks_nobody(query: str) -> None:
    directory = Directory()
    assert run(query, directory) == []
    assert directory.requests == []


def test_two_letters_are_enough() -> None:
    directory = Directory()
    assert len(run("ab", directory)) == 1


def test_long_query_is_cut() -> None:
    directory = Directory()
    run("я" * 500, directory)
    assert (
        directory.requests[0].url.params["term"]
        == "я" * podcast_search.MAX_QUERY
        == "я" * 200
    )


@pytest.mark.parametrize(
    ("asked", "sent"), [(5, "5"), (0, "1"), (-3, "1"), (50, "50"), (999, "50")]
)
def test_limit_is_clamped(asked: int, sent: str) -> None:
    directory = Directory()
    run("рок", directory, limit=asked)
    assert directory.requests[0].url.params["limit"] == sent


def test_no_personal_headers_and_no_redirects() -> None:
    def moved(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            302, headers={"location": "https://evil.example.org/search"}
        )

    directory = Directory(respond=moved)
    with pytest.raises(PodcastSearchUnavailable):
        run("рок", directory)
    assert len(directory.requests) == 1
    headers = {k.lower() for k in directory.requests[0].headers}
    assert not headers & {
        "authorization",
        "cookie",
        "x-apertonodo-key",
        "x-forwarded-for",
    }


# --- response ----------------------------------------------------------------


def test_found_fields() -> None:
    (found,) = run(
        "рок",
        Directory([row(collectionName="  Мой \n подкаст ", artistName=" Кто-то ")]),
    )
    assert found == FoundPodcast(
        title="Мой подкаст",
        author="Кто-то",
        feed_url="https://feeds.example.org/music.xml",
        image="https://is1-ssl.mzstatic.com/a/600x600bb.jpg",
        episodes=42,
    )
    with pytest.raises(dataclasses.FrozenInstanceError):
        found.title = "x"  # type: ignore[misc]


def test_optional_fields_missing() -> None:
    (found,) = run(
        "рок",
        Directory(
            [row(artistName=..., artworkUrl600=..., artworkUrl100=..., trackCount=...)]
        ),
    )
    assert found.author == ""
    assert found.image is None
    assert found.episodes is None


def test_small_image_when_no_large_and_track_name_when_no_collection() -> None:
    (found,) = run(
        "рок",
        Directory([row(artworkUrl600=..., collectionName=..., trackName="По треку")]),
    )
    assert found.image == "https://is1-ssl.mzstatic.com/a/100x100bb.jpg"
    assert found.title == "По треку"


@pytest.mark.parametrize(
    "feed",
    [
        ...,
        None,
        "",
        17,
        ["https://x.org/f.xml"],
        "ftp://x.org/f.xml",
        "file:///etc/passwd",
        "//x.org/f.xml",
        "https:///f.xml",
        "https://user:pw@x.org/f.xml",
        "javascript:alert(1)",
    ],
)
def test_row_without_usable_feed_is_dropped(feed: Any) -> None:
    good = row(feedUrl="https://ok.example.org/f.xml", collectionName="Хороший")
    found = run("рок", Directory([row(feedUrl=feed), good]))
    assert [f.title for f in found] == ["Хороший"]


def test_http_feed_is_kept() -> None:
    (found,) = run("рок", Directory([row(feedUrl=" http://old.example.org/feed ")]))
    assert found.feed_url == "http://old.example.org/feed"


@pytest.mark.parametrize("title", [..., None, "", "   ", 5])
def test_row_without_title_is_dropped(title: Any) -> None:
    assert run("рок", Directory([row(collectionName=title)])) == []


@pytest.mark.parametrize("bad", [None, "строка", 7, ["x"], True])
def test_rows_of_wrong_type_are_skipped(bad: Any) -> None:
    found = run("рок", Directory([bad, row()]))
    assert len(found) == 1


@pytest.mark.parametrize(
    "image",
    [
        "http://plain.example.org/a.jpg",
        "data:image/png;base64,AAAA",
        "javascript:x",
        5,
        None,
    ],
)
def test_image_only_https(image: Any) -> None:
    (found,) = run("рок", Directory([row(artworkUrl600=image, artworkUrl100=image)]))
    assert found.image is None


@pytest.mark.parametrize("count", [0, -1, "42", 4.5, True, None, 10**9])
def test_bad_episode_count_is_unknown(count: Any) -> None:
    (found,) = run("рок", Directory([row(trackCount=count)]))
    assert found.episodes is None


def test_long_strings_are_cut() -> None:
    (found,) = run(
        "рок", Directory([row(collectionName="н" * 900, artistName="а" * 900)])
    )
    assert found.title == "н" * 500
    assert found.author == "а" * 500


def test_same_feed_twice_keeps_first_and_order_is_kept() -> None:
    rows = [
        row(collectionName="Первый", feedUrl="https://a.example.org/f"),
        row(collectionName="Повтор", feedUrl="https://a.example.org/f"),
        row(collectionName="Второй", feedUrl="https://b.example.org/f"),
    ]
    assert [f.title for f in run("рок", Directory(rows))] == ["Первый", "Второй"]


def test_no_more_than_limit_even_if_directory_sends_more() -> None:
    rows = [
        row(collectionName=f"П{n}", feedUrl=f"https://x.example.org/{n}")
        for n in range(30)
    ]
    found = run("рок", Directory(rows), limit=7)
    assert [f.title for f in found] == [f"П{n}" for n in range(7)]


def test_nothing_found_is_empty_list() -> None:
    assert run("рок", Directory([])) == []


# --- directory failure -------------------------------------------------------


@pytest.mark.parametrize("status", [204, 301, 400, 403, 404, 429, 500, 503])
def test_bad_status_is_unavailable(status: int) -> None:
    directory = Directory(
        respond=lambda request: httpx.Response(status, json={"results": [row()]})
    )
    with pytest.raises(PodcastSearchUnavailable):
        run("рок", directory)


@pytest.mark.parametrize(
    "body",
    [
        b"",
        b"<html>blocked</html>",
        b"[]",
        b'"results"',
        b"null",
        b'{"resultCount": 1}',
        b'{"results": {"0": {}}}',
        b'{"results": "many"}',
        b'{"results": [',
        b"\xff\xfe\x00",
        b"[" * 100_000,
    ],
)
def test_bad_body_is_unavailable(body: bytes) -> None:
    directory = Directory(respond=lambda request: httpx.Response(200, content=body))
    with pytest.raises(PodcastSearchUnavailable):
        run("рок", directory)


@pytest.mark.parametrize(
    "error",
    [
        httpx.ConnectError,
        httpx.ReadTimeout,
        httpx.RemoteProtocolError,
        httpx.ProxyError,
    ],
)
def test_network_failure_is_unavailable(error: type[httpx.HTTPError]) -> None:
    def fail(request: httpx.Request) -> httpx.Response:
        raise error(f"cannot reach {request.url}", request=request)

    with pytest.raises(PodcastSearchUnavailable):
        run("рок", Directory(respond=fail))


def test_body_over_limit_is_unavailable_and_not_read_whole() -> None:
    pulled = 0

    async def endless():  # noqa: ANN202
        nonlocal pulled
        yield b'{"results": ['
        while pulled < 64:
            pulled += 1
            yield b" " * (256 * 1024)

    directory = Directory(
        respond=lambda request: httpx.Response(200, content=endless())
    )
    with pytest.raises(PodcastSearchUnavailable):
        run("рок", directory)
    assert pulled <= 6, pulled


def test_body_exactly_at_limit_is_read() -> None:
    payload = json.dumps({"results": [row()]}).encode()
    padded = payload + b" " * (podcast_search.MAX_BYTES - len(payload))
    assert len(padded) == 1024 * 1024
    directory = Directory(respond=lambda request: httpx.Response(200, content=padded))
    assert len(run("рок", directory)) == 1


def test_timeout_is_set_and_short() -> None:
    directory = Directory()
    run("рок", directory)
    timeout = directory.requests[0].extensions["timeout"]
    assert timeout["connect"] == timeout["read"] == podcast_search.TIMEOUT_S
    assert 0 < podcast_search.TIMEOUT_S <= 10


def test_other_errors_are_not_swallowed() -> None:
    def fail(request: httpx.Request) -> httpx.Response:
        raise RuntimeError("bug")

    with pytest.raises(RuntimeError):
        run("рок", Directory(respond=fail))


# --- privacy -------------------------------------------------------------


def test_query_is_not_in_exception_or_log(caplog: pytest.LogCaptureFixture) -> None:
    def fail(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError(f"cannot reach {request.url}", request=request)

    caplog.set_level(logging.DEBUG)
    with pytest.raises(PodcastSearchUnavailable) as caught:
        run(SECRET_QUERY, Directory(respond=fail))
    error = caught.value
    chain = [
        error,
        error.__cause__,
        error.__context__ if not error.__suppress_context__ else None,
    ]
    for link in chain:
        if link is not None:
            assert "xyzzy" not in str(link) and "xyzzy" not in repr(link)
    assert error.__cause__ is None
    # `from None` only hides the previous exception from printing; it remains in
    # `__context__` along with request URL. It must not be there at all.
    assert error.__context__ is None
    assert "xyzzy" not in caplog.text

    caplog.clear()
    run(SECRET_QUERY, Directory())
    assert "xyzzy" not in caplog.text
    assert "Музыкальный" not in caplog.text


def test_module_reads_no_environment_and_writes_no_log() -> None:
    source = open(podcast_search.__file__, encoding="utf-8").read()
    for word in ("os.environ", "getenv", "logger.", "print(", "open("):
        assert word not in source, word


# --- added by lead during acceptance (second look, FT-655) ---


class Drip(httpx.AsyncByteStream):
    """Yields byte-by-byte without end: each chunk arrives fast, response never ends."""

    def __init__(self) -> None:
        self.sent = 0

    async def __aiter__(self) -> Any:
        while True:
            await asyncio.sleep(0.01)
            self.sent += 1
            yield b" "


def test_slow_drip_is_cut_by_one_deadline_for_the_whole_answer(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(podcast_search, "TIMEOUT_S", 0.2)
    drip = Drip()
    directory = Directory(respond=lambda request: httpx.Response(200, stream=drip))
    started = time.monotonic()

    async def guarded() -> None:
        async with httpx.AsyncClient(
            transport=httpx.MockTransport(directory)
        ) as client:
            # Test guard: without total timeout in module, search would never finish.
            await asyncio.wait_for(search("музыка", client=client), 5)

    with pytest.raises(PodcastSearchUnavailable) as caught:
        asyncio.run(guarded())
    assert time.monotonic() - started < 2
    assert drip.sent < 100
    assert caught.value.__context__ is None


@pytest.mark.parametrize(
    "query", ["ab\ud800", "\ud800\udfff\ud800", "a\x00\x00", "\x1b\x7f\u202e"]
)
def test_query_that_cannot_be_sent_is_cleaned_or_empty(query: str) -> None:
    directory = Directory()
    result = run(query, directory)
    if directory.requests:
        term = directory.requests[0].url.params["term"]
        assert term.isprintable()
        assert len(term) >= podcast_search.MIN_QUERY
    else:
        assert result == []


def test_control_characters_do_not_count_as_query_length() -> None:
    directory = Directory()
    assert run("a\x00\x00\u202e", directory) == []
    assert directory.requests == []


class Once(httpx.AsyncByteStream):
    def __init__(self, data: bytes) -> None:
        self.data = data

    async def __aiter__(self) -> Any:
        yield self.data


def test_packed_answer_is_not_asked_for_and_not_unpacked() -> None:
    packed = gzip.compress(b'{"results":[]}' + b" " * (64 * 1024 * 1024))
    assert len(packed) < podcast_search.MAX_BYTES
    # Stream specifically: httpx would unpack ready body itself in mock response.
    directory = Directory(
        respond=lambda request: httpx.Response(
            200, stream=Once(packed), headers={"content-encoding": "gzip"}
        )
    )
    tracemalloc.start()
    try:
        with pytest.raises(PodcastSearchUnavailable):
            run("музыка", directory)
        _, peak = tracemalloc.get_traced_memory()
    finally:
        tracemalloc.stop()
    assert directory.requests[0].headers["accept-encoding"] == "identity"
    assert peak < 16 * 1024 * 1024


@pytest.mark.parametrize(
    "url",
    [
        "https://feeds.example.org/a b.xml",
        "https://feeds.example.org/a\tb.xml",
        "https://feeds.example.org/a\nb.xml",
        "https://feeds.example.org/a\x00b.xml",
        "https://feeds.example.org/\u202eb.xml",
        "https://feeds.exa mple.org/a.xml",
        "https://feeds.example.org:99999/a.xml",
        "https://feeds.example.org:port/a.xml",
        "https://feeds.example.org\\a.xml",
        "https://feeds.example.org/" + "a" * 2100,
    ],
)
def test_feed_and_image_with_blanks_bad_port_or_huge_are_refused(url: str) -> None:
    assert run("музыка", Directory([row(feedUrl=url)])) == []
    [found] = run("музыка", Directory([row(artworkUrl600=url, artworkUrl100=...)]))
    assert found.image is None


def test_image_with_credentials_is_refused() -> None:
    [found] = run(
        "музыка",
        Directory(
            [row(artworkUrl600="https://u:p@cdn.example.org/a.jpg", artworkUrl100=...)]
        ),
    )
    assert found.image is None


def escaped(rows: list[Any]) -> Directory:
    # `json=` in httpx encodes in UTF-8 and crashes on lone surrogate by itself;
    # real response carries it as `\\ud800`.
    body = json.dumps({"results": rows})
    return Directory(respond=lambda request: httpx.Response(200, content=body))


def test_control_and_direction_characters_are_removed_from_names() -> None:
    [found] = run(
        "музыка",
        escaped(
            [row(collectionName="A\x1b[2J\u202eB\x00", artistName="\u200fКто\ud800")]
        ),
    )
    assert found.title == "A[2JB"
    assert found.author == "Кто"
    json.dumps(dataclasses.asdict(found), ensure_ascii=False).encode()
    assert (
        run("музыка", escaped([row(collectionName="\ud800\x00", trackName=...)])) == []
    )
