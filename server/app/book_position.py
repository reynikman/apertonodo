"""FT-673: audiobook playback position on the server."""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any
from uuid import UUID

import asyncpg

MAX_BATCH: int = 500
MAX_ROWS: int = 5000
MAX_PART: int = 3000
MAX_POSITION_MS: int = 30 * 24 * 3600 * 1000
FUTURE_SLACK: timedelta = timedelta(minutes=5)


@dataclass(frozen=True)
class Position:
    part: int
    position_ms: int
    finished: bool
    updated_at: datetime


@dataclass(frozen=True)
class Entry:
    book_id: UUID
    position: Position


def newer(a: Position, b: Position) -> Position:
    """Select the fresher record: timestamp, finished state, part number, position."""
    if b.updated_at != a.updated_at:
        return b if b.updated_at > a.updated_at else a
    if b.finished != a.finished:
        return b if b.finished else a
    if b.part != a.part:
        return b if b.part > a.part else a
    if b.position_ms > a.position_ms:
        return b
    return a


def _book_id(value: Any) -> UUID | None:
    if not isinstance(value, str) or len(value) != 36 or not value.isascii():
        return None
    try:
        return UUID(value)
    except ValueError:
        return None


def from_wire(raw: Any) -> list[Entry] | None:
    """Parse request body from the phone; invalid entries are skipped."""
    if not isinstance(raw, dict):
        return None
    items = raw.get("items")
    if not isinstance(items, list) or len(items) > MAX_BATCH:
        return None

    result: list[Entry] = []
    for item in items:
        if not isinstance(item, dict):
            continue
        book_id = _book_id(item.get("book_id"))
        if book_id is None:
            continue
        part = item.get("part")
        if type(part) is not int or not (1 <= part <= MAX_PART):
            continue
        position_ms = item.get("position_ms")
        if type(position_ms) is not int or not (0 <= position_ms <= MAX_POSITION_MS):
            continue
        finished = item.get("finished")
        if type(finished) is not bool:
            continue
        stamp = item.get("updated_at")
        if not isinstance(stamp, str) or len(stamp) > 40 or not stamp.endswith("Z"):
            continue
        try:
            updated_at = datetime.fromisoformat(stamp)
        except ValueError:
            continue
        if updated_at.tzinfo is None or updated_at.year < 2000:
            continue
        result.append(Entry(book_id, Position(part, position_ms, finished, updated_at)))
    return result


def to_wire(entries: Sequence[Entry]) -> dict[str, list[dict[str, Any]]]:
    """Format response for the phone."""
    items: list[dict[str, Any]] = []
    for entry in entries:
        p = entry.position
        dt = p.updated_at
        dt = (
            dt.astimezone(timezone.utc)
            if dt.tzinfo is not None
            else dt.replace(tzinfo=timezone.utc)
        )
        items.append(
            {
                "book_id": str(entry.book_id),
                "part": p.part,
                "position_ms": p.position_ms,
                "finished": p.finished,
                "updated_at": f"{dt.strftime('%Y-%m-%dT%H:%M:%S')}"
                f".{dt.microsecond // 1000:03d}Z",
            }
        )
    return {"items": items}


def _entry(row: asyncpg.Record) -> Entry:
    return Entry(
        row["book_id"],
        Position(row["part"], row["position_ms"], row["finished"], row["updated_at"]),
    )


async def put(
    conn: asyncpg.Connection,
    user_id: UUID,
    entries: Sequence[Entry],
    *,
    now: datetime | None = None,
) -> list[Entry]:
    """Save a batch of positions; the newer one remains in the database."""
    if now is None:
        now = datetime.now(timezone.utc)
    elif now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)
    cutoff = now + FUTURE_SLACK

    deduped: dict[UUID, Position] = {}
    for e in entries:
        pos = e.position
        if pos.updated_at.tzinfo is None or pos.updated_at.utcoffset() is None:
            continue
        if pos.updated_at > cutoff:
            pos = Position(pos.part, pos.position_ms, pos.finished, now)
        prev = deduped.get(e.book_id)
        deduped[e.book_id] = pos if prev is None else newer(prev, pos)

    if len(deduped) > MAX_BATCH:
        raise ValueError("too_many")
    if not deduped:
        return []

    ids = list(deduped)
    poss = [deduped[i] for i in ids]

    async with conn.transaction():
        # NO KEY UPDATE: shelf and listens for the same user do not wait.
        # Lock is held until the end of write, so seq grows in commit order.
        if not await conn.fetchval(
            "SELECT 1 FROM users WHERE id = $1 FOR NO KEY UPDATE", user_id
        ):
            return []

        await conn.execute(
            """
            INSERT INTO book_position
                (user_id, book_id, part, position_ms, finished, updated_at, seq)
            SELECT $1, u.book_id, u.part, u.position_ms, u.finished,
                   u.updated_at, nextval('book_position_seq')
            FROM unnest(
                $2::uuid[], $3::integer[], $4::bigint[], $5::boolean[],
                $6::timestamptz[]
            ) AS u(book_id, part, position_ms, finished, updated_at)
            JOIN books b ON b.id = u.book_id
            ON CONFLICT (user_id, book_id) DO UPDATE
            SET part = EXCLUDED.part,
                position_ms = EXCLUDED.position_ms,
                finished = EXCLUDED.finished,
                updated_at = EXCLUDED.updated_at,
                seq = EXCLUDED.seq
            WHERE (EXCLUDED.updated_at, EXCLUDED.finished, EXCLUDED.part,
                   EXCLUDED.position_ms)
                > (book_position.updated_at, book_position.finished,
                   book_position.part, book_position.position_ms)
            """,
            user_id,
            ids,
            [p.part for p in poss],
            [p.position_ms for p in poss],
            [p.finished for p in poss],
            [p.updated_at for p in poss],
        )

        await conn.execute(
            """
            DELETE FROM book_position
            WHERE user_id = $1 AND book_id IN (
                SELECT book_id FROM book_position
                WHERE user_id = $1
                ORDER BY updated_at DESC, seq DESC
                OFFSET $2
            )
            """,
            user_id,
            MAX_ROWS,
        )

        rows = await conn.fetch(
            """
            SELECT p.book_id, p.part, p.position_ms, p.finished, p.updated_at
            FROM book_position p
            WHERE p.user_id = $1 AND p.book_id = ANY($2::uuid[])
            ORDER BY p.book_id
            """,
            user_id,
            ids,
        )
        return [_entry(r) for r in rows]


async def changes(
    conn: asyncpg.Connection,
    user_id: UUID,
    *,
    after: int = 0,
    limit: int = 500,
) -> tuple[list[Entry], int]:
    """Records with seq greater than `after` and the new watermark."""
    limit = max(1, min(1000, limit))
    after = max(0, min((1 << 63) - 1, after))
    rows = await conn.fetch(
        """
        SELECT book_id, part, position_ms, finished, updated_at, seq
        FROM book_position
        WHERE user_id = $1 AND seq > $2
        ORDER BY seq
        LIMIT $3
        """,
        user_id,
        after,
        limit,
    )
    if not rows:
        return [], after
    return [_entry(r) for r in rows], rows[-1]["seq"]


async def of_books(
    conn: asyncpg.Connection,
    user_id: UUID,
    book_ids: Sequence[UUID],
) -> dict[UUID, Position]:
    """User positions for the given books."""
    ids = list(dict.fromkeys(book_ids))[:MAX_ROWS]
    if not ids:
        return {}
    rows = await conn.fetch(
        """
        SELECT book_id, part, position_ms, finished, updated_at
        FROM book_position
        WHERE user_id = $1 AND book_id = ANY($2::uuid[])
        """,
        user_id,
        ids,
    )
    return {r["book_id"]: _entry(r).position for r in rows}
