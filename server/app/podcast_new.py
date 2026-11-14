"""FT-729: episodes "from first" and new subscription episodes."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import TYPE_CHECKING
from uuid import UUID

from app.podcasts import StoredEpisode, normalize_feed_url

if TYPE_CHECKING:
    import asyncpg

ORDERS: tuple[str, ...] = ("newest", "oldest")
PER_FEED: int = 3
MAX_NEW: int = 100

__all__ = [
    "MAX_NEW",
    "ORDERS",
    "PER_FEED",
    "NewEpisode",
    "episodes_ordered",
    "new_episodes",
]


@dataclass(frozen=True)
class NewEpisode:
    guid: str
    title: str
    description: str
    audio_url: str
    audio_type: str | None
    audio_bytes: int | None
    duration_ms: int | None
    published: datetime | None
    image: str | None
    season: int | None
    number: int | None
    explicit: bool
    feed_url: str
    feed_title: str


async def episodes_ordered(
    conn: asyncpg.Connection,
    user_id: UUID,
    feed_url: str,
    *,
    order: str,
    limit: int = 50,
    offset: int = 0,
) -> list[StoredEpisode] | None:
    if order not in ORDERS:
        raise ValueError(f"Unknown order: {order!r}")
    clean = normalize_feed_url(feed_url)
    if clean is None:
        return None
    is_subscribed = await conn.fetchval(
        "SELECT 1 FROM podcast_subscriptions WHERE user_id = $1 AND feed_url = $2",
        user_id,
        clean,
    )
    if not is_subscribed:
        return None
    eff_limit = max(1, min(limit, 200))
    eff_offset = max(0, offset)
    order_clause = (
        "published DESC NULLS LAST, place ASC, guid ASC"
        if order == "newest"
        else "published ASC NULLS LAST, place DESC, guid DESC"
    )
    rows = await conn.fetch(
        f"""
        SELECT
            guid, title, description, audio_url, audio_type,
            audio_bytes, duration_ms, published, image, season,
            number, explicit
        FROM podcast_episodes
        WHERE feed_url = $1
        ORDER BY {order_clause}
        LIMIT $2 OFFSET $3
        """,
        clean,
        eff_limit,
        eff_offset,
    )
    return [
        StoredEpisode(
            guid=r["guid"],
            title=r["title"],
            description=r["description"],
            audio_url=r["audio_url"],
            audio_type=r["audio_type"],
            audio_bytes=r["audio_bytes"],
            duration_ms=r["duration_ms"],
            published=r["published"],
            image=r["image"],
            season=r["season"],
            number=r["number"],
            explicit=r["explicit"],
        )
        for r in rows
    ]


async def new_episodes(
    conn: asyncpg.Connection,
    user_id: UUID,
    *,
    since: datetime | None,
    limit: int = 30,
) -> list[NewEpisode]:
    eff_limit = max(1, min(limit, MAX_NEW))
    rows = await conn.fetch(
        """
        WITH ranked AS (
            SELECT
                e.guid,
                e.title,
                e.description,
                e.audio_url,
                e.audio_type,
                e.audio_bytes,
                e.duration_ms,
                e.published,
                e.image,
                e.season,
                e.number,
                e.explicit,
                e.place,
                s.feed_url,
                COALESCE(f.title, '') AS feed_title,
                ROW_NUMBER() OVER (
                    PARTITION BY s.feed_url
                    ORDER BY e.published DESC, e.place ASC, e.guid ASC
                ) AS rn
            FROM podcast_subscriptions s
            JOIN podcast_feeds f ON f.feed_url = s.feed_url
            JOIN podcast_episodes e ON e.feed_url = s.feed_url
            WHERE s.user_id = $1
              AND e.published IS NOT NULL
              AND ($2::timestamptz IS NULL OR e.published > $2::timestamptz)
        )
        SELECT
            guid,
            title,
            description,
            audio_url,
            audio_type,
            audio_bytes,
            duration_ms,
            published,
            image,
            season,
            number,
            explicit,
            feed_url,
            feed_title
        FROM ranked
        WHERE rn <= $3
        ORDER BY published DESC, place ASC, guid ASC
        LIMIT $4
        """,
        user_id,
        since,
        PER_FEED,
        eff_limit,
    )
    return [
        NewEpisode(
            guid=r["guid"],
            title=r["title"],
            description=r["description"],
            audio_url=r["audio_url"],
            audio_type=r["audio_type"],
            audio_bytes=r["audio_bytes"],
            duration_ms=r["duration_ms"],
            published=r["published"],
            image=r["image"],
            season=r["season"],
            number=r["number"],
            explicit=r["explicit"],
            feed_url=r["feed_url"],
            feed_title=r["feed_title"],
        )
        for r in rows
    ]
