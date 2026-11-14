"""FT-657 (Р-A93, block B-5): podcast feeds, episodes, and subscriptions in DB."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import TYPE_CHECKING, Any
from urllib.parse import urlsplit, urlunsplit
from uuid import UUID

if TYPE_CHECKING:
    import asyncpg

    from app.podcast_feed import Podcast

MAX_SUBSCRIPTIONS = 500
MAX_STORED_EPISODES = 2000
REFRESH_EVERY = timedelta(hours=1)
# Feed URL and episode guid together form index key, whose limit is 2704 bytes.
MAX_KEY_BYTES = 1024
BACKOFF = (
    timedelta(hours=1),
    timedelta(hours=3),
    timedelta(hours=12),
    timedelta(hours=24),
)


@dataclass(frozen=True)
class Subscription:
    feed_url: str
    title: str | None
    author: str
    image: str | None
    episodes: int
    newest_at: datetime | None
    added_at: datetime
    language: str | None = None


@dataclass(frozen=True)
class StoredEpisode:
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


def backoff(failures: int) -> timedelta:
    if failures <= 1:
        return BACKOFF[0]
    if failures >= len(BACKOFF):
        return BACKOFF[-1]
    return BACKOFF[failures - 1]


def normalize_feed_url(raw: Any) -> str | None:
    if not isinstance(raw, str):
        return None
    s = raw.strip()
    if not s or len(s) > 2048:
        return None
    if any(ch.isspace() or not ch.isprintable() for ch in s):
        return None
    try:
        u = urlsplit(s)
        port = u.port
    except Exception:
        return None
    scheme = u.scheme.lower()
    if scheme not in ("http", "https"):
        return None
    if not u.hostname:
        return None
    if u.username or u.password or "@" in u.netloc:
        return None
    if port is not None and not (1 <= port <= 65535):
        return None
    host = u.hostname.lower()
    if ":" in host:
        host = f"[{host}]"
    if port is not None:
        if (scheme == "http" and port == 80) or (scheme == "https" and port == 443):
            netloc = host
        else:
            netloc = f"{host}:{port}"
    else:
        netloc = host
    path = u.path
    if not path:
        path = "/"
    res = urlunsplit((scheme, netloc, path, u.query, ""))
    if len(res.encode()) > MAX_KEY_BYTES:
        return None
    return res


async def subscribe(
    conn: asyncpg.Connection,
    user_id: UUID,
    feed_url: str,
    *,
    now: datetime | None = None,
) -> str:
    clean = normalize_feed_url(feed_url)
    if clean is None:
        return "bad_url"
    if now is None:
        now = datetime.now(timezone.utc)
    async with conn.transaction():
        await conn.execute("SELECT 1 FROM users WHERE id = $1 FOR UPDATE", user_id)
        exists = await conn.fetchval(
            "SELECT 1 FROM podcast_subscriptions WHERE user_id = $1 AND feed_url = $2",
            user_id,
            clean,
        )
        if exists:
            return "exists"
        count = await conn.fetchval(
            "SELECT count(*) FROM podcast_subscriptions WHERE user_id = $1",
            user_id,
        )
        if count >= MAX_SUBSCRIPTIONS:
            return "limit"
        await conn.execute(
            "INSERT INTO podcast_subscriptions (user_id, feed_url, added_at) "
            "VALUES ($1, $2, $3) ON CONFLICT (user_id, feed_url) DO NOTHING",
            user_id,
            clean,
            now,
        )
        return "ok"


async def unsubscribe(
    conn: asyncpg.Connection,
    user_id: UUID,
    feed_url: str,
) -> bool:
    clean = normalize_feed_url(feed_url)
    if clean is None:
        return False
    status = await conn.execute(
        "DELETE FROM podcast_subscriptions WHERE user_id = $1 AND feed_url = $2",
        user_id,
        clean,
    )
    return status == "DELETE 1"


async def subscriptions(
    conn: asyncpg.Connection,
    user_id: UUID,
) -> list[Subscription]:
    rows = await conn.fetch(
        """
        SELECT
            s.feed_url,
            CASE WHEN f.fetched_at IS NULL THEN NULL ELSE f.title END AS title,
            COALESCE(f.author, '') AS author,
            f.image,
            COALESCE(ep.episodes, 0)::integer AS episodes,
            ep.newest_at,
            s.added_at,
            f.language
        FROM podcast_subscriptions s
        LEFT JOIN podcast_feeds f ON f.feed_url = s.feed_url
        LEFT JOIN LATERAL (
            SELECT
                count(*)::integer AS episodes,
                max(e.published) AS newest_at
            FROM podcast_episodes e
            WHERE e.feed_url = s.feed_url
        ) ep ON true
        WHERE s.user_id = $1
        ORDER BY
            ep.newest_at DESC NULLS LAST,
            s.added_at DESC,
            s.feed_url ASC
        """,
        user_id,
    )
    return [
        Subscription(
            feed_url=r["feed_url"],
            title=r["title"],
            author=r["author"],
            image=r["image"],
            episodes=r["episodes"],
            newest_at=r["newest_at"],
            added_at=r["added_at"],
            language=r["language"],
        )
        for r in rows
    ]


async def episodes(
    conn: asyncpg.Connection,
    user_id: UUID,
    feed_url: str,
    *,
    limit: int = 50,
    offset: int = 0,
) -> list[StoredEpisode] | None:
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
    rows = await conn.fetch(
        """
        SELECT
            guid, title, description, audio_url, audio_type,
            audio_bytes, duration_ms, published, image, season,
            number, explicit
        FROM podcast_episodes
        WHERE feed_url = $1
        ORDER BY published DESC NULLS LAST, place ASC, guid ASC
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


async def save_feed(
    conn: asyncpg.Connection,
    feed_url: str,
    podcast: Podcast,
    *,
    now: datetime | None = None,
) -> bool:
    clean = normalize_feed_url(feed_url)
    if clean is None:
        return False
    if now is None:
        now = datetime.now(timezone.utc)
    next_fetch = now + REFRESH_EVERY
    seen_guids: set[str] = set()
    episodes_to_save = []
    for ep in podcast.episodes:
        if len(ep.guid.encode()) > MAX_KEY_BYTES:
            continue
        if ep.guid not in seen_guids:
            seen_guids.add(ep.guid)
            episodes_to_save.append(ep)
        if len(episodes_to_save) == MAX_STORED_EPISODES:
            break

    async with conn.transaction():
        await conn.execute(
            """
            INSERT INTO podcast_feeds (
                feed_url, title, author, description, image, link,
                fetched_at, failures, next_fetch_at, language
            ) VALUES ($1, $2, $3, $4, $5, $6, $7, 0, $8, $9)
            ON CONFLICT (feed_url) DO UPDATE SET
                title = EXCLUDED.title,
                author = EXCLUDED.author,
                description = EXCLUDED.description,
                image = EXCLUDED.image,
                link = EXCLUDED.link,
                fetched_at = EXCLUDED.fetched_at,
                failures = 0,
                next_fetch_at = EXCLUDED.next_fetch_at,
                language = EXCLUDED.language
            """,
            clean,
            podcast.title,
            podcast.author,
            podcast.description,
            podcast.image,
            podcast.link,
            now,
            next_fetch,
            podcast.language,
        )
        if episodes_to_save:
            current_guids = [e.guid for e in episodes_to_save]
            await conn.execute(
                """
                UPDATE podcast_episodes
                SET place = 10000 + r.rn
                FROM (
                    SELECT guid, ROW_NUMBER() OVER (ORDER BY place, first_seen_at) AS rn
                    FROM podcast_episodes
                    WHERE feed_url = $1 AND NOT (guid = ANY($2::text[]))
                ) r
                WHERE podcast_episodes.feed_url = $1 AND podcast_episodes.guid = r.guid
                """,
                clean,
                current_guids,
            )
            batch = [
                (
                    clean,
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
                    idx,
                    now,
                )
                for idx, e in enumerate(episodes_to_save)
            ]
            await conn.executemany(
                """
                INSERT INTO podcast_episodes (
                    feed_url, guid, title, description, audio_url, audio_type,
                    audio_bytes, duration_ms, published, image, season,
                    number, explicit, place, first_seen_at
                ) VALUES (
                    $1, $2, $3, $4, $5, $6,
                    $7, $8, $9, $10, $11,
                    $12, $13, $14, $15
                )
                ON CONFLICT (feed_url, guid) DO UPDATE SET
                    title = EXCLUDED.title,
                    description = EXCLUDED.description,
                    audio_url = EXCLUDED.audio_url,
                    audio_type = EXCLUDED.audio_type,
                    audio_bytes = EXCLUDED.audio_bytes,
                    duration_ms = EXCLUDED.duration_ms,
                    published = EXCLUDED.published,
                    image = EXCLUDED.image,
                    season = EXCLUDED.season,
                    number = EXCLUDED.number,
                    explicit = EXCLUDED.explicit,
                    place = EXCLUDED.place
                """,
                batch,
            )
            await conn.execute(
                """
                DELETE FROM podcast_episodes
                WHERE feed_url = $1
                  AND guid IN (
                      SELECT guid
                      FROM podcast_episodes
                      WHERE feed_url = $1
                      ORDER BY published DESC NULLS LAST, place ASC, guid ASC
                      OFFSET $2
                  )
                """,
                clean,
                MAX_STORED_EPISODES,
            )
    return True


async def mark_failed(
    conn: asyncpg.Connection,
    feed_url: str,
    *,
    now: datetime | None = None,
) -> None:
    clean = normalize_feed_url(feed_url)
    if clean is None:
        return
    if now is None:
        now = datetime.now(timezone.utc)
    async with conn.transaction():
        row = await conn.fetchrow(
            "SELECT failures FROM podcast_feeds WHERE feed_url = $1 FOR UPDATE",
            clean,
        )
        if row is None:
            new_failures = 1
            next_fetch = now + backoff(new_failures)
            await conn.execute(
                """
                INSERT INTO podcast_feeds (
                    feed_url, title, author, description, fetched_at,
                    failures, next_fetch_at
                ) VALUES ($1, '', '', '', NULL, $2, $3)
                ON CONFLICT (feed_url) DO UPDATE SET
                    failures = podcast_feeds.failures + 1,
                    next_fetch_at = $3
                """,
                clean,
                new_failures,
                next_fetch,
            )
        else:
            new_failures = row["failures"] + 1
            next_fetch = now + backoff(new_failures)
            await conn.execute(
                "UPDATE podcast_feeds SET failures = $2, next_fetch_at = $3 WHERE feed_url = $1",
                clean,
                new_failures,
                next_fetch,
            )


async def due(
    conn: asyncpg.Connection,
    *,
    now: datetime | None = None,
    limit: int = 20,
) -> list[str]:
    if now is None:
        now = datetime.now(timezone.utc)
    eff_limit = max(1, min(limit, 100))
    rows = await conn.fetch(
        """
        SELECT s.feed_url
        FROM (
            SELECT DISTINCT feed_url FROM podcast_subscriptions
        ) s
        LEFT JOIN podcast_feeds f ON f.feed_url = s.feed_url
        WHERE f.feed_url IS NULL OR f.next_fetch_at <= $1
        ORDER BY
            CASE WHEN f.fetched_at IS NULL THEN 0 ELSE 1 END ASC,
            f.next_fetch_at ASC NULLS FIRST,
            s.feed_url ASC
        LIMIT $2
        """,
        now,
        eff_limit,
    )
    return [r["feed_url"] for r in rows]


async def purge_orphans(conn: asyncpg.Connection) -> int:
    res = await conn.execute(
        """
        DELETE FROM podcast_feeds
        WHERE feed_url NOT IN (SELECT feed_url FROM podcast_subscriptions)
        """
    )
    try:
        return int(res.split()[-1])
    except (IndexError, ValueError):
        return 0
