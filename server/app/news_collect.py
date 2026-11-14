"""FT-573 (Р-A83): periodic collection of RSS and Atom news and purging expired items."""

from __future__ import annotations

import json
import logging
import os
from collections.abc import Awaitable, Callable
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

import asyncpg

from app import news_rss, news_telegram

logger = logging.getLogger("apertonodo")

DEFAULT_CURATED_FILE = Path(__file__).resolve().parent / "data" / "news_channels.json"


def load_curated_channels(path: str | Path | None = None) -> list[dict[str, Any]]:
    """Load curated channels list from a JSON file.

    Admin can override the path via NEWS_CHANNELS_FILE env var.
    """
    if path is None:
        env_file = os.environ.get("NEWS_CHANNELS_FILE")
        p = Path(env_file) if env_file else DEFAULT_CURATED_FILE
    else:
        p = Path(path)

    if not p.is_file():
        return []
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
        if isinstance(data, list):
            return data
    except Exception as exc:  # noqa: BLE001
        logger.warning("news_collect: curated file error: %s", type(exc).__name__)
    return []


async def _default_fetch(url: str) -> bytes:
    from app import news_fetch

    result = await news_fetch.fetch(url)
    if result.status >= 400:
        raise ValueError(f"HTTP {result.status}")
    return result.body


async def collect_once(
    database_url: str,
    *,
    fetch: Callable[[str], Awaitable[bytes]] | None = None,
    curated: list[dict[str, Any]] | None = None,
) -> int:
    """Single pass of news collection.

    Crawls curated channels and users' custom channels from `news_channels`.
    A broken channel does not crash the others.
    Returns count of newly added entries.
    """
    if fetch is None:
        fetch = _default_fetch

    if curated is None:
        curated = load_curated_channels()

    conn = await asyncpg.connect(database_url)
    try:
        own_rows = await conn.fetch("SELECT DISTINCT feed_url, name, kind FROM news_channels")

        channels_to_fetch: dict[str, dict[str, Any]] = {}
        for c in curated:
            feed_url = c.get("feed_url")
            if feed_url:
                channels_to_fetch[feed_url] = {
                    "name": c.get("name", ""),
                    "feed_url": feed_url,
                    "kind": c.get("kind", "rss"),
                    "is_curated": True,
                }

        for row in own_rows:
            feed_url = row["feed_url"]
            if feed_url in channels_to_fetch:
                # Already in list, is_curated flag remains True
                pass
            else:
                channels_to_fetch[feed_url] = {
                    "name": row["name"],
                    "feed_url": feed_url,
                    "kind": row["kind"],
                    "is_curated": False,
                }

        new_count = 0
        for idx, ch in enumerate(channels_to_fetch.values()):
            kind = ch.get("kind")
            try:
                raw = await fetch(ch["feed_url"])
                if kind == "telegram" or "t.me/" in ch["feed_url"]:
                    items = news_telegram.parse_channel(raw)
                    if not items:
                        logger.warning("news_collect: channel %d (telegram) returned no posts", idx)
                else:
                    items = news_rss.parse_feed(raw)
            except Exception as exc:  # noqa: BLE001
                # Do not write channel URL or name to log
                logger.warning("news_collect: channel %d failed: %s", idx, type(exc).__name__)
                continue

            for item in items:
                link = item.get("link")
                title = item.get("title")
                if not link or not title:
                    continue
                pub = item.get("published") or datetime.now(timezone.utc)
                channel_name = ch["name"] or item.get("channel") or ""

                row = await conn.fetchrow(
                    """
                    INSERT INTO news_items (feed_url, channel, title, text, link, image_url, published, is_curated)
                    VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
                    ON CONFLICT (link) DO UPDATE SET is_curated = news_items.is_curated OR EXCLUDED.is_curated
                    RETURNING (xmax = 0) AS inserted
                    """,
                    ch["feed_url"],
                    channel_name,
                    title,
                    item.get("text") or "",
                    link,
                    item.get("image"),
                    pub,
                    ch["is_curated"],
                )
                if row and row["inserted"]:
                    new_count += 1

        logger.info("news_collect: cycle complete, %d channels, %d new items", len(channels_to_fetch), new_count)
        return new_count
    finally:
        await conn.close()


async def purge_news(database_url: str, *, now: datetime | None = None) -> int:
    """Purge news older than 14 days. Returns count of deleted entries."""
    if now is None:
        now = datetime.now(timezone.utc)
    cutoff = now - timedelta(days=14)

    conn = await asyncpg.connect(database_url)
    try:
        tag = await conn.execute("DELETE FROM news_items WHERE published < $1", cutoff)
        parts = tag.split()
        count = int(parts[1]) if len(parts) == 2 else 0
        logger.info("news_collect: purged %d expired news items", count)
        return count
    finally:
        await conn.close()
