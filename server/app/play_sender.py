"""FT-641 (Р-A96, Р-A97, contract D1, items 10–12): playback queue sender.

Processes `play_deliveries` queue: acquires rows for work, verifies token,
sends to external services (ListenBrainz), records outcome and retries
failures with exponential backoff.
"""

from __future__ import annotations

import logging
from collections.abc import Awaitable, Callable, Mapping
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from uuid import UUID

import asyncpg
import httpx

from app.scrobble import LISTENBRAINZ_URL, Listen, _payload

logger = logging.getLogger("apertonodo")

LEASE: timedelta = timedelta(minutes=10)

BACKOFF: tuple[timedelta, ...] = (
    timedelta(minutes=1),
    timedelta(minutes=5),
    timedelta(minutes=30),
    timedelta(hours=2),
    timedelta(hours=6),
)


def backoff(attempts: int) -> timedelta:
    """Backoff pause after attempt number `attempts` (1-indexed)."""
    if attempts < 1:
        return BACKOFF[0]
    if attempts >= len(BACKOFF):
        return BACKOFF[-1]
    return BACKOFF[attempts - 1]


@dataclass(frozen=True)
class Song:
    artist: str
    title: str
    duration_ms: int


@dataclass(frozen=True)
class Job:
    user_id: UUID
    listen_id: UUID
    service: str
    account_revision: int
    attempts: int
    track_id: str
    started_at: datetime


Sender = Callable[[str, Listen], Awaitable[str]]
Lookup = Callable[[str], Awaitable[Song | None]]


async def take(
    conn: asyncpg.Connection,
    *,
    now: datetime,
    limit: int = 20,
) -> list[Job]:
    """Acquire queue rows for processing in a single query."""
    if now.tzinfo is None or now.utcoffset() is None:
        now = now.replace(tzinfo=UTC)

    rows = await conn.fetch(
        """
        WITH selected AS (
            SELECT user_id, listen_id, service, next_try_at, created_at
            FROM play_deliveries
            WHERE next_try_at <= $1
              AND state IN ('waiting', 'retry', 'working')
            ORDER BY next_try_at ASC, created_at ASC, user_id ASC, listen_id ASC, service ASC
            LIMIT $2
            FOR UPDATE SKIP LOCKED
        ),
        updated AS (
            UPDATE play_deliveries d
            SET state = 'working',
                attempts = d.attempts + 1,
                next_try_at = $3
            FROM selected s
            WHERE d.user_id = s.user_id
              AND d.listen_id = s.listen_id
              AND d.service = s.service
            RETURNING d.user_id, d.listen_id, d.service, d.account_revision, d.attempts,
                      s.next_try_at AS orig_next_try_at, s.created_at AS orig_created_at
        )
        SELECT u.user_id, u.listen_id, u.service, u.account_revision, u.attempts,
               r.track_id, r.started_at
        FROM updated u
        JOIN play_reports r ON r.user_id = u.user_id AND r.listen_id = u.listen_id
        ORDER BY u.orig_next_try_at ASC, u.orig_created_at ASC, u.user_id ASC, u.listen_id ASC, u.service ASC
        """,
        now,
        limit,
        now + LEASE,
    )
    return [
        Job(
            user_id=row["user_id"],
            listen_id=row["listen_id"],
            service=row["service"],
            account_revision=int(row["account_revision"]),
            attempts=int(row["attempts"]),
            track_id=str(row["track_id"]),
            started_at=row["started_at"],
        )
        for row in rows
    ]


async def deliver(
    conn: asyncpg.Connection,
    job: Job,
    *,
    senders: Mapping[str, Sender],
    lookup: Lookup,
    now: datetime,
) -> str:
    """Deliver a single listen entry to an external service."""
    if now.tzinfo is None or now.utcoffset() is None:
        now = now.replace(tzinfo=UTC)

    # 0. Is the entry still ours? While requests for previous pass entries were running,
    #    pause ("do not record") might have removed it or another pass claimed it — then send nothing outside.
    mine = await conn.fetchval(
        """
        SELECT 1 FROM play_deliveries
        WHERE user_id = $1 AND listen_id = $2 AND service = $3
          AND state = 'working' AND attempts = $4
        """,
        job.user_id,
        job.listen_id,
        job.service,
        job.attempts,
    )
    if mine is None:
        return "outdated"

    # 1. User account connection to service (scrobble_accounts).
    #    Missing or revision != job.account_revision -> entry deleted, "outdated", send nothing outside.
    account = await conn.fetchrow(
        "SELECT token, bad, revision FROM scrobble_accounts WHERE user_id = $1 AND service = $2",
        job.user_id,
        job.service,
    )
    if account is None or int(account["revision"]) != job.account_revision:
        await conn.execute(
            """
            DELETE FROM play_deliveries
            WHERE user_id = $1 AND listen_id = $2 AND service = $3
              AND state = 'working' AND attempts = $4
            """,
            job.user_id,
            job.listen_id,
            job.service,
            job.attempts,
        )
        return "outdated"

    # 2. bad -> entry refused, "bad_token", send nothing outside.
    if account["bad"]:
        await conn.execute(
            """
            UPDATE play_deliveries
            SET state = 'refused'
            WHERE user_id = $1 AND listen_id = $2 AND service = $3
              AND state = 'working' AND attempts = $4
            """,
            job.user_id,
            job.listen_id,
            job.service,
            job.attempts,
        )
        return "bad_token"

    # 3. No such service in senders -> entry retry, next_try_at = now + backoff(job.attempts), "no_sender".
    sender = senders.get(job.service)
    if sender is None:
        await conn.execute(
            """
            UPDATE play_deliveries
            SET state = 'retry', next_try_at = $5
            WHERE user_id = $1 AND listen_id = $2 AND service = $3
              AND state = 'working' AND attempts = $4
            """,
            job.user_id,
            job.listen_id,
            job.service,
            job.attempts,
            now + backoff(job.attempts),
        )
        return "no_sender"

    # 4. lookup(job.track_id): exception -> retry with same delay, "retry"; None -> refused, "no_song".
    try:
        song = await lookup(job.track_id)
    except Exception:
        await conn.execute(
            """
            UPDATE play_deliveries
            SET state = 'retry', next_try_at = $5
            WHERE user_id = $1 AND listen_id = $2 AND service = $3
              AND state = 'working' AND attempts = $4
            """,
            job.user_id,
            job.listen_id,
            job.service,
            job.attempts,
            now + backoff(job.attempts),
        )
        return "retry"

    if song is None:
        await conn.execute(
            """
            UPDATE play_deliveries
            SET state = 'refused'
            WHERE user_id = $1 AND listen_id = $2 AND service = $3
              AND state = 'working' AND attempts = $4
            """,
            job.user_id,
            job.listen_id,
            job.service,
            job.attempts,
        )
        return "no_song"

    # 5. sender(token, Listen(artist, title, duration_ms, played_at=job.started_at))
    #    song start time, not "now". Sender exception or unrecognized word -> treated as "retry".
    listen_obj = Listen(
        artist=song.artist,
        title=song.title,
        duration_ms=song.duration_ms,
        played_at=job.started_at,
    )
    token = str(account["token"])
    try:
        word = await sender(token, listen_obj)
    except Exception:
        word = "retry"

    if word not in ("sent", "refused", "retry", "bad_token"):
        word = "retry"

    # 6. Outcome:
    #    "sent" -> sent
    #    "refused" -> refused (do not touch account)
    #    "retry" -> retry, next_try_at = now + backoff(job.attempts)
    #    "bad_token" -> entry refused and account bad = true — only if its
    #                   revision is still equal to job.account_revision
    if word == "sent":
        await conn.execute(
            """
            UPDATE play_deliveries
            SET state = 'sent'
            WHERE user_id = $1 AND listen_id = $2 AND service = $3
              AND state = 'working' AND attempts = $4
            """,
            job.user_id,
            job.listen_id,
            job.service,
            job.attempts,
        )
        return "sent"

    if word == "refused":
        await conn.execute(
            """
            UPDATE play_deliveries
            SET state = 'refused'
            WHERE user_id = $1 AND listen_id = $2 AND service = $3
              AND state = 'working' AND attempts = $4
            """,
            job.user_id,
            job.listen_id,
            job.service,
            job.attempts,
        )
        return "refused"

    if word == "retry":
        await conn.execute(
            """
            UPDATE play_deliveries
            SET state = 'retry', next_try_at = $5
            WHERE user_id = $1 AND listen_id = $2 AND service = $3
              AND state = 'working' AND attempts = $4
            """,
            job.user_id,
            job.listen_id,
            job.service,
            job.attempts,
            now + backoff(job.attempts),
        )
        return "retry"

    # word == "bad_token"
    async with conn.transaction():
        await conn.execute(
            """
            UPDATE play_deliveries
            SET state = 'refused'
            WHERE user_id = $1 AND listen_id = $2 AND service = $3
              AND state = 'working' AND attempts = $4
            """,
            job.user_id,
            job.listen_id,
            job.service,
            job.attempts,
        )
        await conn.execute(
            """
            UPDATE scrobble_accounts
            SET bad = true
            WHERE user_id = $1 AND service = $2 AND revision = $3
            """,
            job.user_id,
            job.service,
            job.account_revision,
        )
    return "bad_token"


async def run_once(
    conn: asyncpg.Connection,
    *,
    senders: Mapping[str, Sender],
    lookup: Lookup,
    now: datetime | None = None,
    limit: int = 20,
) -> dict[str, int]:
    """Single queue drain pass."""
    if now is None:
        now = datetime.now(UTC)
    elif now.tzinfo is None or now.utcoffset() is None:
        now = now.replace(tzinfo=UTC)

    jobs = await take(conn, now=now, limit=limit)
    if not jobs:
        return {}

    counts: dict[str, int] = {}
    retry_services: set[str] = set()

    for job in jobs:
        if job.service in retry_services:
            try:
                await conn.execute(
                    """
                    UPDATE play_deliveries
                    SET state = 'retry',
                        attempts = attempts - 1,
                        next_try_at = $5
                    WHERE user_id = $1 AND listen_id = $2 AND service = $3
                      AND state = 'working' AND attempts = $4
                    """,
                    job.user_id,
                    job.listen_id,
                    job.service,
                    job.attempts,
                    now + timedelta(minutes=1),
                )
                counts["skipped"] = counts.get("skipped", 0) + 1
            except asyncpg.PostgresError:
                counts["failed"] = counts.get("failed", 0) + 1
                logger.info("play delivery %s failed", job.service)
            continue

        try:
            word = await deliver(conn, job, senders=senders, lookup=lookup, now=now)
        except asyncpg.PostgresError:
            counts["failed"] = counts.get("failed", 0) + 1
            logger.info("play delivery %s failed", job.service)
            continue

        counts[word] = counts.get(word, 0) + 1
        if word == "retry":
            retry_services.add(job.service)

        logger.info("play delivery %s %s", job.service, word)

    return counts


def listenbrainz(client: httpx.AsyncClient) -> Sender:
    """ListenBrainz delivery sender."""

    async def send(token: str, listen: Listen) -> str:
        try:
            response = await client.post(
                LISTENBRAINZ_URL,
                headers={"Authorization": f"Token {token}"},
                json=_payload(listen),
            )
        except httpx.HTTPError:
            return "retry"

        if response.status_code == 200:
            return "sent"
        if response.status_code == 401:
            return "bad_token"
        if response.status_code == 400:
            return "refused"
        return "retry"

    return send
