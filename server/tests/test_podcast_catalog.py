"""FT-688 (Р-A108 item 2): podcast catalog — categories and top.

Owner 08.10: "just a catalog where a person can choose any podcast interesting to them" — without "For you"
and "Editor's Choice". The server gets top podcasts from the same open directory as search (iTunes, without
an API key): top feed by country and category provides podcast IDs, and a second `lookup` request for these
IDs provides feed URLs and artwork. The response format is identical to `/v1/podcasts/search`.

Contract of the `app/podcast_catalog.py` module:
- constants `TOP_URL`, `LOOKUP_URL`, `TOP_LIMIT = 30`, `FRESH_S = 6 h`, `STALE_S = 24 h`, `MAX_KEYS = 200`,
  `DEFAULT_COUNTRY = "us"`; `Category(id, ru, en)`; `CATEGORIES` — 12 categories in constant order;
- `country_of(raw) -> str` — two lowercase latin letters, otherwise `"us"`;
- `await top(*, client, country, category) -> list[FoundPodcast]` — popularity order, without duplicates;
  unknown category — `ValueError` before request; directory error — `PodcastSearchUnavailable` (from
  `app.podcast_search`) without request URL inside;
- `TopCache(clock=)` with `await get(key, fetch)`: fresh <= 6 h does not query; after — queries, on failure
  returns stale up to 24 h; at most `MAX_KEYS` keys (oldest evicted);
- `install_podcast_catalog(app, *, client, clock=)`: `GET /v1/podcasts/categories`,
  `GET /v1/podcasts/top?category=&country=`; bad category — `400 invalid_request`; no client or
  directory silent — `503 podcast_search_unavailable`.

What the test does not prove: real directory is not called (iTunes response format verified by lead 08.10
with a single request); wiring in `main.py` and client in mobile app — lead.
"""

from __future__ import annotations

import asyncio
import gzip
import json
import logging
from typing import Any

import httpx
import pytest
from fastapi.testclient import TestClient

from app import podcast_catalog
from app.main import create_app
from app.podcast_catalog import (
    CATEGORIES,
    Category,
    TopCache,
    country_of,
    install_podcast_catalog,
    top,
)
from app.podcast_search import MAX_BYTES, FoundPodcast, PodcastSearchUnavailable

TITLE = "Тайный подкаст xyzzy"


def entry(raw_id: Any) -> dict[str, Any]:
    return {
        "im:name": {"label": "x"},
        "id": {"label": "u", "attributes": {"im:id": raw_id}},
    }


def rss(ids: list[Any]) -> dict[str, Any]:
    return {"feed": {"author": {}, "entry": [entry(i) for i in ids]}}


def found(raw_id: Any, **over: Any) -> dict[str, Any]:
    base: dict[str, Any] = {
        "wrapperType": "track",
        "kind": "podcast",
        "collectionId": raw_id,
        "trackId": raw_id,
        "collectionName": f"Подкаст {raw_id}",
        "artistName": "Автор",
        "feedUrl": f"https://feeds.example.org/{raw_id}.xml",
        "artworkUrl100": f"https://is1-ssl.mzstatic.com/{raw_id}/100x100bb.jpg",
        "artworkUrl600": f"https://is1-ssl.mzstatic.com/{raw_id}/600x600bb.jpg",
        "trackCount": 42,
    }
    base.update(over)
    return {k: v for k, v in base.items() if v is not ...}


class Directory:
    """Fake directory: top feed and `lookup`."""

    def __init__(
        self,
        ids: list[Any] | None = None,
        rows: list[Any] | None = None,
        *,
        top_body: Any = None,
        lookup_body: Any = None,
        respond: Any = None,
    ) -> None:
        self.ids = ids if ids is not None else ["101", "102", "103"]
        self.rows = rows
        self.top_body = top_body
        self.lookup_body = lookup_body
        self.respond = respond
        self.requests: list[httpx.Request] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.respond is not None:
            answer = self.respond(request)
            if answer is not None:
                return answer
        if "/rss/toppodcasts/" in request.url.path:
            body = self.top_body if self.top_body is not None else rss(self.ids)
            return httpx.Response(200, json=body)
        if self.lookup_body is not None:
            return httpx.Response(200, json=self.lookup_body)
        rows = (
            self.rows
            if self.rows is not None
            else [found(int(i)) for i in reversed(self.ids)]
        )
        return httpx.Response(200, json={"resultCount": len(rows), "results": rows})

    def tops(self) -> list[httpx.Request]:
        return [r for r in self.requests if "/rss/toppodcasts/" in r.url.path]

    def lookups(self) -> list[httpx.Request]:
        return [r for r in self.requests if r.url.path == "/lookup"]


def run(directory: Directory, **kwargs: Any) -> list[FoundPodcast]:
    kwargs.setdefault("country", "ru")
    kwargs.setdefault("category", 1533)

    async def go() -> list[FoundPodcast]:
        async with httpx.AsyncClient(
            transport=httpx.MockTransport(directory)
        ) as client:
            return await top(client=client, **kwargs)

    return asyncio.run(go())


def feeds(result: list[FoundPodcast]) -> list[str]:
    return [p.feed_url for p in result]


def url_of(raw_id: Any) -> str:
    return f"https://feeds.example.org/{raw_id}.xml"


# --- constants ----------------------------------------------------------------


def test_constants() -> None:
    assert podcast_catalog.TOP_URL == (
        "https://itunes.apple.com/{country}/rss/toppodcasts/limit={limit}{genre}/json"
    )
    assert podcast_catalog.LOOKUP_URL == "https://itunes.apple.com/lookup"
    assert podcast_catalog.TOP_LIMIT == 30
    assert podcast_catalog.FRESH_S == 6 * 3600
    assert podcast_catalog.STALE_S == 24 * 3600
    assert podcast_catalog.MAX_KEYS == 200
    assert podcast_catalog.DEFAULT_COUNTRY == "us"


def test_twelve_categories_in_a_fixed_order() -> None:
    assert CATEGORIES == (
        Category(1533, "Наука", "Science"),
        Category(1487, "История", "History"),
        Category(1324, "Общество и культура", "Society & Culture"),
        Category(1303, "Комедия", "Comedy"),
        Category(1304, "Образование", "Education"),
        Category(1318, "Технологии", "Technology"),
        Category(1321, "Бизнес", "Business"),
        Category(1512, "Здоровье", "Health & Fitness"),
        Category(1545, "Спорт", "Sports"),
        Category(1305, "Дети и семья", "Kids & Family"),
        Category(1483, "Художественные", "Fiction"),
        Category(1489, "Новости", "News"),
    )


def test_category_is_frozen() -> None:
    with pytest.raises(AttributeError):
        CATEGORIES[0].id = 1  # type: ignore[misc]


@pytest.mark.parametrize(
    ("raw", "want"),
    [
        ("ru", "ru"),
        ("us", "us"),
        ("de", "de"),
        ("RU", "us"),
        ("Ru", "us"),
        ("rus", "us"),
        ("r", "us"),
        ("", "us"),
        ("r1", "us"),
        ("р у", "us"),
        ("ру", "us"),
        ("ru\n", "us"),
        (" ru", "us"),
        (None, "us"),
        (7, "us"),
        (["ru"], "us"),
    ],
)
def test_country_of(raw: Any, want: str) -> None:
    assert country_of(raw) == want


# --- requests -----------------------------------------------------------------


def test_requests_shape() -> None:
    directory = Directory()
    run(directory, country="ru", category=1533)
    first, second = directory.requests
    assert first.method == "GET"
    assert str(first.url) == (
        "https://itunes.apple.com/ru/rss/toppodcasts/limit=30/genre=1533/json"
    )
    assert second.method == "GET"
    assert str(second.url).split("?")[0] == "https://itunes.apple.com/lookup"
    assert dict(second.url.params) == {
        "id": "101,102,103",
        "entity": "podcast",
        "country": "ru",
    }


def test_without_category_is_the_overall_top() -> None:
    directory = Directory()
    run(directory, category=None)
    assert str(directory.tops()[0].url) == (
        "https://itunes.apple.com/ru/rss/toppodcasts/limit=30/json"
    )


def test_bad_country_becomes_the_default() -> None:
    directory = Directory()
    run(directory, country="RUS")
    assert directory.tops()[0].url.path.startswith("/us/")
    assert directory.lookups()[0].url.params["country"] == "us"


@pytest.mark.parametrize("category", [0, 1, 1310, 9999, -1533])
def test_unknown_category_asks_nobody(category: int) -> None:
    directory = Directory()
    with pytest.raises(ValueError):
        run(directory, category=category)
    assert directory.requests == []


def test_compressed_answers_are_not_asked_for() -> None:
    directory = Directory()
    run(directory)
    for request in directory.requests:
        assert request.headers["accept-encoding"] == "identity"


# --- response -----------------------------------------------------------------


def test_result_is_what_lookup_gave_in_popularity_order() -> None:
    directory = Directory(ids=["101", "102", "103"])
    result = run(directory)
    assert result == [
        FoundPodcast(
            title=f"Подкаст {i}",
            author="Автор",
            feed_url=url_of(i),
            image=f"https://is1-ssl.mzstatic.com/{i}/600x600bb.jpg",
            episodes=42,
        )
        for i in (101, 102, 103)
    ]


def test_a_single_entry_is_not_a_list_in_the_feed() -> None:
    directory = Directory(ids=["555"], top_body={"feed": {"entry": entry("555")}})
    assert feeds(run(directory)) == [url_of(555)]


@pytest.mark.parametrize(
    "body",
    [{"feed": {}}, {"feed": {"entry": []}}, {"feed": {"author": {}}}],
)
def test_empty_top_is_empty_and_lookup_is_not_asked(body: Any) -> None:
    directory = Directory(top_body=body)
    assert run(directory) == []
    assert directory.lookups() == []


def test_repeated_and_broken_ids_are_dropped() -> None:
    directory = Directory(
        top_body={
            "feed": {
                "entry": [
                    entry("101"),
                    entry("101"),
                    entry("abc"),
                    entry(""),
                    entry(102),
                    entry("1" * 13),
                    entry("-5"),
                    entry("１２"),
                    {"id": "no attributes"},
                    {"nothing": 1},
                    "not a dict",
                    entry("103"),
                ]
            }
        },
        rows=[found(101), found(103)],
    )
    assert feeds(run(directory)) == [url_of(101), url_of(103)]
    assert directory.lookups()[0].url.params["id"] == "101,103"


def test_twelve_digit_id_is_still_an_id() -> None:
    big = "9" * 12
    directory = Directory(ids=[big], rows=[found(int(big))])
    assert feeds(run(directory)) == [url_of(int(big))]


def test_no_more_than_the_limit_of_ids_is_looked_up() -> None:
    ids = [str(1000 + i) for i in range(45)]
    directory = Directory(ids=ids, rows=[found(int(i)) for i in ids])
    result = run(directory)
    assert len(result) == 30
    assert directory.lookups()[0].url.params["id"] == ",".join(ids[:30])


def test_rows_the_top_did_not_name_are_ignored() -> None:
    directory = Directory(ids=["101"], rows=[found(999), found(101)])
    assert feeds(run(directory)) == [url_of(101)]


@pytest.mark.parametrize(
    "bad",
    [
        {"collectionId": ...},
        {"collectionId": "101"},
        {"collectionId": 101.0},
        {"collectionId": True},
        {"feedUrl": ...},
        {"feedUrl": "ftp://feeds.example.org/a.xml"},
        {"feedUrl": "javascript:alert(1)"},
        {"feedUrl": "https://user@feeds.example.org/a.xml"},
        {"feedUrl": "https://feeds.example.org/a b.xml"},
        {"collectionName": ..., "trackName": ...},
        {"collectionName": "", "trackName": "  "},
    ],
)
def test_a_bad_row_is_skipped_others_stay(bad: dict[str, Any]) -> None:
    directory = Directory(ids=["101", "102"], rows=[found(101, **bad), found(102)])
    assert feeds(run(directory)) == [url_of(102)]


def test_title_falls_back_to_track_name() -> None:
    directory = Directory(
        ids=["101"], rows=[found(101, collectionName=..., trackName="Имя")]
    )
    assert run(directory)[0].title == "Имя"


def test_text_is_cleaned() -> None:
    directory = Directory(
        ids=["101"],
        rows=[found(101, collectionName="  Лето‮ \x00 и\n\tзима ", artistName=5)],
    )
    (p,) = run(directory)
    assert p.title == "Лето и зима"
    assert p.author == ""


@pytest.mark.parametrize(
    ("over", "want"),
    [
        ({}, "https://is1-ssl.mzstatic.com/101/600x600bb.jpg"),
        ({"artworkUrl600": ...}, "https://is1-ssl.mzstatic.com/101/100x100bb.jpg"),
        (
            {"artworkUrl600": "http://insecure.example.org/a.jpg"},
            "https://is1-ssl.mzstatic.com/101/100x100bb.jpg",
        ),
        ({"artworkUrl600": ..., "artworkUrl100": "http://x.example.org/a.jpg"}, None),
        ({"artworkUrl600": ..., "artworkUrl100": ...}, None),
    ],
)
def test_image(over: dict[str, Any], want: str | None) -> None:
    directory = Directory(ids=["101"], rows=[found(101, **over)])
    assert run(directory)[0].image == want


@pytest.mark.parametrize(
    ("count", "want"),
    [
        (1, 1),
        (999_999, 999_999),
        (0, None),
        (1_000_000, None),
        (-3, None),
        ("7", None),
        (True, None),
        (2.0, None),
    ],
)
def test_episode_count(count: Any, want: int | None) -> None:
    directory = Directory(ids=["101"], rows=[found(101, trackCount=count)])
    assert run(directory)[0].episodes == want


def test_same_feed_twice_keeps_the_more_popular() -> None:
    shared = "https://feeds.example.org/shared.xml"
    directory = Directory(
        ids=["101", "102"],
        rows=[
            found(102, feedUrl=shared, collectionName="Второй"),
            found(101, feedUrl=shared, collectionName="Первый"),
        ],
    )
    (p,) = run(directory)
    assert p.title == "Первый"


def test_same_id_twice_in_lookup_keeps_the_first_row() -> None:
    directory = Directory(
        ids=["101"],
        rows=[found(101, collectionName="Раз"), found(101, collectionName="Два")],
    )
    assert [p.title for p in run(directory)] == ["Раз"]


def test_non_dict_rows_are_skipped() -> None:
    directory = Directory(ids=["101"], rows=[None, 5, "x", [], found(101)])
    assert feeds(run(directory)) == [url_of(101)]


# --- failures -----------------------------------------------------------------


def _status(code: int, where: str) -> Any:
    def respond(request: httpx.Request) -> httpx.Response | None:
        if (where == "top") == ("/rss/toppodcasts/" in request.url.path):
            return httpx.Response(code, json={})
        return None

    return respond


@pytest.mark.parametrize("where", ["top", "lookup"])
@pytest.mark.parametrize("code", [301, 404, 429, 500, 503])
def test_a_bad_status_is_unavailable(where: str, code: int) -> None:
    directory = Directory(respond=_status(code, where))
    with pytest.raises(PodcastSearchUnavailable):
        run(directory)


def test_a_redirect_is_not_followed() -> None:
    def respond(request: httpx.Request) -> httpx.Response | None:
        if "/rss/toppodcasts/" in request.url.path:
            return httpx.Response(
                302, headers={"location": "https://evil.example.org/top.json"}
            )
        return None

    directory = Directory(respond=respond)
    with pytest.raises(PodcastSearchUnavailable):
        run(directory)
    assert len(directory.requests) == 1


@pytest.mark.parametrize(
    "top_body",
    [
        [],
        "x",
        5,
        None,
        {"feed": []},
        {"feed": "x"},
        {"feed": {"entry": "x"}},
        {"feed": {"entry": 5}},
    ],
)
def test_a_broken_top_is_unavailable(top_body: Any) -> None:
    def respond(request: httpx.Request) -> httpx.Response | None:
        if "/rss/toppodcasts/" in request.url.path:
            return httpx.Response(200, content=json.dumps(top_body).encode())
        return None

    directory = Directory(respond=respond)
    with pytest.raises(PodcastSearchUnavailable):
        run(directory)
    assert directory.lookups() == []


@pytest.mark.parametrize(
    "lookup_body", [[], "x", {"results": "x"}, {"results": {}}, {"resultCount": 0}]
)
def test_a_broken_lookup_is_unavailable(lookup_body: Any) -> None:
    directory = Directory(lookup_body=lookup_body)
    with pytest.raises(PodcastSearchUnavailable):
        run(directory)


@pytest.mark.parametrize("where", ["top", "lookup"])
def test_not_json_is_unavailable(where: str) -> None:
    def respond(request: httpx.Request) -> httpx.Response | None:
        if (where == "top") == ("/rss/toppodcasts/" in request.url.path):
            return httpx.Response(200, content=b"<html>nope</html>")
        return None

    with pytest.raises(PodcastSearchUnavailable):
        run(Directory(respond=respond))


def test_deep_json_is_unavailable_not_a_crash() -> None:
    deep = b"[" * 100_000 + b"]" * 100_000

    def respond(request: httpx.Request) -> httpx.Response | None:
        return (
            httpx.Response(200, content=deep[: MAX_BYTES - 1])
            if "/rss/" in request.url.path
            else None
        )

    with pytest.raises(PodcastSearchUnavailable):
        run(Directory(respond=respond))


@pytest.mark.parametrize("where", ["top", "lookup"])
def test_a_compressed_answer_is_unavailable(where: str) -> None:
    def respond(request: httpx.Request) -> httpx.Response | None:
        if (where == "top") == ("/rss/toppodcasts/" in request.url.path):
            body = rss(["101"]) if where == "top" else {"results": [found(101)]}
            return httpx.Response(
                200,
                content=gzip.compress(json.dumps(body).encode()),
                headers={"content-encoding": "gzip"},
            )
        return None

    with pytest.raises(PodcastSearchUnavailable):
        run(Directory(respond=respond))


@pytest.mark.parametrize("where", ["top", "lookup"])
def test_a_huge_answer_is_unavailable(where: str) -> None:
    """Response is valid, but one byte over limit: must not read it to the end."""

    def respond(request: httpx.Request) -> httpx.Response | None:
        if (where == "top") == ("/rss/toppodcasts/" in request.url.path):
            body = rss(["101"]) if where == "top" else {"results": [found(101)]}
            raw = json.dumps(body).encode()
            return httpx.Response(200, content=raw + b" " * (MAX_BYTES + 1 - len(raw)))
        return None

    with pytest.raises(PodcastSearchUnavailable):
        run(Directory(ids=["101"], respond=respond))


def test_an_answer_at_the_limit_is_read() -> None:
    body = json.dumps(rss(["101"])).encode()
    padded = body + b" " * (MAX_BYTES - len(body))

    def respond(request: httpx.Request) -> httpx.Response | None:
        return (
            httpx.Response(200, content=padded) if "/rss/" in request.url.path else None
        )

    directory = Directory(ids=["101"], respond=respond)
    assert feeds(run(directory)) == [url_of(101)]


@pytest.mark.parametrize("where", ["top", "lookup"])
def test_a_network_error_is_unavailable_without_the_address(where: str) -> None:
    def respond(request: httpx.Request) -> httpx.Response | None:
        if (where == "top") == ("/rss/toppodcasts/" in request.url.path):
            raise httpx.ConnectError(
                "boom at https://itunes.apple.com/secret", request=request
            )
        return None

    with pytest.raises(PodcastSearchUnavailable) as caught:
        run(Directory(respond=respond))
    assert "itunes" not in str(caught.value)
    assert caught.value.__context__ is None
    assert caught.value.__cause__ is None


def test_a_slow_answer_is_unavailable(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(podcast_catalog, "TIMEOUT_S", 0.05, raising=False)
    import app.podcast_search as search_module

    monkeypatch.setattr(search_module, "TIMEOUT_S", 0.05)

    class Slow(httpx.AsyncByteStream):
        async def __aiter__(self):  # type: ignore[no-untyped-def]
            yield b"{"
            await asyncio.sleep(1)
            yield b"}"

    def respond(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, stream=Slow())

    async def go() -> None:
        async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as client:
            await top(client=client, country="ru", category=None)

    with pytest.raises(PodcastSearchUnavailable):
        asyncio.run(asyncio.wait_for(go(), timeout=0.9))


# --- cache --------------------------------------------------------------------


class Clock:
    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now


class Fetch:
    def __init__(self) -> None:
        self.calls = 0
        self.fail = False

    async def __call__(self) -> list[FoundPodcast]:
        self.calls += 1
        if self.fail:
            raise PodcastSearchUnavailable()
        return [FoundPodcast(f"t{self.calls}", "a", url_of(self.calls), None, None)]


def get(
    cache: TopCache, fetch: Fetch, key: tuple[str, int | None] = ("ru", 1533)
) -> list[FoundPodcast]:
    return asyncio.run(cache.get(key, fetch))


def test_fresh_is_not_asked_again() -> None:
    clock, fetch = Clock(), Fetch()
    cache = TopCache(clock=clock)
    first = get(cache, fetch)
    clock.now += 6 * 3600 - 1
    assert get(cache, fetch) == first
    assert fetch.calls == 1


def test_after_six_hours_it_is_asked_again() -> None:
    clock, fetch = Clock(), Fetch()
    cache = TopCache(clock=clock)
    get(cache, fetch)
    clock.now += 6 * 3600
    assert get(cache, fetch)[0].title == "t2"
    assert fetch.calls == 2


def test_a_failure_gives_the_old_answer_within_a_day() -> None:
    clock, fetch = Clock(), Fetch()
    cache = TopCache(clock=clock)
    first = get(cache, fetch)
    clock.now += 24 * 3600 - 1
    fetch.fail = True
    assert get(cache, fetch) == first
    assert fetch.calls == 2


def test_a_failure_after_a_day_is_a_failure() -> None:
    clock, fetch = Clock(), Fetch()
    cache = TopCache(clock=clock)
    get(cache, fetch)
    clock.now += 24 * 3600
    fetch.fail = True
    with pytest.raises(PodcastSearchUnavailable):
        get(cache, fetch)


def test_a_failure_with_nothing_held_is_a_failure() -> None:
    fetch = Fetch()
    fetch.fail = True
    with pytest.raises(PodcastSearchUnavailable):
        get(TopCache(clock=Clock()), fetch)


def test_a_failure_does_not_extend_the_old_answer() -> None:
    clock, fetch = Clock(), Fetch()
    cache = TopCache(clock=clock)
    get(cache, fetch)
    fetch.fail = True
    clock.now += 23 * 3600
    get(cache, fetch)
    clock.now += 2 * 3600
    with pytest.raises(PodcastSearchUnavailable):
        get(cache, fetch)


def test_a_fresh_answer_restarts_the_clock() -> None:
    clock, fetch = Clock(), Fetch()
    cache = TopCache(clock=clock)
    get(cache, fetch)
    clock.now += 6 * 3600
    second = get(cache, fetch)
    clock.now += 6 * 3600 - 1
    assert get(cache, fetch) == second
    assert fetch.calls == 2


def test_an_empty_answer_is_held_too() -> None:
    clock = Clock()
    cache = TopCache(clock=clock)
    calls = []

    async def empty() -> list[FoundPodcast]:
        calls.append(1)
        return []

    assert asyncio.run(cache.get(("ru", None), empty)) == []
    assert asyncio.run(cache.get(("ru", None), empty)) == []
    assert len(calls) == 1


def test_keys_are_separate() -> None:
    clock, fetch = Clock(), Fetch()
    cache = TopCache(clock=clock)
    a = get(cache, fetch, ("ru", 1533))
    b = get(cache, fetch, ("ru", 1487))
    c = get(cache, fetch, ("us", 1533))
    d = get(cache, fetch, ("ru", None))
    assert len({a[0].title, b[0].title, c[0].title, d[0].title}) == 4
    assert get(cache, fetch, ("ru", 1533)) == a
    assert fetch.calls == 4


def test_the_oldest_key_goes_past_the_limit() -> None:
    clock, fetch = Clock(), Fetch()
    cache = TopCache(clock=clock)
    for i in range(200):
        get(cache, fetch, (f"k{i}", None))
    get(cache, fetch, ("k1", None))
    assert fetch.calls == 200
    get(cache, fetch, ("new", None))
    assert fetch.calls == 201
    get(cache, fetch, ("k1", None))
    assert fetch.calls == 201
    get(cache, fetch, ("k0", None))
    assert fetch.calls == 202


def test_a_refreshed_key_is_no_longer_the_oldest() -> None:
    clock, fetch = Clock(), Fetch()
    cache = TopCache(clock=clock)
    for i in range(200):
        get(cache, fetch, (f"k{i}", None))
    clock.now += 6 * 3600
    get(cache, fetch, ("k0", None))
    assert fetch.calls == 201
    get(cache, fetch, ("new", None))
    clock.now -= 6 * 3600
    get(cache, fetch, ("k0", None))
    assert fetch.calls == 202


def test_the_default_clock_is_monotonic() -> None:
    import inspect
    import time

    default = inspect.signature(TopCache).parameters["clock"].default
    assert default is time.monotonic


# --- endpoints ----------------------------------------------------------------


def _app(directory: Directory | None, clock: Any = None) -> TestClient:
    app = create_app(
        database_url=None,
        catalog=[],
    )
    client = (
        httpx.AsyncClient(transport=httpx.MockTransport(directory))
        if directory is not None
        else None
    )
    kwargs: dict[str, Any] = {"client": client}
    if clock is not None:
        kwargs["clock"] = clock
    install_podcast_catalog(app, **kwargs)
    return TestClient(app)


def test_categories_route() -> None:
    r = _app(Directory()).get("/v1/podcasts/categories")
    assert r.status_code == 200
    body = r.json()
    assert body == {
        "categories": [{"id": c.id, "ru": c.ru, "en": c.en} for c in CATEGORIES]
    }
    assert body["categories"][0] == {"id": 1533, "ru": "Наука", "en": "Science"}


def test_top_route_gives_the_search_shape() -> None:
    directory = Directory(ids=["101", "102"])
    r = _app(directory).get(
        "/v1/podcasts/top", params={"category": "1533", "country": "ru"}
    )
    assert r.status_code == 200
    assert r.json() == {
        "podcasts": [
            {
                "feed_url": url_of(i),
                "title": f"Подкаст {i}",
                "author": "Автор",
                "image": f"https://is1-ssl.mzstatic.com/{i}/600x600bb.jpg",
                "episodes": 42,
            }
            for i in (101, 102)
        ]
    }
    assert (
        directory.tops()[0].url.path == "/ru/rss/toppodcasts/limit=30/genre=1533/json"
    )


def test_top_route_without_parameters_is_the_overall_us_top() -> None:
    directory = Directory()
    r = _app(directory).get("/v1/podcasts/top")
    assert r.status_code == 200
    assert directory.tops()[0].url.path == "/us/rss/toppodcasts/limit=30/json"


def test_top_route_bad_country_is_the_default() -> None:
    directory = Directory()
    assert (
        _app(directory)
        .get("/v1/podcasts/top", params={"country": "Россия"})
        .status_code
        == 200
    )
    assert directory.tops()[0].url.path.startswith("/us/")


@pytest.mark.parametrize(
    "category",
    [
        "",
        "abc",
        "9999",
        "1310",
        "-1533",
        "+1533",
        "1533.0",
        " 1533",
        "１５３３",
        "01533",
    ],
)
def test_top_route_bad_category_is_refused_and_asks_nobody(category: str) -> None:
    directory = Directory()
    r = _app(directory).get("/v1/podcasts/top", params={"category": category})
    assert r.status_code == 400
    assert r.json() == {"status": "invalid_request"}
    assert directory.requests == []


def test_top_route_without_a_client_is_unavailable() -> None:
    r = _app(None).get("/v1/podcasts/top")
    assert r.status_code == 503
    assert r.json() == {"status": "podcast_search_unavailable"}


def test_top_route_directory_trouble_is_unavailable() -> None:
    directory = Directory(respond=_status(500, "top"))
    r = _app(directory).get("/v1/podcasts/top", params={"category": "1487"})
    assert r.status_code == 503
    assert r.json() == {"status": "podcast_search_unavailable"}


def test_top_route_holds_the_answer() -> None:
    directory = Directory()
    client = _app(directory)
    for _ in range(3):
        assert (
            client.get(
                "/v1/podcasts/top", params={"category": "1533", "country": "ru"}
            ).status_code
            == 200
        )
    assert len(directory.tops()) == 1
    assert len(directory.lookups()) == 1
    client.get("/v1/podcasts/top", params={"category": "1487", "country": "ru"})
    assert len(directory.tops()) == 2


def test_top_route_gives_the_old_answer_when_the_directory_fails() -> None:
    clock = Clock()
    state = {"down": False}

    def respond(request: httpx.Request) -> httpx.Response | None:
        return httpx.Response(500) if state["down"] else None

    directory = Directory(respond=respond)
    client = _app(directory, clock)
    first = client.get("/v1/podcasts/top").json()
    clock.now += 7 * 3600
    state["down"] = True
    r = client.get("/v1/podcasts/top")
    assert r.status_code == 200
    assert r.json() == first


def test_top_route_with_an_empty_top_is_an_empty_list() -> None:
    directory = Directory(top_body={"feed": {}})
    r = _app(directory).get("/v1/podcasts/top")
    assert r.status_code == 200
    assert r.json() == {"podcasts": []}


def test_nothing_about_podcasts_reaches_the_log(
    caplog: pytest.LogCaptureFixture,
) -> None:
    caplog.set_level(logging.DEBUG)
    directory = Directory(ids=["101"], rows=[found(101, collectionName=TITLE)])
    client = _app(directory)
    assert (
        client.get(
            "/v1/podcasts/top", params={"category": "1533", "country": "ru"}
        ).status_code
        == 200
    )
    text = "\n".join(r.getMessage() for r in caplog.records)
    assert TITLE not in text
    assert "feeds.example.org" not in text
    assert "toppodcasts" not in text
    assert "lookup" not in text
