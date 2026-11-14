"""FT-724 (C1, R-A99, contract D5a): found release -> book on shelf.

Contract of module `app/book_shelving.py`:
- `shelve_found(conn, user_id, found: FoundBook, *, files, space=DEFAULT_BOOK_SPACE,
  now=None) -> Outcome`;
- `files(asset, hint)` — coroutine supplied externally (in prod — extension per books contract,
  here fake): list of release files in a format understood by `book_parts`,
  or `None` if file source gave nothing;
- `Outcome(state, book)`; `state` — one of `ok, exists, no_space, limit,
  not_a_book, unavailable, unknown`; `book` — `books.Book` for `ok`/`exists`,
  otherwise `None`;
- already stored release is put on shelf without fetching files;
- on any failure, neither book nor parts remain in database;
- fetching files is before writing, writing is a single transaction;
- module logs nothing about the book.

What these tests do not prove: that real extension responds in this format
(that is C2 and wiring), that phone receives the book (C2), and that cache preserves
the book (C4).
"""

from __future__ import annotations

import asyncio
import logging
from datetime import UTC, datetime
from typing import Any
from uuid import UUID

import asyncpg
import pytest

from app import books
from app.book_found import FoundBook
from app.book_shelving import Outcome, shelve_found
from app.migrate import apply

NOW = datetime(2026, 10, 10, 12, 0, tzinfo=UTC)
ANN = UUID("aaaaaaaa-0000-4000-8000-000000000724")
BOB = UUID("bbbbbbbb-0000-4000-8000-000000000724")
NOBODY = UUID("cccccccc-0000-4000-8000-000000000724")
ASSET = "bookhost:5551234"
HINT = "opaque-hint-724"
TITLE = "Мастер и Маргарита"
STATES = {"ok", "exists", "no_space", "limit", "not_a_book", "unavailable", "unknown"}


def found(asset: str = ASSET, **over: Any) -> FoundBook:
    values: dict[str, Any] = {
        "title": TITLE,
        "author": "Булгаков",
        "narrator": "Чтец Чтецов",
        "year": 2011,
        "size_bytes": 3000,
        "popularity": 5,
        "asset": asset,
        "hint": HINT,
    }
    values.update(over)
    return FoundBook(**values)


def listing(count: int = 3, size: int = 1000) -> list[dict[str, Any]]:
    # Reverse order: parts must be ordered by name, not by output order.
    return [
        {"index": n, "name": f"Книга/{n:02d}.mp3", "length": size + n}
        for n in range(count, 0, -1)
    ]


class Files:
    def __init__(self, answer: Any = None, *, error: Exception | None = None) -> None:
        self.answer = listing() if answer is None else answer
        self.error = error
        self.calls: list[tuple[str, str]] = []

    async def __call__(self, asset: str, hint: str) -> Any:
        self.calls.append((asset, hint))
        await asyncio.sleep(0)
        if self.error is not None:
            raise self.error
        return self.answer


class NoneFiles(Files):
    async def __call__(self, asset: str, hint: str) -> Any:
        self.calls.append((asset, hint))
        return None


def _run(url: str, work: Any) -> Any:
    async def go() -> Any:
        conn = await asyncpg.connect(url)
        try:
            return await work(conn)
        finally:
            await conn.close()

    return asyncio.run(go())


@pytest.fixture
def base(postgres_url: str) -> str:
    asyncio.run(apply(postgres_url))

    async def prepare(conn: asyncpg.Connection) -> None:
        await conn.execute("TRUNCATE books CASCADE")
        for user, name in ((ANN, "ann-ft724"), (BOB, "bob-ft724")):
            await conn.execute(
                "INSERT INTO users (id, username) VALUES ($1, $2) ON CONFLICT (id) DO NOTHING",
                user,
                name,
            )

    _run(postgres_url, prepare)
    return postgres_url


async def _counts(conn: asyncpg.Connection) -> tuple[int, int, int]:
    return (
        await conn.fetchval("SELECT count(*) FROM books"),
        await conn.fetchval("SELECT count(*) FROM book_parts"),
        await conn.fetchval("SELECT count(*) FROM book_shelf"),
    )


def _shelve(url: str, user: UUID, files: Any, **kw: Any) -> tuple[Outcome, Any]:
    async def work(conn: asyncpg.Connection) -> tuple[Outcome, Any]:
        out = await shelve_found(
            conn, user, kw.pop("item", found()), files=files, now=NOW, **kw
        )
        return out, await _counts(conn)

    return _run(url, work)


# --- happy path -----------------------------------------------------------


def test_new_book_lands_on_the_shelf(base: str) -> None:
    files = Files()
    out, counts = _shelve(base, ANN, files)
    assert out.state == "ok"
    assert isinstance(out.book, books.Book)
    assert out.book.title == TITLE
    assert out.book.author == "Булгаков"
    assert out.book.narrator == "Чтец Чтецов"
    assert out.book.year == 2011
    assert out.book.parts == 3
    assert out.book.total_bytes == 1001 + 1002 + 1003
    assert counts == (1, 3, 1)
    assert files.calls == [(ASSET, HINT)]


def test_parts_are_stored_in_name_order(base: str) -> None:
    out, _ = _shelve(base, ANN, Files())
    assert out.book is not None

    async def work(conn: asyncpg.Connection) -> list[books.StoredPart]:
        return await books.book_parts(conn, out.book.id)

    stored = _run(base, work)
    assert [(p.number, p.file_index, p.size) for p in stored] == [
        (1, 1, 1001),
        (2, 2, 1002),
        (3, 3, 1003),
    ]


def test_book_keeps_the_asset_and_hint_on_the_server(base: str) -> None:
    out, _ = _shelve(base, ANN, Files())
    assert out.book is not None

    async def work(conn: asyncpg.Connection) -> books.BookSource | None:
        return await books.book_source(conn, out.book.id)

    source = _run(base, work)
    assert source is not None
    assert source.asset == ASSET
    assert source.hint == HINT


def test_book_is_on_the_persons_shelf(base: str) -> None:
    out, _ = _shelve(base, ANN, Files())

    async def work(conn: asyncpg.Connection) -> list[UUID]:
        return [s.book.id for s in await books.shelf(conn, ANN)]

    assert out.book is not None
    assert _run(base, work) == [out.book.id]


def test_same_person_twice_is_exists_without_files(base: str) -> None:
    first, _ = _shelve(base, ANN, Files())
    files = Files()
    out, counts = _shelve(base, ANN, files)
    assert out.state == "exists"
    assert out.book is not None and first.book is not None
    assert out.book.id == first.book.id
    assert files.calls == []
    assert counts == (1, 3, 1)


def test_other_person_gets_the_same_book_without_files(base: str) -> None:
    first, _ = _shelve(base, ANN, Files())
    files = Files()
    out, counts = _shelve(base, BOB, files)
    assert out.state == "ok"
    assert out.book is not None and first.book is not None
    assert out.book.id == first.book.id
    assert files.calls == []
    assert counts == (1, 3, 2)


# --- failures: nothing recorded -----------------------------------------------


def test_no_audio_files_is_not_a_book(base: str) -> None:
    files = Files([{"index": 0, "name": "cover.jpg", "length": 100}])
    out, counts = _shelve(base, ANN, files)
    assert out == Outcome("not_a_book")
    assert counts == (0, 0, 0)


def test_empty_listing_is_not_a_book(base: str) -> None:
    out, counts = _shelve(base, ANN, Files([]))
    assert out == Outcome("not_a_book")
    assert counts == (0, 0, 0)


def test_too_many_parts_is_not_a_book(base: str) -> None:
    out, counts = _shelve(base, ANN, Files(listing(books.MAX_BOOK_PARTS + 1)))
    assert out == Outcome("not_a_book")
    assert counts == (0, 0, 0)


def test_exactly_the_part_limit_is_a_book(base: str) -> None:
    out, counts = _shelve(base, ANN, Files(listing(books.MAX_BOOK_PARTS)))
    assert out.state == "ok"
    assert counts == (1, books.MAX_BOOK_PARTS, 1)


def test_files_error_is_unavailable(base: str) -> None:
    out, counts = _shelve(base, ANN, Files(error=RuntimeError("boom")))
    assert out == Outcome("unavailable")
    assert counts == (0, 0, 0)


def test_files_timeout_is_unavailable(base: str) -> None:
    out, counts = _shelve(base, ANN, Files(error=TimeoutError()))
    assert out == Outcome("unavailable")
    assert counts == (0, 0, 0)


def test_files_none_is_unavailable(base: str) -> None:
    out, counts = _shelve(base, ANN, NoneFiles())
    assert out == Outcome("unavailable")
    assert counts == (0, 0, 0)


def test_bad_asset_is_not_a_book_and_files_not_asked(base: str) -> None:
    files = Files()
    out, counts = _shelve(base, ANN, files, item=found(asset="no colon here"))
    assert out == Outcome("not_a_book")
    assert files.calls == []
    assert counts == (0, 0, 0)


def test_unsavable_title_leaves_nothing(base: str) -> None:
    out, counts = _shelve(base, ANN, Files(), item=found(title="   "))
    assert out == Outcome("not_a_book")
    assert counts == (0, 0, 0)


def test_no_space_leaves_no_orphan_book(base: str) -> None:
    out, counts = _shelve(base, ANN, Files(), space=100)
    assert out == Outcome("no_space")
    assert counts == (0, 0, 0)


def test_known_book_on_no_shelf_still_respects_space(base: str) -> None:
    # Book is recorded, but on nobody's shelf (will be dropped 24h later, C4):
    # it holds no space, so limit applies to it as well.
    _shelve(base, ANN, Files())

    async def drop(conn: asyncpg.Connection) -> None:
        await conn.execute("DELETE FROM book_shelf")

    _run(base, drop)
    files = Files()
    out, counts = _shelve(base, BOB, files, space=100)
    assert out == Outcome("no_space")
    assert files.calls == []
    assert counts == (1, 3, 0)


def test_unknown_person_leaves_no_orphan_book(base: str) -> None:
    out, counts = _shelve(base, NOBODY, Files())
    assert out == Outcome("unknown")
    assert counts == (0, 0, 0)


def test_full_shelf_is_limit_and_leaves_no_orphan_book(base: str) -> None:
    async def fill(conn: asyncpg.Connection) -> None:
        one = [books.StoredPart(1, 0, 10, "mp3")]
        for n in range(books.MAX_SHELF):
            book_id = await books.save_book(
                conn, asset=f"fill:{n}", hint="h", title=f"t{n}", parts=one, now=NOW
            )
            assert book_id is not None
            assert await books.shelve(conn, ANN, book_id, now=NOW) == "ok"

    _run(base, fill)
    out, counts = _shelve(base, ANN, Files())
    assert out == Outcome("limit")
    assert counts == (books.MAX_SHELF, books.MAX_SHELF, books.MAX_SHELF)


def test_failure_while_shelving_rolls_the_book_back(
    base: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    async def broken(*_: Any, **__: Any) -> str:
        raise RuntimeError("shelf broke")

    monkeypatch.setattr(books, "shelve", broken)

    async def work(conn: asyncpg.Connection) -> tuple[int, int, int]:
        with pytest.raises(RuntimeError):
            await shelve_found(conn, ANN, found(), files=Files(), now=NOW)
        return await _counts(conn)

    assert _run(base, work) == (0, 0, 0)


def test_failure_does_not_poison_the_next_attempt(base: str) -> None:
    _shelve(base, ANN, Files(), space=100)
    out, counts = _shelve(base, ANN, Files())
    assert out.state == "ok"
    assert counts == (1, 3, 1)


# --- race ------------------------------------------------------------------


def test_two_people_at_once_get_one_book_two_shelves(base: str) -> None:
    async def go() -> tuple[list[Outcome], tuple[int, int, int]]:
        one = await asyncpg.connect(base)
        two = await asyncpg.connect(base)
        try:
            outs = await asyncio.gather(
                shelve_found(one, ANN, found(), files=Files(), now=NOW),
                shelve_found(two, BOB, found(), files=Files(), now=NOW),
            )
            return list(outs), await _counts(one)
        finally:
            await one.close()
            await two.close()

    outs, counts = asyncio.run(go())
    assert [o.state for o in outs] == ["ok", "ok"]
    assert outs[0].book is not None and outs[1].book is not None
    assert outs[0].book.id == outs[1].book.id
    assert counts == (1, 3, 2)


def test_files_are_fetched_outside_a_transaction(base: str) -> None:
    seen: list[bool] = []

    async def work(conn: asyncpg.Connection) -> Outcome:
        async def files(asset: str, hint: str) -> Any:
            seen.append(conn.is_in_transaction())
            return listing()

        return await shelve_found(conn, ANN, found(), files=files, now=NOW)

    assert _run(base, work).state == "ok"
    assert seen == [False]


# --- contract --------------------------------------------------------------


def test_every_state_is_from_the_agreed_list(base: str) -> None:
    results = [
        _shelve(base, ANN, Files())[0],
        _shelve(base, ANN, Files())[0],
        _shelve(base, ANN, Files(error=RuntimeError()), item=found(asset="x:1"))[0],
        _shelve(base, ANN, Files([]), item=found(asset="x:2"))[0],
        _shelve(base, ANN, Files(), item=found(asset="x:3"), space=1)[0],
        _shelve(base, NOBODY, Files(), item=found(asset="x:4"))[0],
    ]
    assert {r.state for r in results} <= STATES
    assert all((r.book is None) == (r.state not in ("ok", "exists")) for r in results)


def test_nothing_about_the_book_goes_to_the_log(
    base: str, caplog: pytest.LogCaptureFixture
) -> None:
    caplog.set_level(logging.DEBUG)
    _shelve(base, ANN, Files())
    _shelve(base, BOB, Files(error=RuntimeError(TITLE)), item=found(asset="x:9"))
    text = caplog.text
    for secret in (TITLE, "Булгаков", "Чтец Чтецов", ASSET, HINT, "Книга/01.mp3"):
        assert secret not in text
