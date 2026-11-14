"""FT-724 (K1, P-A99, contract D5a): found release -> book on the shelf.

Fetching files happens before writing and outside a transaction; writing the book
and placing it on the shelf is a single transaction, so on failure neither book nor parts remain.
The module logs nothing about the book.
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from datetime import datetime
from typing import Any
from uuid import UUID

import asyncpg

from app import books
from app.book_found import FoundBook
from app.book_parts import BookTooLong, book_parts

__all__ = ["Outcome", "shelve_found"]

FilesFetcher = Callable[[str, str], Awaitable[Any]]


@dataclass(frozen=True, slots=True)
class Outcome:
    state: str
    book: books.Book | None = None


class _Refused(Exception):
    """Write rollback: carries the outcome to be returned outward."""

    def __init__(self, outcome: Outcome) -> None:
        super().__init__()
        self.outcome = outcome


async def _placed(
    conn: asyncpg.Connection,
    user_id: UUID,
    book_id: UUID,
    space: int,
    now: datetime | None,
) -> Outcome:
    state = await books.shelve(conn, user_id, book_id, space=space, now=now)
    if state not in ("ok", "exists"):
        return Outcome(state)
    return Outcome(state, await books.book(conn, book_id))


async def shelve_found(
    conn: asyncpg.Connection,
    user_id: UUID,
    found: FoundBook,
    *,
    files: FilesFetcher,
    space: int = books.DEFAULT_BOOK_SPACE,
    now: datetime | None = None,
) -> Outcome:
    asset = books.normalize_asset(found.asset)
    if asset is None:
        return Outcome("not_a_book")

    known = await conn.fetchval("SELECT id FROM books WHERE asset_key = $1", asset)
    if known is not None:
        return await _placed(conn, user_id, known, space, now)

    try:
        listing = await files(asset, found.hint)
    except Exception:
        return Outcome("unavailable")
    if listing is None:
        return Outcome("unavailable")

    try:
        parts = book_parts(listing)
    except BookTooLong:
        return Outcome("not_a_book")
    if not parts:
        return Outcome("not_a_book")

    try:
        async with conn.transaction():
            book_id = await books.save_book(
                conn,
                asset=asset,
                hint=found.hint,
                title=found.title,
                parts=parts,
                author=found.author,
                narrator=found.narrator,
                year=found.year,
                now=now,
            )
            if book_id is None:
                raise _Refused(Outcome("not_a_book"))
            outcome = await _placed(conn, user_id, book_id, space, now)
            if outcome.book is None:
                raise _Refused(outcome)
            return outcome
    except _Refused as refused:
        return refused.outcome
