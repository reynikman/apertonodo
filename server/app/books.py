"""FT-667 (P-A99, contract D5): audiobooks, their parts and personal shelves in the database.

FT-720 (P-A88): the core does not know where a book comes from. It stores an opaque
`asset` key (`<extension>:<id>`) and a `hint`, which is parsed by the extension itself.
They are returned only by `book_source` (for the server); `Book`, `ShelfBook`
and `StoredPart` do not carry them. The connection comes from outside, the module does
not open it and logs nothing.
"""

from __future__ import annotations

import re
from collections.abc import Iterable
from dataclasses import dataclass, field
from datetime import UTC, datetime
from itertools import islice
from typing import Any
from uuid import UUID, uuid4

import asyncpg

MAX_SHELF = 500
MAX_BOOK_PARTS = 3000
MAX_BOOK_TEXT = 500
DEFAULT_BOOK_SPACE = 20 * 1024**3

_MAX_HINT = 8192
_MAX_PART_SIZE = 2**62
_MAX_FILE_INDEX = 2**31 - 1  # column file_index is integer
_MAX_TOTAL = 2**63 - 1
# A single shared lock for space checking: the limit is shared across the whole server.
_SPACE_LOCK = 1111838539

_ASSET = re.compile(r"[a-z][a-z0-9-]{0,31}:[A-Za-z0-9._~-]{1,200}")
_KIND = re.compile(r"[a-z0-9]{1,8}")


@dataclass(frozen=True)
class Book:
    id: UUID
    title: str
    author: str
    narrator: str
    year: int | None
    total_bytes: int
    parts: int
    added_at: datetime


@dataclass(frozen=True)
class ShelfBook:
    book: Book
    shelved_at: datetime


@dataclass(frozen=True)
class StoredPart:
    number: int
    file_index: int
    size: int
    kind: str


@dataclass(frozen=True)
class BookSource:
    asset: str = field(repr=False)
    hint: str = field(repr=False)


def normalize_asset(raw: object) -> str | None:
    if not isinstance(raw, str):
        return None
    clean = raw.strip()
    return clean if _ASSET.fullmatch(clean) else None


def _text(raw: object) -> str:
    if not isinstance(raw, str):
        return ""
    spaced = "".join(c if c.isprintable() else " " for c in raw)
    return " ".join(spaced.split())[:MAX_BOOK_TEXT].rstrip()


def _is_int(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _clean_parts(raw: object) -> list[tuple[int, int, int, str]] | None:
    if isinstance(raw, str | bytes) or not isinstance(raw, Iterable):
        return None
    clean: list[tuple[int, int, int, str]] = []
    for item in islice(raw, MAX_BOOK_PARTS + 1):
        number = getattr(item, "number", None)
        file_index = getattr(item, "file_index", None)
        size = getattr(item, "size", None)
        kind = getattr(item, "kind", None)
        if (
            not isinstance(number, int)
            or isinstance(number, bool)
            or number != len(clean) + 1
            or not isinstance(file_index, int)
            or isinstance(file_index, bool)
            or not 0 <= file_index <= _MAX_FILE_INDEX
            or not isinstance(size, int)
            or isinstance(size, bool)
            or not 1 <= size <= _MAX_PART_SIZE
            or not isinstance(kind, str)
            or not _KIND.fullmatch(kind)
        ):
            return None
        clean.append((number, file_index, size, kind))
    if not 1 <= len(clean) <= MAX_BOOK_PARTS:
        return None
    return clean


async def save_book(
    conn: asyncpg.Connection,
    *,
    asset: object,
    hint: object,
    title: object,
    parts: object,
    author: object = "",
    narrator: object = "",
    year: object = None,
    now: datetime | None = None,
) -> UUID | None:
    key = normalize_asset(asset)
    name = _text(title)
    if key is None or not name:
        return None
    if not isinstance(hint, str):
        return None
    clean_hint = hint.strip()
    if not clean_hint or len(clean_hint) > _MAX_HINT or "\x00" in clean_hint:
        return None
    try:
        clean_hint.encode()
    except UnicodeError:
        # Lone surrogate: the database will reject it, and its rejection message would reveal the hint.
        return None
    rows = _clean_parts(parts)
    if rows is None:
        return None
    total = sum(row[2] for row in rows)
    if total > _MAX_TOTAL:
        return None
    clean_year = year if _is_int(year) and 1000 <= year <= 2100 else None  # type: ignore[operator]

    book_id = uuid4()
    async with conn.transaction():
        inserted = await conn.fetchval(
            "INSERT INTO books (id, asset_key, asset_hint, title, author, narrator,"
            " year, total_bytes, part_count, added_at)"
            " VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)"
            " ON CONFLICT (asset_key) DO NOTHING RETURNING id",
            book_id,
            key,
            clean_hint,
            name,
            _text(author),
            _text(narrator),
            clean_year,
            total,
            len(rows),
            now or datetime.now(UTC),
        )
        if inserted is None:
            return await conn.fetchval("SELECT id FROM books WHERE asset_key = $1", key)
        await conn.executemany(
            "INSERT INTO book_parts (book_id, number, file_index, size, kind)"
            " VALUES ($1, $2, $3, $4, $5)",
            [(book_id, *row) for row in rows],
        )
    return book_id


_BOOK_COLUMNS = "id, title, author, narrator, year, total_bytes, part_count, added_at"


def _book(row: Any) -> Book:
    return Book(
        id=row["id"],
        title=row["title"],
        author=row["author"],
        narrator=row["narrator"],
        year=row["year"],
        total_bytes=row["total_bytes"],
        parts=row["part_count"],
        added_at=row["added_at"],
    )


async def book(conn: asyncpg.Connection, book_id: UUID) -> Book | None:
    row = await conn.fetchrow(
        f"SELECT {_BOOK_COLUMNS} FROM books WHERE id = $1", book_id
    )
    return _book(row) if row else None


async def book_parts(conn: asyncpg.Connection, book_id: UUID) -> list[StoredPart]:
    rows = await conn.fetch(
        "SELECT number, file_index, size, kind FROM book_parts WHERE book_id = $1 ORDER BY number",
        book_id,
    )
    return [
        StoredPart(r["number"], r["file_index"], r["size"], r["kind"]) for r in rows
    ]


async def book_source(conn: asyncpg.Connection, book_id: UUID) -> BookSource | None:
    row = await conn.fetchrow(
        "SELECT asset_key, asset_hint FROM books WHERE id = $1", book_id
    )
    return BookSource(row["asset_key"], row["asset_hint"]) if row else None


async def shelf_bytes(conn: asyncpg.Connection) -> int:
    return int(
        await conn.fetchval(
            "SELECT COALESCE(SUM(total_bytes), 0)::bigint FROM books"
            " WHERE EXISTS (SELECT 1 FROM book_shelf s WHERE s.book_id = books.id)"
        )
    )


async def kept_assets(conn: asyncpg.Connection) -> set[str]:
    rows = await conn.fetch(
        "SELECT asset_key FROM books"
        " WHERE EXISTS (SELECT 1 FROM book_shelf s WHERE s.book_id = books.id)"
    )
    return {r["asset_key"] for r in rows}


async def shelve(
    conn: asyncpg.Connection,
    user_id: UUID,
    book_id: UUID,
    *,
    space: int = DEFAULT_BOOK_SPACE,
    now: datetime | None = None,
) -> str:
    try:
        async with conn.transaction():
            await conn.execute("SELECT pg_advisory_xact_lock($1)", _SPACE_LOCK)
            size = await conn.fetchval(
                "SELECT total_bytes FROM books WHERE id = $1", book_id
            )
            known = await conn.fetchval("SELECT 1 FROM users WHERE id = $1", user_id)
            if size is None or known is None:
                return "unknown"
            if await conn.fetchval(
                "SELECT 1 FROM book_shelf WHERE user_id = $1 AND book_id = $2",
                user_id,
                book_id,
            ):
                return "exists"
            if (
                await conn.fetchval(
                    "SELECT count(*) FROM book_shelf WHERE user_id = $1", user_id
                )
                >= MAX_SHELF
            ):
                return "limit"
            kept = await conn.fetchval(
                "SELECT 1 FROM book_shelf WHERE book_id = $1 LIMIT 1", book_id
            )
            if kept is None and await shelf_bytes(conn) + size > space:
                return "no_space"
            await conn.execute(
                "INSERT INTO book_shelf (user_id, book_id, added_at) VALUES ($1, $2, $3)",
                user_id,
                book_id,
                now or datetime.now(UTC),
            )
            return "ok"
    except asyncpg.ForeignKeyViolationError:
        # The user was deleted between check and insert.
        return "unknown"


async def unshelve(conn: asyncpg.Connection, user_id: UUID, book_id: UUID) -> bool:
    status = await conn.execute(
        "DELETE FROM book_shelf WHERE user_id = $1 AND book_id = $2", user_id, book_id
    )
    return status.endswith(" 1")


async def shelf(conn: asyncpg.Connection, user_id: UUID) -> list[ShelfBook]:
    rows = await conn.fetch(
        "SELECT b.id, b.title, b.author, b.narrator, b.year, b.total_bytes, b.part_count,"
        " b.added_at, s.added_at AS shelved_at"
        " FROM book_shelf s JOIN books b ON b.id = s.book_id"
        " WHERE s.user_id = $1 ORDER BY s.added_at DESC, b.id",
        user_id,
    )
    return [ShelfBook(_book(r), r["shelved_at"]) for r in rows]
