"""FT-726 (Bk-1b, R-A88, books contract FT-721): core queries book extension.

Contract of module `app/book_extension.py`:
- `BookExtension(name, url, *, transport=None, poll_s=1.0, wait_s=15.0, clock=time.monotonic,
  sleep=asyncio.sleep)`; `transport` — for tests (`httpx.MockTransport`);
- `await search(query, limit) -> list[FoundBook]` — `POST {url}/v1/books/find {query, limit}`;
  finding: `asset = "<name>:<id>"`, `hint = id`; selection and order — same as `found_books` (FT-672);
  author, narrator and year — from extension fields if present, otherwise from title;
  non-2xx response, network or broken body — exception (endpoint returns 503, not empty list);
- `await files(asset, hint) -> list[dict] | None` — `POST {url}/v1/books/files {id: hint}`;
  `ready` -> `[{index, name, length}]` (as understood by `book_parts`); `preparing` — repoll after
  `poll_s` within `wait_s`, then `None`; `failed`, `404` or alien `asset` — `None`;
  network or 5xx — exception (`shelve_found` returns `unavailable`).

What test does not prove: that book index extension responds this way (its endpoints — next card) and
that `main.py` wires the module (lead).
"""

from __future__ import annotations

import asyncio
import json
import logging
from typing import Any

import httpx
import pytest

from app.book_extension import BookExtension
from app.book_found import FoundBook
from app.book_parts import book_parts

URL = "http://books-ext:8080"
MIB = 1024**2


def item(n: int = 1, **over: Any) -> dict[str, Any]:
    base: dict[str, Any] = {
        "id": f"t{n}",
        "title": f"Автор {n} - Книга {n} [Чтец {n}, 2010]",
        "author": "",
        "narrator": "",
        "year": None,
        "size": 50 * MIB,
        "language": "ru",
        "popularity": 10 + n,
    }
    base.update(over)
    return base


class Ext:
    """Extension from test: remembers requests, responds with configured data."""

    def __init__(self) -> None:
        self.calls: list[tuple[str, Any]] = []
        self.find_status = 200
        self.find_body: Any = {"items": [item(1)]}
        self.files_replies: list[tuple[int, Any]] = []

    def handle(self, request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content) if request.content else None
        self.calls.append((request.url.path, body))
        assert str(request.url).startswith(URL)
        if request.url.path == "/v1/books/find":
            return httpx.Response(self.find_status, json=self.find_body)
        if request.url.path == "/v1/books/files":
            status, reply = (
                self.files_replies.pop(0)
                if len(self.files_replies) > 1
                else self.files_replies[0]
            )
            return httpx.Response(status, json=reply)
        return httpx.Response(404, json={})


class Clock:
    def __init__(self) -> None:
        self.now = 100.0
        self.sleeps: list[float] = []

    def __call__(self) -> float:
        return self.now

    async def sleep(self, seconds: float) -> None:
        self.sleeps.append(seconds)
        self.now += seconds


def ext(fake: Ext, clock: Clock | None = None, **kw: Any) -> BookExtension:
    clock = clock or Clock()
    return BookExtension(
        "bookhost",
        URL + "/",
        transport=httpx.MockTransport(fake.handle),
        clock=clock,
        sleep=clock.sleep,
        **kw,
    )


def run(coro: Any) -> Any:
    return asyncio.run(coro)


# --- search ------------------------------------------------------------------


def test_search_asks_find_and_maps_to_found_books() -> None:
    fake = Ext()
    books = run(ext(fake).search("мастер", 7))
    assert fake.calls == [("/v1/books/find", {"query": "мастер", "limit": 7})]
    assert len(books) == 1
    book = books[0]
    assert isinstance(book, FoundBook)
    assert book.asset == "bookhost:t1"
    assert book.hint == "t1"
    assert book.size_bytes == 50 * MIB
    assert book.popularity == 11


def test_search_limit_and_query_are_bounded() -> None:
    fake = Ext()
    run(ext(fake).search("x" * 500, 999))
    _, body = fake.calls[0]
    assert body == {"query": "x" * 200, "limit": 50}
    run(ext(fake).search("ab", 0))
    assert fake.calls[1][1]["limit"] == 1


def test_fields_from_extension_win_over_title() -> None:
    fake = Ext()
    fake.find_body = {
        "items": [item(1, author="Булгаков", narrator="Ульянов", year=2011)]
    }
    book = run(ext(fake).search("мастер", 5))[0]
    assert (book.author, book.narrator, book.year) == ("Булгаков", "Ульянов", 2011)


def test_empty_fields_fall_back_to_title() -> None:
    fake = Ext()
    fake.find_body = {"items": [item(1, author="  ", narrator=None, year="2011")]}
    book = run(ext(fake).search("мастер", 5))[0]
    assert book.author == "Автор 1"
    assert book.narrator == "Чтец 1"
    assert book.year == 2010


@pytest.mark.parametrize("year", [0, 999, 3000, True, 2011.0])
def test_nonsense_year_is_ignored(year: Any) -> None:
    fake = Ext()
    fake.find_body = {"items": [item(1, year=year)]}
    assert run(ext(fake).search("мастер", 5))[0].year == 2010


def test_bad_items_are_dropped_and_order_is_by_popularity() -> None:
    fake = Ext()
    fake.find_body = {
        "items": [
            item(1, popularity=3),
            item(2, popularity=30),
            item(3, id="bad/id"),
            item(4, id="has:colon"),
            item(5, size=1 * MIB),
            item(6, popularity=0),
            "nonsense",
            item(7, id=7),
        ]
    }
    books = run(ext(fake).search("мастер", 10))
    assert [b.hint for b in books] == ["t2", "t1"]


def test_search_cuts_to_limit() -> None:
    fake = Ext()
    fake.find_body = {"items": [item(n) for n in range(1, 30)]}
    assert len(run(ext(fake).search("мастер", 4))) == 4


@pytest.mark.parametrize("status", [500, 503, 400])
def test_search_failure_raises(status: int) -> None:
    fake = Ext()
    fake.find_status = status
    with pytest.raises((httpx.HTTPError, ValueError)):
        run(ext(fake).search("мастер", 5))


@pytest.mark.parametrize("body", [{"nope": 1}, [], {"items": "x"}])
def test_search_bad_body_raises(body: Any) -> None:
    fake = Ext()
    fake.find_body = body
    with pytest.raises((httpx.HTTPError, ValueError)):
        run(ext(fake).search("мастер", 5))


def test_search_empty_is_empty() -> None:
    fake = Ext()
    fake.find_body = {"items": []}
    assert run(ext(fake).search("мастер", 5)) == []


# --- files -------------------------------------------------------------------

READY = {
    "state": "ready",
    "files": [
        {"index": 2, "name": "Книга/02.mp3", "size": 2000},
        {"index": 0, "name": "Книга/cover.jpg", "size": 50},
        {"index": 1, "name": "Книга/01.mp3", "size": 1000},
    ],
}


def test_files_ready_maps_size_to_length() -> None:
    fake = Ext()
    fake.files_replies = [(200, READY)]
    listing = run(ext(fake).files("bookhost:t1", "t1"))
    assert fake.calls == [("/v1/books/files", {"id": "t1"})]
    assert {"index": 1, "name": "Книга/01.mp3", "length": 1000} in listing
    parts = book_parts(listing)
    assert [(p.number, p.file_index, p.size) for p in parts] == [
        (1, 1, 1000),
        (2, 2, 2000),
    ]


def test_preparing_is_asked_again_then_ready() -> None:
    fake = Ext()
    fake.files_replies = [
        (200, {"state": "preparing", "files": []}),
        (200, {"state": "preparing", "files": []}),
        (200, READY),
    ]
    clock = Clock()
    listing = run(ext(fake, clock, poll_s=1.0, wait_s=15.0).files("bookhost:t1", "t1"))
    assert listing is not None and len(listing) == 3
    assert len(fake.calls) == 3
    assert clock.sleeps == [1.0, 1.0]


def test_preparing_too_long_gives_none() -> None:
    fake = Ext()
    fake.files_replies = [(200, {"state": "preparing", "files": []})]
    clock = Clock()
    assert (
        run(ext(fake, clock, poll_s=1.0, wait_s=5.0).files("bookhost:t1", "t1")) is None
    )
    assert 4 <= len(fake.calls) <= 6
    assert sum(clock.sleeps) <= 5.0


@pytest.mark.parametrize(
    "reply",
    [
        (200, {"state": "failed", "reason": "not_found", "files": []}),
        (404, {"status": "unknown_id"}),
        (200, {"state": "weird"}),
        (200, {"state": "ready", "files": "x"}),
        (200, ["nope"]),
    ],
)
def test_no_files_gives_none(reply: tuple[int, Any]) -> None:
    fake = Ext()
    fake.files_replies = [reply]
    assert run(ext(fake).files("bookhost:t1", "t1")) is None


@pytest.mark.parametrize(
    ("asset", "hint"),
    [
        ("other:t1", "t1"),
        ("bookhost:t2", "t1"),
        ("bookhost:a/b", "a/b"),
        ("bookhost:", ""),
    ],
)
def test_foreign_or_bad_asset_is_not_asked(asset: str, hint: str) -> None:
    fake = Ext()
    fake.files_replies = [(200, READY)]
    assert run(ext(fake).files(asset, hint)) is None
    assert fake.calls == []


@pytest.mark.parametrize("status", [500, 503])
def test_files_server_error_raises(status: int) -> None:
    fake = Ext()
    fake.files_replies = [(status, {})]
    with pytest.raises((httpx.HTTPError, ValueError)):
        run(ext(fake).files("bookhost:t1", "t1"))


def test_network_error_raises() -> None:
    def down(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("down", request=request)

    book_ext = BookExtension("bookhost", URL, transport=httpx.MockTransport(down))
    with pytest.raises((httpx.HTTPError, ValueError)):
        run(book_ext.search("мастер", 5))
    with pytest.raises((httpx.HTTPError, ValueError)):
        run(book_ext.files("bookhost:t1", "t1"))


def test_nothing_in_the_log(caplog: pytest.LogCaptureFixture) -> None:
    # Only logger 'apertonodo' is configured ('app/log_config.py'); httpx lines not visible in prod.
    caplog.set_level(logging.DEBUG, logger="apertonodo")
    fake = Ext()
    fake.files_replies = [(200, READY)]
    book_ext = ext(fake)
    run(book_ext.search("секретныйзапрос", 5))
    run(book_ext.files("bookhost:t1", "t1"))
    text = caplog.text
    for word in ("секретныйзапрос", "Книга", "Автор 1", "bookhost:t1", URL):
        assert word not in text, word
