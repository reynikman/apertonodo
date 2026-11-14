"""FT-755: podcast episodes for "Continue" section."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import TYPE_CHECKING
from uuid import UUID

if TYPE_CHECKING:
    import asyncpg

MAX_CONTINUE: int = 100

__all__ = [
    "MAX_CONTINUE",
    "ContinueEpisode",
    "continue_episodes",
]


@dataclass(frozen=True)
class ContinueEpisode:
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
    position_ms: int


async def continue_episodes(
    conn: asyncpg.Connection,
    user_id: UUID,
    *,
    limit: int = 20,
) -> list[ContinueEpisode]:
    eff_limit = max(1, min(limit, MAX_CONTINUE))
    rows = await conn.fetch(
        """
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
            p.feed_url,
            COALESCE(f.title, '') AS feed_title,
            p.position_ms
        FROM podcast_progress p
        JOIN podcast_episodes e ON e.feed_url = p.feed_url AND e.guid = p.guid
        LEFT JOIN podcast_feeds f ON f.feed_url = p.feed_url
        WHERE p.user_id = $1
          AND NOT p.done
          AND p.position_ms > 0
        ORDER BY p.updated_at DESC, p.seq DESC
        LIMIT $2
        """,
        user_id,
        eff_limit,
    )
    return [
        ContinueEpisode(
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
            position_ms=r["position_ms"],
        )
        for r in rows
    ]
