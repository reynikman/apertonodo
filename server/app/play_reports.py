"""FT-639 (Р-A96, contract D1): playback report ingestion and delivery queue.

For each song play, the phone provides a unique identifier (listen_id). The server stores
the maximum played milliseconds and enqueues the task once for delivery
to external services (ListenBrainz, Last.fm).
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import TYPE_CHECKING
from uuid import UUID

if TYPE_CHECKING:
    import asyncpg

SERVICES: tuple[str, ...] = ("listenbrainz", "lastfm")

FOUR_MINUTES_MS = 240_000
MIN_TRACK_MS = 30_000

MAX_FUTURE_DELTA = timedelta(minutes=5)
MAX_PAST_DELTA = timedelta(days=14)

PURGE_DELIVERIES_DELTA = timedelta(days=14)
PURGE_REPORTS_DELTA = timedelta(days=30)


def external_due(listened_ms: int, duration_ms: int) -> bool:
    """External service threshold: half of track or 4 minutes; shorter than 30s — never."""
    if duration_ms <= 0:
        return listened_ms >= FOUR_MINUTES_MS
    if duration_ms < MIN_TRACK_MS:
        return False
    return listened_ms >= FOUR_MINUTES_MS or (listened_ms * 2 >= duration_ms)


def settle_started_at(started_at: datetime, now: datetime) -> datetime:
    """Phone playback start time. Without timezone or with skewed clock replaced with now."""
    if started_at.tzinfo is None or started_at.utcoffset() is None:
        return now
    if started_at > now + MAX_FUTURE_DELTA:
        return now
    if started_at < now - MAX_PAST_DELTA:
        return now
    return started_at


@dataclass(frozen=True)
class Reported:
    listened_ms: int
    started_at: datetime
    first: bool
    queued: tuple[str, ...]


def _deleted_count(status: str) -> int:
    parts = status.split()
    return int(parts[1]) if len(parts) >= 2 else 0


async def report(
    conn: asyncpg.Connection,
    user_id: UUID,
    *,
    listen_id: UUID,
    track_id: str,
    started_at: datetime,
    listened_ms: int,
    duration_ms: int,
    paused: bool,
    now: datetime | None = None,
) -> Reported | None:
    """Ingest playback report and enqueue when threshold is reached."""
    if listened_ms < 0:
        raise ValueError("listened_ms cannot be negative")
    if paused:
        return None

    if now is None:
        now = datetime.now(UTC)

    settled_started = settle_started_at(started_at, now)
    duration_to_store = max(0, duration_ms)

    async with conn.transaction():
        row = await conn.fetchrow(
            """
            INSERT INTO play_reports (
                user_id,
                listen_id,
                track_id,
                started_at,
                listened_ms,
                duration_ms,
                received_at
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7)
            ON CONFLICT (user_id, listen_id) DO UPDATE
            SET listened_ms = GREATEST(play_reports.listened_ms, EXCLUDED.listened_ms),
                -- Track duration unknown on first report is taken from the next one:
                -- otherwise the track would wait for 4 minutes instead of half duration.
                duration_ms = CASE WHEN play_reports.duration_ms = 0
                    THEN EXCLUDED.duration_ms ELSE play_reports.duration_ms END
            WHERE play_reports.track_id = EXCLUDED.track_id
            RETURNING listened_ms, started_at, duration_ms, (xmax = 0) AS first
            """,
            user_id,
            listen_id,
            track_id,
            settled_started,
            listened_ms,
            duration_to_store,
            now,
        )
        if row is None:
            return None

        stored_listened_ms: int = row["listened_ms"]
        stored_started_at: datetime = row["started_at"]
        stored_duration_ms: int = row["duration_ms"]
        first: bool = bool(row["first"])

        queued: tuple[str, ...] = ()
        if external_due(stored_listened_ms, stored_duration_ms):
            delivery_rows = await conn.fetch(
                """
                INSERT INTO play_deliveries (
                    user_id,
                    listen_id,
                    service,
                    account_revision,
                    state,
                    attempts,
                    next_try_at,
                    created_at
                )
                SELECT
                    user_id,
                    $2,
                    service,
                    revision,
                    'waiting',
                    0,
                    $3,
                    $3
                FROM scrobble_accounts
                WHERE user_id = $1 AND NOT bad AND service = ANY($4::text[])
                -- Key is being changed right now — wait and take the new revision.
                FOR SHARE
                ON CONFLICT (user_id, listen_id, service) DO NOTHING
                RETURNING service
                """,
                user_id,
                listen_id,
                now,
                list(SERVICES),
            )
            queued = tuple(sorted(r["service"] for r in delivery_rows))

        return Reported(
            listened_ms=stored_listened_ms,
            started_at=stored_started_at,
            first=first,
            queued=queued,
        )


async def drop_waiting(conn: asyncpg.Connection, user_id: UUID) -> int:
    """User enabled "do not scrobble": remove everything not yet sent.

    Rows are not deleted but marked `dropped`: if deleted, the next report
    of the same play (after unpausing) would re-queue it.
    Rows currently being processed (`working`) are cancelled too: a worker batch
    takes up to 20 rows and sends them sequentially — otherwise they would be sent
    after pausing. Only the HTTP request currently in flight cannot be cancelled.
    """
    status = await conn.execute(
        """
        UPDATE play_deliveries SET state = 'dropped'
        WHERE user_id = $1 AND state IN ('waiting', 'retry', 'working')
        """,
        user_id,
    )
    return _deleted_count(status)


async def drop_outdated(conn: asyncpg.Connection) -> int:
    """Delete delivery rows whose account revision changed or service was disabled."""
    status = await conn.execute(
        """
        DELETE FROM play_deliveries d
        WHERE d.state IN ('waiting', 'retry')
          AND NOT EXISTS (
            SELECT 1 FROM scrobble_accounts a
            WHERE a.user_id = d.user_id
              AND a.service = d.service
              AND a.revision = d.account_revision
          )
        """
    )
    return _deleted_count(status)


async def purge(conn: asyncpg.Connection, *, now: datetime | None = None) -> int:
    """Delete failed deliveries older than 14 days and playback reports older than 30 days.

    Sent and refused rows live as long as the report: otherwise
    a late duplicate report would re-queue already delivered scrobbles.
    """
    if now is None:
        now = datetime.now(UTC)

    cutoff_deliveries = now - PURGE_DELIVERIES_DELTA
    cutoff_reports = now - PURGE_REPORTS_DELTA

    async with conn.transaction():
        status = await conn.execute(
            "DELETE FROM play_deliveries WHERE created_at < $1 AND state NOT IN ('sent', 'refused')",
            cutoff_deliveries,
        )
        await conn.execute(
            "DELETE FROM play_reports WHERE received_at < $1",
            cutoff_reports,
        )
        return _deleted_count(status)
