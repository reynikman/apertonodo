"""FT-667 (R-A99, contract D5): audiobooks, their parts, and personal shelves in DB.

No custom book catalog: book is a release as found by source. Release id
and source address live only on server; client identifies book by
opaque UUID. Book stays on server while shelved on someone's shelf,
and books have their own disk space limit — shared per server, by default 20 GB.

Contract of module `app/books.py`:
- `normalize_asset(raw) -> str | None` — `asset` key (FT-720, `test_book_asset_names.py`);
- `save_book(conn, *, asset, hint, title, parts, author="",
  narrator="", year=None, now=None) -> UUID | None` — `None` if book
  cannot be saved; same release second time — same ID, nothing changes;
- `book(conn, book_id) -> Book | None`, `book_parts(conn, book_id) -> list[StoredPart]`;
- `book_source(conn, book_id) -> BookSource | None` — server only;
- `shelve(conn, user_id, book_id, *, space=DEFAULT_BOOK_SPACE, now=None)
  -> "ok" | "exists" | "unknown" | "limit" | "no_space"`;
- `unshelve(conn, user_id, book_id) -> bool`;
- `shelf(conn, user_id) -> list[ShelfBook]`;
- `shelf_bytes(conn) -> int`, `kept_assets(conn) -> set[str]`;
- constants `MAX_SHELF = 500`, `MAX_BOOK_PARTS = 3000`, `MAX_BOOK_TEXT = 500`,
  `DEFAULT_BOOK_SPACE = 20 GB`.

What tests do not prove: that anyone finds or downloads the book, that endpoints
exist, that cache truly does not evict book (it only receives the
`kept_assets` set) and that resume position is stored — these are subsequent cards.
"""

from __future__ import annotations

import asyncio
import dataclasses
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any
from uuid import UUID

import asyncpg
import pytest

from app import books
from app.books import (
    DEFAULT_BOOK_SPACE,
    MAX_BOOK_PARTS,
    MAX_BOOK_TEXT,
    MAX_SHELF,
    Book,
    BookSource,
    ShelfBook,
    StoredPart,
    book,
    book_parts,
    book_source,
    kept_assets,
    save_book,
    shelf,
    shelf_bytes,
    shelve,
    unshelve,
)
from app.migrate import apply

NOW = datetime(2026, 10, 7, 12, 0, tzinfo=UTC)
ANN = UUID("aaaaaaaa-0000-4000-8000-000000000067")
BOB = UUID("bbbbbbbb-0000-4000-8000-000000000067")
NOBODY = UUID("cccccccc-0000-4000-8000-000000000067")
HASH = "bt:" + "a" * 40
OTHER = "bt:" + "b" * 40
HINT = "opaque-hint-" + "a" * 8


@dataclass(frozen=True)
class Part:
    """What `book_parts` returns from FT-665: storage only needs these four fields."""

    number: int
    file_index: int
    size: int
    kind: str


def parts(count: int = 3, *, size: int = 1000) -> list[Part]:
    return [Part(n, n + 4, size + n, "mp3") for n in range(1, count + 1)]


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
        for user, name in ((ANN, "ann-ft667"), (BOB, "bob-ft667")):
            await conn.execute(
                "INSERT INTO users (id, username) VALUES ($1, $2) ON CONFLICT (id) DO NOTHING",
                user,
                name,
            )

    _run(postgres_url, prepare)
    return postgres_url


async def _save(
    conn: asyncpg.Connection, asset: str = HASH, **over: Any
) -> UUID | None:
    values: dict[str, Any] = {
        "asset": asset,
        "hint": f"hint-{asset}",
        "title": "Книга",
        "author": "Автор",
        "narrator": "Чтец",
        "year": 2010,
        "parts": parts(),
        "now": NOW,
    }
    values.update(over)
    return await save_book(conn, **values)


def _hash(n: int) -> str:
    return f"bt:{n:040x}"


# --- contract -------------------------------------------------------------


def test_constants_are_the_agreed_ones():
    assert MAX_SHELF == 500
    assert MAX_BOOK_PARTS == 3000
    assert MAX_BOOK_TEXT == 500
    assert DEFAULT_BOOK_SPACE == 20 * 1024**3


def test_what_goes_outside_carries_no_source():
    assert [f.name for f in dataclasses.fields(Book)] == [
        "id",
        "title",
        "author",
        "narrator",
        "year",
        "total_bytes",
        "parts",
        "added_at",
    ]
    assert [f.name for f in dataclasses.fields(ShelfBook)] == ["book", "shelved_at"]
    assert [f.name for f in dataclasses.fields(StoredPart)] == [
        "number",
        "file_index",
        "size",
        "kind",
    ]


def test_the_source_does_not_print_itself():
    source = BookSource(asset=HASH, hint=HINT)
    assert HASH not in repr(source)
    assert HASH not in str(source)
    assert HINT not in repr(source)


# Asset key formatting — `test_book_asset_names.py` (FT-720).


# --- book -----------------------------------------------------------------


def test_a_book_is_saved_and_read_back(base):
    async def work(conn):
        book_id = await _save(conn)
        return book_id, await book(conn, book_id), await book_parts(conn, book_id)

    book_id, saved, stored = _run(base, work)
    assert isinstance(book_id, UUID)
    assert saved == Book(
        id=book_id,
        title="Книга",
        author="Автор",
        narrator="Чтец",
        year=2010,
        total_bytes=1001 + 1002 + 1003,
        parts=3,
        added_at=NOW,
    )
    assert stored == [
        StoredPart(number=1, file_index=5, size=1001, kind="mp3"),
        StoredPart(number=2, file_index=6, size=1002, kind="mp3"),
        StoredPart(number=3, file_index=7, size=1003, kind="mp3"),
    ]


def test_the_book_number_says_nothing_about_the_release(base):
    async def work(conn):
        return await _save(conn), await _save(conn, OTHER)

    first, second = _run(base, work)
    assert first != second
    assert HASH not in str(first) and HASH[:8] not in first.hex
    assert first.version == 4


def test_the_source_stays_on_the_server_side(base):
    async def work(conn):
        book_id = await _save(conn, " " + HASH + "\n", hint="  " + HINT + " ")
        return await book_source(conn, book_id), await book_source(conn, NOBODY)

    source, missing = _run(base, work)
    assert source == BookSource(asset=HASH, hint=HINT)
    assert missing is None


def test_the_same_release_again_is_the_same_book_and_changes_nothing(base):
    async def work(conn):
        first = await _save(conn)
        again = await _save(
            conn,
            HASH,
            title="Другое название",
            author="Другой",
            parts=parts(5),
            hint="other",
            now=NOW + timedelta(days=1),
        )
        return (
            first,
            again,
            await book(conn, first),
            await book_parts(conn, first),
            await book_source(conn, first),
        )

    first, again, saved, stored, source = _run(base, work)
    assert again == first
    assert saved.title == "Книга" and saved.parts == 3 and saved.added_at == NOW
    assert len(stored) == 3
    assert source.hint == f"hint-{HASH}"


def test_two_saves_at_once_give_one_book(base):
    async def work(_conn):
        async def one() -> UUID | None:
            conn = await asyncpg.connect(base)
            try:
                return await _save(conn)
            finally:
                await conn.close()

        ids = await asyncio.gather(*[one() for _ in range(6)])
        conn = await asyncpg.connect(base)
        try:
            rows = await conn.fetchval("SELECT count(*) FROM books")
            stored = await conn.fetchval("SELECT count(*) FROM book_parts")
        finally:
            await conn.close()
        return ids, rows, stored

    ids, rows, stored = _run(base, work)
    assert len(set(ids)) == 1 and ids[0] is not None
    assert rows == 1 and stored == 3


def test_an_unknown_book_is_none_and_has_no_parts(base):
    async def work(conn):
        return await book(conn, NOBODY), await book_parts(conn, NOBODY)

    assert _run(base, work) == (None, [])


def test_an_unknown_book_is_none_even_when_others_exist(base):
    async def work(conn):
        first = await _save(conn, _hash(1), title="Первая")
        second = await _save(conn, _hash(2), title="Вторая", parts=parts(2))
        return (
            await book(conn, NOBODY),
            await book_parts(conn, NOBODY),
            await book_source(conn, NOBODY),
            (await book(conn, first)).title,
            (await book(conn, second)).title,
            len(await book_parts(conn, second)),
            (await book_source(conn, second)).asset,
        )

    assert _run(base, work) == (None, [], None, "Первая", "Вторая", 2, _hash(2))


def test_text_is_cleaned_and_cut(base):
    async def work(conn):
        book_id = await _save(
            conn,
            title="  Война \n\t и   мир\x00\x07 ",
            author="А" * (MAX_BOOK_TEXT + 50),
            narrator=None,
        )
        return await book(conn, book_id)

    saved = _run(base, work)
    assert saved.title == "Война и мир"
    assert saved.author == "А" * MAX_BOOK_TEXT
    assert saved.narrator == ""


def test_a_cut_title_does_not_end_with_a_space(base):
    async def work(conn):
        book_id = await _save(conn, title="Б" * (MAX_BOOK_TEXT - 1) + " хвост")
        return await book(conn, book_id)

    assert _run(base, work).title == "Б" * (MAX_BOOK_TEXT - 1)


@pytest.mark.parametrize("year", [None, 999, 2101, -5, "2010", 2010.0, True])
def test_a_strange_year_is_no_year(base, year):
    async def work(conn):
        return await book(conn, await _save(conn, year=year))

    assert _run(base, work).year is None


@pytest.mark.parametrize("year", [1000, 1869, 2100])
def test_a_real_year_is_kept(base, year):
    async def work(conn):
        return await book(conn, await _save(conn, year=year))

    assert _run(base, work).year == year


@pytest.mark.parametrize(
    "over",
    [
        {"asset": "nope"},
        {"asset": None},
        {"title": ""},
        {"title": " \n\t "},
        {"title": None},
        {"title": 5},
        {"hint": ""},
        {"hint": "   "},
        {"hint": None},
        {"hint": b"opaque"},
        {"hint": "x" * 8193},
        {"hint": "a\x00bad"},
        {"parts": []},
        {"parts": None},
        {"parts": "mp3"},
        {"parts": 5},
        {"parts": [Part(2, 0, 10, "mp3")]},
        {"parts": [Part(1, 0, 10, "mp3"), Part(3, 1, 10, "mp3")]},
        {"parts": [Part(1, 0, 10, "mp3"), Part(1, 1, 10, "mp3")]},
        {"parts": [Part(1, -1, 10, "mp3")]},
        {"parts": [Part(1, 2**31, 10, "mp3")]},
        {"parts": [Part(1, 0, 0, "mp3")]},
        {"hint": "a\ud800"},
        {"parts": [Part(1, 0, -4, "mp3")]},
        {"parts": [Part(1, 0, 2**63, "mp3")]},
        {"parts": [Part(1, 0, 10, "")]},
        {"parts": [Part(1, 0, 10, "MP3")]},
        {"parts": [Part(1, 0, 10, "../x")]},
        {"parts": [Part(1, 0, 10, "extension")]},
        {"parts": [Part(True, 0, 10, "mp3")]},  # type: ignore[arg-type]
        {"parts": [Part(1, 0, 10.0, "mp3")]},  # type: ignore[arg-type]
        {"parts": [Part(1, 0, 10, "mp3"), object()]},
        {"parts": [{"number": 1, "file_index": 0, "size": 10, "kind": "mp3"}]},
    ],
)
def test_what_cannot_be_a_book_is_not_saved_and_leaves_nothing(base, over):
    async def work(conn):
        result = await _save(conn, **over)
        return (
            result,
            await conn.fetchval("SELECT count(*) FROM books"),
            await conn.fetchval("SELECT count(*) FROM book_parts"),
        )

    assert _run(base, work) == (None, 0, 0)


def test_the_part_limit_itself_is_still_a_book(base):
    async def work(conn):
        book_id = await _save(conn, parts=parts(MAX_BOOK_PARTS))
        over = await _save(conn, OTHER, parts=parts(MAX_BOOK_PARTS + 1))
        return await book(conn, book_id), over, len(await book_parts(conn, book_id))

    saved, over, stored = _run(base, work)
    assert saved.parts == MAX_BOOK_PARTS and stored == MAX_BOOK_PARTS
    assert over is None


def test_parts_may_come_as_any_iterable(base):
    async def work(conn):
        book_id = await _save(conn, parts=iter(parts(2)))
        return await book(conn, book_id)

    assert _run(base, work).parts == 2


def test_a_big_book_keeps_its_exact_size(base):
    big = 3 * 1024**3

    async def work(conn):
        book_id = await _save(conn, parts=[Part(1, 0, big, "m4b")])
        return await book(conn, book_id), await book_parts(conn, book_id)

    saved, stored = _run(base, work)
    assert saved.total_bytes == big
    assert stored == [StoredPart(1, 0, big, "m4b")]


# --- shelf ----------------------------------------------------------------


def test_a_book_goes_on_the_shelf(base):
    async def work(conn):
        book_id = await _save(conn)
        result = await shelve(conn, ANN, book_id, now=NOW + timedelta(hours=1))
        return book_id, result, await shelf(conn, ANN), await shelf(conn, BOB)

    book_id, result, mine, theirs = _run(base, work)
    assert result == "ok"
    assert len(mine) == 1
    assert mine[0].book.id == book_id and mine[0].book.title == "Книга"
    assert mine[0].shelved_at == NOW + timedelta(hours=1)
    assert theirs == []


def test_shelving_twice_says_exists_and_keeps_the_first_time(base):
    async def work(conn):
        book_id = await _save(conn)
        await shelve(conn, ANN, book_id, now=NOW)
        again = await shelve(conn, ANN, book_id, now=NOW + timedelta(days=3))
        return again, await shelf(conn, ANN)

    again, mine = _run(base, work)
    assert again == "exists"
    assert [item.shelved_at for item in mine] == [NOW]


def test_an_unknown_book_or_person_is_unknown(base):
    async def work(conn):
        book_id = await _save(conn)
        return (
            await shelve(conn, ANN, NOBODY, now=NOW),
            await shelve(conn, NOBODY, book_id, now=NOW),
            await conn.fetchval("SELECT count(*) FROM book_shelf"),
        )

    assert _run(base, work) == ("unknown", "unknown", 0)


def test_the_largest_file_number_the_table_holds_is_still_a_book(base):
    async def work(conn):
        book_id = await _save(conn, parts=[Part(1, 2**31 - 1, 10, "mp3")])
        return await book_parts(conn, book_id)

    assert _run(base, work) == [StoredPart(1, 2**31 - 1, 10, "mp3")]


class _PersonGoesAway:
    """Connection where user is deleted an instant before shelving."""

    def __init__(self, conn: asyncpg.Connection, url: str, user: UUID) -> None:
        self._conn, self._url, self._user = conn, url, user

    def __getattr__(self, name: str) -> Any:
        return getattr(self._conn, name)

    async def execute(self, query: str, *args: Any) -> Any:
        if "INSERT INTO book_shelf" in query:
            other = await asyncpg.connect(self._url)
            try:
                await other.execute("DELETE FROM users WHERE id = $1", self._user)
            finally:
                await other.close()
        return await self._conn.execute(query, *args)


def test_a_person_removed_in_the_middle_is_unknown_not_a_crash(base):
    gone = UUID("eeeeeeee-0000-4000-8000-000000000067")

    async def work(conn):
        await conn.execute(
            "INSERT INTO users (id, username) VALUES ($1, 'mid-ft667')", gone
        )
        book_id = await _save(conn)
        result = await shelve(_PersonGoesAway(conn, base, gone), gone, book_id, now=NOW)
        # Connection is functional after this, nothing left on shelves.
        return (
            result,
            await conn.fetchval("SELECT count(*) FROM book_shelf"),
            await shelf_bytes(conn),
        )

    assert _run(base, work) == ("unknown", 0, 0)


def test_the_shelf_shows_the_latest_first(base):
    async def work(conn):
        ids = [await _save(conn, _hash(n), title=f"Книга {n}") for n in range(1, 4)]
        await shelve(conn, ANN, ids[0], now=NOW + timedelta(minutes=2))
        await shelve(conn, ANN, ids[1], now=NOW + timedelta(minutes=3))
        await shelve(conn, ANN, ids[2], now=NOW + timedelta(minutes=1))
        return [item.book.title for item in await shelf(conn, ANN)]

    assert _run(base, work) == ["Книга 2", "Книга 1", "Книга 3"]


def test_books_shelved_at_the_same_moment_keep_a_steady_order(base):
    async def work(conn):
        ids = [await _save(conn, _hash(n)) for n in range(1, 6)]
        for book_id in ids:
            await shelve(conn, ANN, book_id, now=NOW)
        first = [item.book.id for item in await shelf(conn, ANN)]
        second = [item.book.id for item in await shelf(conn, ANN)]
        return ids, first, second

    ids, first, second = _run(base, work)
    assert first == second == sorted(ids)


def test_taking_a_book_off_the_shelf(base):
    async def work(conn):
        book_id = await _save(conn)
        await shelve(conn, ANN, book_id, now=NOW)
        await shelve(conn, BOB, book_id, now=NOW)
        return (
            await unshelve(conn, ANN, book_id),
            await unshelve(conn, ANN, book_id),
            await unshelve(conn, ANN, NOBODY),
            await shelf(conn, ANN),
            len(await shelf(conn, BOB)),
            await book(conn, book_id) is not None,
        )

    assert _run(base, work) == (True, False, False, [], 1, True)


def test_a_book_nobody_keeps_is_still_known(base):
    # File cleanup is a separate card; storage itself does not forget the book.
    async def work(conn):
        book_id = await _save(conn)
        await shelve(conn, ANN, book_id, now=NOW)
        gone = await unshelve(conn, ANN, book_id)
        return (
            gone,
            await book(conn, book_id) is not None,
            len(await book_parts(conn, book_id)),
            await shelve(conn, ANN, book_id, now=NOW),
        )

    assert _run(base, work) == (True, True, 3, "ok")


def test_the_shelf_limit(base, monkeypatch):
    monkeypatch.setattr(books, "MAX_SHELF", 3)

    async def work(conn):
        ids = [await _save(conn, _hash(n)) for n in range(1, 6)]
        results = [await shelve(conn, ANN, book_id, now=NOW) for book_id in ids[:4]]
        other = await shelve(conn, BOB, ids[3], now=NOW)
        await unshelve(conn, ANN, ids[0])
        after = await shelve(conn, ANN, ids[4], now=NOW)
        return results, other, after

    results, other, after = _run(base, work)
    assert results == ["ok", "ok", "ok", "limit"]
    assert other == "ok", "each user has their own limit"
    assert after == "ok"


# --- space ----------------------------------------------------------------


def test_space_counts_each_shelved_book_once(base):
    async def work(conn):
        first = await _save(conn, _hash(1), parts=[Part(1, 0, 700, "mp3")])
        second = await _save(conn, _hash(2), parts=[Part(1, 0, 50, "mp3")])
        await _save(conn, _hash(3), parts=[Part(1, 0, 9000, "mp3")])
        empty = await shelf_bytes(conn)
        await shelve(conn, ANN, first, now=NOW)
        await shelve(conn, BOB, first, now=NOW)
        await shelve(conn, BOB, second, now=NOW)
        return empty, await shelf_bytes(conn)

    assert _run(base, work) == (0, 750)


def test_a_book_over_the_space_limit_is_not_taken(base):
    async def work(conn):
        first = await _save(conn, _hash(1), parts=[Part(1, 0, 600, "mp3")])
        second = await _save(conn, _hash(2), parts=[Part(1, 0, 401, "mp3")])
        exact = await _save(conn, _hash(3), parts=[Part(1, 0, 400, "mp3")])
        return (
            await shelve(conn, ANN, first, space=1000, now=NOW),
            await shelve(conn, ANN, second, space=1000, now=NOW),
            await shelve(conn, BOB, second, space=1000, now=NOW),
            await shelve(conn, ANN, exact, space=1000, now=NOW),
            await shelf_bytes(conn),
            len(await shelf(conn, ANN)),
        )

    assert _run(base, work) == ("ok", "no_space", "no_space", "ok", 1000, 2)


def test_a_book_bigger_than_all_the_space_is_not_taken(base):
    async def work(conn):
        book_id = await _save(conn, parts=[Part(1, 0, 5000, "mp3")])
        return await shelve(conn, ANN, book_id, space=4999, now=NOW), await shelve(
            conn, ANN, book_id, space=0, now=NOW
        )

    assert _run(base, work) == ("no_space", "no_space")


def test_a_book_someone_already_keeps_takes_no_new_space(base):
    async def work(conn):
        book_id = await _save(conn, parts=[Part(1, 0, 900, "mp3")])
        first = await shelve(conn, ANN, book_id, space=1000, now=NOW)
        # Limit has been lowered since — book already exists, costs nothing to second user.
        second = await shelve(conn, BOB, book_id, space=10, now=NOW)
        return first, second, await shelf_bytes(conn)

    assert _run(base, work) == ("ok", "ok", 900)


def test_space_comes_back_when_the_last_reader_lets_go(base):
    async def work(conn):
        first = await _save(conn, _hash(1), parts=[Part(1, 0, 900, "mp3")])
        second = await _save(conn, _hash(2), parts=[Part(1, 0, 900, "mp3")])
        await shelve(conn, ANN, first, space=1000, now=NOW)
        await shelve(conn, BOB, first, space=1000, now=NOW)
        blocked = await shelve(conn, ANN, second, space=1000, now=NOW)
        await unshelve(conn, ANN, first)
        still = await shelve(conn, ANN, second, space=1000, now=NOW)
        await unshelve(conn, BOB, first)
        free = await shelve(conn, ANN, second, space=1000, now=NOW)
        return blocked, still, free

    assert _run(base, work) == ("no_space", "no_space", "ok")


def test_the_default_space_is_twenty_gigabytes(base):
    gigabyte = 1024**3

    async def work(conn):
        ids = [
            await _save(conn, _hash(n), parts=[Part(1, 0, 7 * gigabyte, "m4b")])
            for n in range(1, 4)
        ]
        return [await shelve(conn, ANN, book_id, now=NOW) for book_id in ids]

    assert _run(base, work) == ["ok", "ok", "no_space"]


def test_two_people_at_once_cannot_get_past_the_space_limit(base):
    async def work(_conn):
        conn = await asyncpg.connect(base)
        try:
            ids = [
                await _save(conn, _hash(n), parts=[Part(1, 0, 600, "mp3")])
                for n in range(1, 9)
            ]
        finally:
            await conn.close()

        async def one(user: UUID, book_id: UUID) -> str:
            own = await asyncpg.connect(base)
            try:
                return await shelve(own, user, book_id, space=1000, now=NOW)
            finally:
                await own.close()

        results = await asyncio.gather(
            *[one(ANN if n % 2 else BOB, book_id) for n, book_id in enumerate(ids)]
        )
        conn = await asyncpg.connect(base)
        try:
            return results, await shelf_bytes(conn)
        finally:
            await conn.close()

    results, used = _run(base, work)
    assert sorted(results) == ["no_space"] * 7 + ["ok"]
    assert used == 600


def test_the_same_person_twice_at_once_gets_one_place(base):
    async def work(_conn):
        conn = await asyncpg.connect(base)
        try:
            book_id = await _save(conn)
        finally:
            await conn.close()

        async def one() -> str:
            own = await asyncpg.connect(base)
            try:
                return await shelve(own, ANN, book_id, now=NOW)
            finally:
                await own.close()

        return await asyncio.gather(*[one() for _ in range(6)])

    assert sorted(_run(base, work)) == ["exists"] * 5 + ["ok"]


# --- what cache keeps ----------------------------------------------------


def test_kept_releases_are_those_on_someones_shelf(base):
    async def work(conn):
        first = await _save(conn, _hash(1))
        second = await _save(conn, _hash(2))
        await _save(conn, _hash(3))
        nothing = await kept_assets(conn)
        await shelve(conn, ANN, first, now=NOW)
        await shelve(conn, BOB, first, now=NOW)
        await shelve(conn, BOB, second, now=NOW)
        both = await kept_assets(conn)
        await unshelve(conn, BOB, second)
        await unshelve(conn, BOB, first)
        return nothing, both, await kept_assets(conn)

    assert _run(base, work) == (set(), {_hash(1), _hash(2)}, {_hash(1)})


# --- users and backup ----------------------------------------------------


def test_removing_a_person_empties_the_shelf_and_keeps_the_book(base):
    gone = UUID("dddddddd-0000-4000-8000-000000000067")

    async def work(conn):
        await conn.execute(
            "INSERT INTO users (id, username) VALUES ($1, 'gone-ft667')", gone
        )
        book_id = await _save(conn)
        await shelve(conn, gone, book_id, now=NOW)
        await conn.execute("DELETE FROM users WHERE id = $1", gone)
        return (
            await conn.fetchval("SELECT count(*) FROM book_shelf"),
            await book(conn, book_id) is not None,
            await kept_assets(conn),
        )

    assert _run(base, work) == (0, True, set())


def test_the_migration_can_be_applied_twice(base):
    asyncio.run(apply(base))
    asyncio.run(apply(base))

    async def work(conn):
        return await conn.fetchval("SELECT count(*) FROM books")

    assert _run(base, work) == 0


@pytest.mark.parametrize("script", ["backup.sh", "restore_check.sh"])
def test_books_are_part_of_the_backup(script):
    # A book cannot be rebuilt from foreign catalog — both books and shelves go into backup.
    text = (Path(__file__).resolve().parents[2] / "scripts" / script).read_text()
    line = next(row for row in text.splitlines() if row.startswith("PERSONAL="))
    for table in ("books", "book_parts", "book_shelf"):
        assert f" {table}" in line, f"{table} missing from PERSONAL ({script})"


def test_no_book_text_reaches_the_log(base, caplog):
    async def work(conn):
        book_id = await _save(conn, title="Тайная книга", author="Тайный автор")
        await shelve(conn, ANN, book_id, now=NOW)
        await shelve(conn, ANN, book_id, now=NOW)
        await shelve(conn, ANN, NOBODY, now=NOW)
        await _save(conn, "nope", title="Тайная книга")
        await unshelve(conn, ANN, book_id)

    with caplog.at_level("DEBUG"):
        _run(base, work)
    assert "Тайн" not in caplog.text
    assert HASH not in caplog.text
