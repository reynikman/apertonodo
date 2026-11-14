"""FT-658: Podcast episode playback progress on the server."""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
import unicodedata
from datetime import datetime, timedelta, timezone
from typing import Any
from uuid import UUID

import asyncpg

MAX_BATCH: int = 500
MAX_ROWS: int = 20_000
MAX_POSITION_MS: int = 7 * 24 * 3600 * 1000
FUTURE_SLACK: timedelta = timedelta(minutes=5)
# Feed URL and episode guid combined form index key, limit is 2704 bytes.
MAX_KEY_BYTES: int = 1024


@dataclass(frozen=True)
class Progress:
    position_ms: int
    done: bool
    updated_at: datetime


@dataclass(frozen=True)
class Entry:
    feed_url: str
    guid: str
    progress: Progress


def newer(a: Progress, b: Progress) -> Progress:
    """Select the newer playback progress record.

    1. Later updated_at (compared as point in time).
    2. When time is equal — completed (done).
    3. When status is equal — larger position_ms.
    4. When completely equal — the first one (a).
    """
    if b.updated_at > a.updated_at:
        return b
    if b.updated_at < a.updated_at:
        return a
    if b.done and not a.done:
        return b
    if a.done and not b.done:
        return a
    if b.position_ms > a.position_ms:
        return b
    if b.position_ms < a.position_ms:
        return a
    return a


def _clean(text: str) -> bool:
    """No control characters or lone surrogates: rejected by DB or phone key."""
    return not any(unicodedata.category(ch) in ("Cc", "Cs") for ch in text)


def from_wire(raw: Any) -> list[Entry] | None:
    """Parse phone request body into list of entries."""
    if not isinstance(raw, dict):
        return None
    items = raw.get("items")
    if not isinstance(items, list):
        return None
    if len(items) > MAX_BATCH:
        return None

    result: list[Entry] = []
    for item in items:
        if not isinstance(item, dict):
            continue

        feed_url = item.get("feed_url")
        if (
            not isinstance(feed_url, str)
            or not (1 <= len(feed_url) <= MAX_KEY_BYTES)
            or not _clean(feed_url)
            or len(feed_url.encode()) > MAX_KEY_BYTES
        ):
            continue

        guid = item.get("guid")
        if (
            not isinstance(guid, str)
            or not (1 <= len(guid) <= MAX_KEY_BYTES)
            or not _clean(guid)
            or len(guid.encode()) > MAX_KEY_BYTES
        ):
            continue

        position_ms = item.get("position_ms")
        if type(position_ms) is not int or not (0 <= position_ms <= MAX_POSITION_MS):
            continue

        done = item.get("done")
        if type(done) is not bool:
            continue

        updated_at_raw = item.get("updated_at")
        if (
            not isinstance(updated_at_raw, str)
            or len(updated_at_raw) > 40
            or not updated_at_raw.endswith("Z")
        ):
            continue

        try:
            updated_at = datetime.fromisoformat(updated_at_raw)
        except Exception:
            continue

        if updated_at.tzinfo is None or updated_at.year < 2000:
            continue

        result.append(
            Entry(
                feed_url=feed_url,
                guid=guid,
                progress=Progress(
                    position_ms=position_ms,
                    done=done,
                    updated_at=updated_at,
                ),
            )
        )

    return result


def to_wire(entries: Sequence[Entry]) -> dict[str, list[dict[str, Any]]]:
    """Format response payload for phone."""
    items: list[dict[str, Any]] = []
    for entry in entries:
        dt = entry.progress.updated_at
        if dt.tzinfo is not None:
            dt_utc = dt.astimezone(timezone.utc)
        else:
            dt_utc = dt.replace(tzinfo=timezone.utc)
        ms = dt_utc.microsecond // 1000
        items.append(
            {
                "feed_url": entry.feed_url,
                "guid": entry.guid,
                "position_ms": entry.progress.position_ms,
                "done": entry.progress.done,
                "updated_at": f"{dt_utc.strftime('%Y-%m-%dT%H:%M:%S')}.{ms:03d}Z",
            }
        )
    return {"items": items}


async def put(
    conn: asyncpg.Connection,
    user_id: UUID,
    entries: Sequence[Entry],
    *,
    now: datetime | None = None,
) -> list[Entry]:
    """Save batch of playback progress entries for user."""
    if not entries:
        return []

    if now is None:
        now = datetime.now(timezone.utc)
    elif now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)

    cutoff = now + FUTURE_SLACK
    deduped: dict[tuple[str, str], Entry] = {}

    for e in entries:
        if (
            e.progress.updated_at.tzinfo is None
            or e.progress.updated_at.utcoffset() is None
        ):
            continue
        cur_updated_at = e.progress.updated_at
        if cur_updated_at > cutoff:
            cur_updated_at = now
        cur_progress = (
            Progress(e.progress.position_ms, e.progress.done, cur_updated_at)
            if cur_updated_at is not e.progress.updated_at
            else e.progress
        )
        key = (e.feed_url, e.guid)
        if key in deduped:
            best_progress = newer(deduped[key].progress, cur_progress)
            deduped[key] = Entry(
                feed_url=e.feed_url, guid=e.guid, progress=best_progress
            )
        else:
            deduped[key] = Entry(
                feed_url=e.feed_url, guid=e.guid, progress=cur_progress
            )

    if len(deduped) > MAX_BATCH:
        raise ValueError("too_many")

    if not deduped:
        return []

    async with conn.transaction():
        user_exists = await conn.fetchval(
            "SELECT 1 FROM users WHERE id = $1 FOR NO KEY UPDATE", user_id
        )
        if not user_exists:
            return []

        items = list(deduped.values())
        feed_urls = [it.feed_url for it in items]
        guids = [it.guid for it in items]
        positions = [it.progress.position_ms for it in items]
        dones = [it.progress.done for it in items]
        updated_ats = [it.progress.updated_at for it in items]

        await conn.execute(
            """
            INSERT INTO podcast_progress
                (user_id, feed_url, guid, position_ms, done, updated_at, seq)
            SELECT
                $1,
                u.feed_url,
                u.guid,
                u.position_ms,
                u.done,
                u.updated_at,
                nextval('podcast_progress_seq')
            FROM unnest(
                $2::text[],
                $3::text[],
                $4::integer[],
                $5::boolean[],
                $6::timestamptz[]
            ) AS u(feed_url, guid, position_ms, done, updated_at)
            ON CONFLICT (user_id, feed_url, guid) DO UPDATE
            SET
                position_ms = EXCLUDED.position_ms,
                done = EXCLUDED.done,
                updated_at = EXCLUDED.updated_at,
                seq = EXCLUDED.seq
            WHERE
                EXCLUDED.updated_at > podcast_progress.updated_at
                OR (
                    EXCLUDED.updated_at = podcast_progress.updated_at
                    AND EXCLUDED.done AND NOT podcast_progress.done
                )
                OR (
                    EXCLUDED.updated_at = podcast_progress.updated_at
                    AND EXCLUDED.done = podcast_progress.done
                    AND EXCLUDED.position_ms > podcast_progress.position_ms
                )
            """,
            user_id,
            feed_urls,
            guids,
            positions,
            dones,
            updated_ats,
        )

        total = await conn.fetchval(
            "SELECT count(*) FROM podcast_progress WHERE user_id = $1", user_id
        )
        await conn.execute(
            """
            DELETE FROM podcast_progress
            WHERE user_id = $1 AND $3 AND (feed_url, guid) IN (
                SELECT feed_url, guid
                FROM podcast_progress
                WHERE user_id = $1
                ORDER BY updated_at DESC, seq DESC
                OFFSET $2
            )
            """,
            user_id,
            MAX_ROWS,
            total > MAX_ROWS,
        )

        rows = await conn.fetch(
            """
            SELECT p.feed_url, p.guid, p.position_ms, p.done, p.updated_at
            FROM podcast_progress p
            JOIN unnest($2::text[], $3::text[]) AS u(feed_url, guid)
              ON p.feed_url = u.feed_url AND p.guid = u.guid
            WHERE p.user_id = $1
            ORDER BY p.feed_url ASC, p.guid ASC
            """,
            user_id,
            feed_urls,
            guids,
        )

        return [
            Entry(
                feed_url=row["feed_url"],
                guid=row["guid"],
                progress=Progress(
                    position_ms=row["position_ms"],
                    done=row["done"],
                    updated_at=row["updated_at"],
                ),
            )
            for row in rows
        ]


async def changes(
    conn: asyncpg.Connection,
    user_id: UUID,
    *,
    after: int = 0,
    limit: int = 500,
) -> tuple[list[Entry], int]:
    """Fetch user playback progress changes after seq."""
    limit = max(1, min(1000, limit))
    after = max(0, min((1 << 63) - 1, after))

    rows = await conn.fetch(
        """
        SELECT feed_url, guid, position_ms, done, updated_at, seq
        FROM podcast_progress
        WHERE user_id = $1 AND seq > $2
        ORDER BY seq ASC
        LIMIT $3
        """,
        user_id,
        after,
        limit,
    )

    if not rows:
        return [], after

    entries = [
        Entry(
            feed_url=row["feed_url"],
            guid=row["guid"],
            progress=Progress(
                position_ms=row["position_ms"],
                done=row["done"],
                updated_at=row["updated_at"],
            ),
        )
        for row in rows
    ]
    return entries, rows[-1]["seq"]


async def of_feed(
    conn: asyncpg.Connection,
    user_id: UUID,
    feed_url: str,
) -> dict[str, Progress]:
    """Fetch user episode playback progress for a specific feed."""
    rows = await conn.fetch(
        """
        SELECT guid, position_ms, done, updated_at
        FROM podcast_progress
        WHERE user_id = $1 AND feed_url = $2
        ORDER BY guid ASC
        """,
        user_id,
        feed_url,
    )
    return {
        row["guid"]: Progress(
            position_ms=row["position_ms"],
            done=row["done"],
            updated_at=row["updated_at"],
        )
        for row in rows
    }
