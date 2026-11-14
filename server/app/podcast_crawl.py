"""FT-660 (Р-A93, block B-5): podcast feed crawler."""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Awaitable, Callable
from datetime import UTC, datetime

import asyncpg

from app import news_fetch, podcasts
from app.podcast_feed import parse_podcast

MAX_FEED_BYTES: int = 8 * 1024 * 1024
FEED_TIMEOUT_S: float = 30.0
PER_PASS: int = 20

logger = logging.getLogger("apertonodo")


class FeedUnavailable(Exception):
    """Feed is unavailable or returned status other than 200."""


async def default_fetch(url: str) -> bytes:
    result = await news_fetch.fetch(
        url, max_bytes=MAX_FEED_BYTES, timeout=FEED_TIMEOUT_S
    )
    if result.status != 200:
        raise FeedUnavailable
    return result.body


async def refresh_one(
    conn: asyncpg.Connection,
    feed_url: str,
    *,
    fetch: Callable[[str], Awaitable[bytes]] = default_fetch,
    now: datetime | None = None,
) -> str:
    if podcasts.normalize_feed_url(feed_url) is None:
        return "bad_url"
    if now is None:
        now = datetime.now(UTC)

    try:
        async with asyncio.timeout(FEED_TIMEOUT_S):
            raw = await fetch(feed_url)
    except asyncio.CancelledError:
        raise
    except Exception:
        await podcasts.mark_failed(conn, feed_url, now=now)
        return "failed"

    if not isinstance(raw, (bytes, bytearray)) or len(raw) > MAX_FEED_BYTES:
        await podcasts.mark_failed(conn, feed_url, now=now)
        return "failed"

    if isinstance(raw, bytearray):
        raw = bytes(raw)

    try:
        podcast = await asyncio.to_thread(parse_podcast, raw)
    except asyncio.CancelledError:
        raise
    except Exception:
        await podcasts.mark_failed(conn, feed_url, now=now)
        return "not_a_feed"

    if podcast is None:
        await podcasts.mark_failed(conn, feed_url, now=now)
        return "not_a_feed"

    await podcasts.save_feed(conn, feed_url, podcast, now=now)
    return "saved"


async def run_once(
    conn: asyncpg.Connection,
    *,
    fetch: Callable[[str], Awaitable[bytes]] = default_fetch,
    now: datetime | None = None,
    limit: int = PER_PASS,
) -> dict[str, int]:
    if now is None:
        now = datetime.now(UTC)
    feeds = await podcasts.due(conn, now=now, limit=limit)
    if not feeds:
        return {"saved": 0, "failed": 0, "not_a_feed": 0}

    counts = {"saved": 0, "failed": 0, "not_a_feed": 0}
    for feed_url in feeds:
        try:
            status = await refresh_one(conn, feed_url, fetch=fetch, now=now)
        except asyncio.CancelledError:
            raise
        except (asyncpg.PostgresError, asyncpg.InterfaceError, OSError):
            counts["failed"] += 1
            continue

        if status == "saved":
            counts["saved"] += 1
        elif status == "not_a_feed":
            counts["not_a_feed"] += 1
        else:
            counts["failed"] += 1

    logger.info(
        "podcast crawl saved=%d failed=%d not_a_feed=%d",
        counts["saved"],
        counts["failed"],
        counts["not_a_feed"],
    )
    return counts
