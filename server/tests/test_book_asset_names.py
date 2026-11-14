"""FT-720 (Bk-0, R-A88, R-A106): books in core use "key asset", not torrent terms.

Source of books is an extension (R-A88, R-A99): core does not know where book comes from, and only stores
opaque key `asset` like `<extension>:<id>` and hint `hint`, which is parsed by
the extension itself. Prior to this card, books relied on `info_hash`, `seeders`,
`source_locator`, and `magnet:` check — words specific to a single source.

Contract:
- `books.normalize_asset(raw) -> str | None` — string without edge whitespace matching
  `^[a-z][a-z0-9-]{0,31}:[A-Za-z0-9._~-]{1,200}$`, id case is preserved;
- `books.BookSource(asset, hint)` — neither field included in `repr`;
- `books.save_book(conn, *, asset, hint, title, parts, author="", narrator="", year=None,
  now=None)` — invalid `asset` or empty `hint` -> `None`;
- `books.kept_assets(conn) -> set[str]` — keys of books shelved on at least one shelf;
- `books` table: columns `asset_key` (unique) and `asset_hint`; migration
  `server/migrations/057_book_asset.sql` renames them (055 already in prod);
- `book_found.FoundBook(title, author, narrator, year, size_bytes, popularity, asset, hint)`,
  `asset` and `hint` not in `repr`; `found_books(hits)` reads `asset`, `hint`,
  `popularity` from finding (rest as before: `title`, `size`); `MAX_HINT` instead of `MAX_LOCATOR`.

What this test does not prove: book extension itself does not exist yet (Bk-1); shelf and
finding behaviors are guarded by earlier tests `test_books.py`, `test_book_found.py` — after
renaming their meaning is preserved.
"""

from __future__ import annotations

import asyncio
import dataclasses
import re
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import asyncpg
import pytest

from app import book_found, books
from app.migrate import apply

SERVER = Path(__file__).resolve().parents[1]
SOURCE_WORDS = re.compile(
    r"info_hash|infohash|seeders|magnet|source_locator|kept_hashes|torrent|btih",
    re.IGNORECASE,
)
NOW = datetime(2026, 10, 10, 12, 0, tzinfo=UTC)


@dataclasses.dataclass(frozen=True)
class Part:
    number: int
    file_index: int
    size: int
    kind: str


PARTS = [Part(n, n, 1000 + n, "mp3") for n in (1, 2)]


# --- source words ------------------------------------------------------------


@pytest.mark.parametrize(
    "path", sorted((SERVER / "app").glob("book*.py")), ids=lambda p: p.name
)
def test_book_code_has_no_source_words(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    found = sorted({m.group(0).lower() for m in SOURCE_WORDS.finditer(text)})
    assert found == [], f"{path.name}: {found}"


def test_migration_055_creates_opaque_columns() -> None:
    # FT-905: a fresh install gets the opaque names straight from 055, 057 has nothing left to rename.
    low = (SERVER / "migrations" / "055_books.sql").read_text(encoding="utf-8").lower()
    assert "asset_key" in low and "asset_hint" in low
    assert not SOURCE_WORDS.search(low)


def test_migration_057_survives_a_second_run(base: str) -> None:
    # Project requirement: migration survives rerun (see 014_images.sql).
    sql = (SERVER / "migrations" / "057_book_asset.sql").read_text(encoding="utf-8")

    async def work(conn: asyncpg.Connection) -> set[str]:
        await conn.execute(sql)
        await conn.execute(sql)
        rows = await conn.fetch(
            "SELECT indexname FROM pg_indexes WHERE tablename = 'books'"
        )
        return {r["indexname"] for r in rows}

    indexes = _run(base, work)
    assert not any("info_hash" in name for name in indexes), indexes


# --- normalize_asset ---------------------------------------------------------


@pytest.mark.parametrize(
    "raw, expected",
    [
        ("othershelf:abc123", "othershelf:abc123"),
        ("  books-x:AbC.d_e~f-9  ", "books-x:AbC.d_e~f-9"),
        ("a:" + "x" * 200, "a:" + "x" * 200),
    ],
)
def test_normalize_asset_accepts(raw: str, expected: str) -> None:
    assert books.normalize_asset(raw) == expected


@pytest.mark.parametrize(
    "raw",
    [
        None,
        42,
        "",
        "abc",
        ":abc",
        "Othershelf:abc",
        "9bt:abc",
        "bt:",
        "bt:a b",
        "bt:a/b",
        "bt:" + "x" * 201,
        "b" + "x" * 32 + ":abc",
        "bt:abc\x00",
    ],
)
def test_normalize_asset_rejects(raw: object) -> None:
    assert books.normalize_asset(raw) is None


def test_old_names_are_gone() -> None:
    for name in ("normalize_info_hash", "kept_hashes"):
        assert not hasattr(books, name), name
    assert not hasattr(book_found, "MAX_LOCATOR")
    assert book_found.MAX_HINT == 8192


def test_book_source_fields_and_repr() -> None:
    names = [f.name for f in dataclasses.fields(books.BookSource)]
    assert names == ["asset", "hint"]
    src = books.BookSource("bt:secret-number", "secret-hint")
    assert "secret" not in repr(src)


# --- database ----------------------------------------------------------------


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
    _run(postgres_url, lambda c: c.execute("TRUNCATE books CASCADE"))
    return postgres_url


def test_books_table_has_asset_columns(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> set[str]:
        rows = await conn.fetch(
            "SELECT column_name FROM information_schema.columns"
            " WHERE table_name = 'books'"
        )
        return {r["column_name"] for r in rows}

    cols = _run(base, work)
    assert {"asset_key", "asset_hint"} <= cols
    assert not cols & {"info_hash", "source_locator"}


def test_save_and_read_back_by_asset(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> Any:
        first = await books.save_book(
            conn,
            asset=" bt:Abc-1 ",
            hint="opaque-1",
            title="Книга",
            parts=PARTS,
            now=NOW,
        )
        again = await books.save_book(
            conn, asset="bt:Abc-1", hint="opaque-2", title="Книга", parts=PARTS, now=NOW
        )
        source = await books.book_source(conn, first)
        # Not on any shelf — nothing to keep.
        kept = await books.kept_assets(conn)
        return first, again, source, kept

    first, again, source, kept = _run(base, work)
    assert first is not None and again == first
    assert source == books.BookSource("bt:Abc-1", "opaque-1")
    assert kept == set()


@pytest.mark.parametrize(
    "over",
    [
        {"asset": "not an asset"},
        {"asset": None},
        {"hint": ""},
        {"hint": "   "},
        {"hint": 7},
    ],
)
def test_save_rejects_bad_asset_or_hint(base: str, over: dict[str, object]) -> None:
    values: dict[str, Any] = {
        "asset": "bt:ok",
        "hint": "opaque",
        "title": "Книга",
        "parts": PARTS,
        "now": NOW,
    }
    values.update(over)

    async def work(conn: asyncpg.Connection) -> Any:
        saved = await books.save_book(conn, **values)
        count = await conn.fetchval("SELECT count(*) FROM books")
        return saved, count

    assert _run(base, work) == (None, 0)


# --- findings ----------------------------------------------------------------

MB = 1024**2


def hit(asset: object = "bt:one", **over: object) -> dict[str, object]:
    raw: dict[str, object] = {
        "asset": asset,
        "hint": "opaque",
        "popularity": 5,
        "size": 100 * MB,
        "title": "Толстой Лев - Война и мир [Клюквин Александр, 2011, 128 kbps, MP3]",
    }
    raw.update(over)
    return raw


def test_found_book_fields_and_repr() -> None:
    names = [f.name for f in dataclasses.fields(book_found.FoundBook)]
    assert names == [
        "title",
        "author",
        "narrator",
        "year",
        "size_bytes",
        "popularity",
        "asset",
        "hint",
        "language",
    ]
    found = book_found.found_books([hit("bt:secret-asset", hint="secret-hint")])
    assert len(found) == 1
    assert "secret" not in repr(found[0])


def test_found_books_reads_asset_hint_popularity() -> None:
    found = book_found.found_books([hit("bt:one", hint="h1", popularity=7)])
    assert [(b.asset, b.hint, b.popularity) for b in found] == [("bt:one", "h1", 7)]


def test_found_books_ranks_by_popularity_and_merges_same_asset() -> None:
    found = book_found.found_books(
        [
            hit("bt:low", popularity=2),
            hit("bt:high", popularity=9),
            hit("bt:low", popularity=4),
            hit("bt:unknown", popularity=None),
        ]
    )
    assert [(b.asset, b.popularity) for b in found] == [
        ("bt:high", 9),
        ("bt:low", 4),
        ("bt:unknown", None),
    ]


@pytest.mark.parametrize(
    "bad",
    [
        hit("not an asset"),
        hit(None),
        hit("bt:x", popularity=0),
        hit("bt:x", hint="a\x00b"),
        hit("bt:x", hint="h" * 8193),
        hit("bt:x", hint=5),
    ],
)
def test_found_books_skips_bad_hits(bad: dict[str, object]) -> None:
    assert book_found.found_books([bad]) == []


def test_found_books_skips_a_hint_the_base_cannot_store() -> None:
    # Half of surrogate pair: save_book rejects it — don't show such finding.
    assert book_found.found_books([hit("bt:x", hint="a\ud800")]) == []


def test_found_books_hint_is_opaque() -> None:
    # Core does not parse hint: any non-empty extension string passes.
    found = book_found.found_books([hit("bt:x", hint="anything://at/all?x=1")])
    assert [b.hint for b in found] == ["anything://at/all?x=1"]


def test_found_books_without_hint_is_skipped() -> None:
    # Without hint extension cannot retrieve book — don't show such finding.
    raw = hit("bt:x")
    del raw["hint"]
    assert book_found.found_books([raw]) == []
