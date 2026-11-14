"""News subscriptions (Р-A83, FT-571, FT-573): artists, custom channels, and news feed.

Boundaries enforced here:

- Subscriptions are read and modified only by their owner — like favorites
  (app/library.py). Another user cannot see others' subscriptions.
- Neither artist name, channel URL, nor title enters the log: the log line is
  database error type; contents of subscriptions and news never enter it (docs/logs.md, Р-A83).
- `NEWS_ENABLED=0` is the admin master switch: every `/v1/news*` route responds
  with 200 `{"enabled": false}`, and the news collector does not start.
- `NEWS_COLLECT=0` turns off periodic collection (used in tests).
- `GET /v1/news` — news from curated channels by subscription, everything from custom channels,
  and fresh releases of subscribed artists from our local MusicBrainz copy (FT-574):
  `article` / `release` cards, newest first, up to 50.
- `GET /v1/photos/news/{news_id}` — serves news images downloaded by the server.
"""

from __future__ import annotations

import asyncio
import html
import logging
import re
import threading
import time
import urllib.parse
import xml.etree.ElementTree as ET
from collections.abc import Mapping
from datetime import date, timedelta
from html.parser import HTMLParser
from typing import Any
from uuid import UUID

import asyncpg
from fastapi import APIRouter, BackgroundTasks, FastAPI, Request
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel

from app.news_fetch import NewsFetchRefused

logger = logging.getLogger("apertonodo")

DISABLED = {"enabled": False}
NOT_FOUND = {"status": "not_found"}
COLLECT_INTERVAL_S = 1800.0


class Unavailable(Exception):
    """No database."""


class ArtistIn(BaseModel):
    artist_id: UUID


class ChannelIn(BaseModel):
    link: str


class ChannelRemoveIn(BaseModel):
    id: str


class CuratedIn(BaseModel):
    id: str
    enabled: bool


class _AlternateFeedFinder(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.feed_url: str | None = None
        self.feed_title: str | None = None
        self.html_title: str | None = None
        self._in_title = False
        self._title_pieces: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        tag_lower = tag.lower()
        if tag_lower == "link" and not self.feed_url:
            adict = {k.lower(): (v or "") for k, v in attrs}
            rel_tokens = adict.get("rel", "").lower().split()
            type_attr = adict.get("type", "").lower()
            href = adict.get("href", "").strip()
            if "alternate" in rel_tokens and href:
                if "application/rss+xml" in type_attr or "application/atom+xml" in type_attr:
                    self.feed_url = href
                    self.feed_title = adict.get("title", "").strip() or None
        elif tag_lower == "title":
            self._in_title = True

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() == "title":
            self._in_title = False
            self.html_title = "".join(self._title_pieces).strip()

    def handle_data(self, data: str) -> None:
        if self._in_title:
            self._title_pieces.append(data)


def _extract_feed_title(raw: bytes) -> str | None:
    try:
        root = ET.fromstring(raw)
    except Exception:
        return None
    rtag = root.tag.split("}")[-1].lower()
    if rtag == "feed":
        for child in root:
            if child.tag.split("}")[-1].lower() == "title" and child.text:
                return html.unescape(child.text.strip())
    elif rtag in ("rss", "rdf"):
        for item in root.iter():
            if item.tag.split("}")[-1].lower() == "channel":
                for child in item:
                    if child.tag.split("}")[-1].lower() == "title" and child.text:
                        return html.unescape(child.text.strip())
        for child in root.iter():
            if child.tag.split("}")[-1].lower() == "title" and child.text:
                return html.unescape(child.text.strip())
    return None


def _is_feed(raw: bytes) -> bool:
    try:
        root = ET.fromstring(raw)
    except Exception:
        return False
    tag = root.tag.split("}")[-1].lower()
    return tag in ("rss", "feed", "rdf")


async def _fetch_bytes(fetch_fn: Any, url: str) -> bytes:
    res = await fetch_fn(url)
    return res.body if hasattr(res, "body") else res


async def resolve_channel_link(link: str, fetch_fn: Any) -> tuple[str, str, str]:
    """Resolve a link into a channel (kind, feed_url, name)."""
    clean_link = link.strip()
    if not clean_link:
        raise ValueError("empty link")

    # 1. Telegram: @channel, t.me/channel, https://t.me/channel
    if clean_link.startswith("@"):
        channel_name = clean_link[1:].strip().strip("/")
        if not channel_name:
            raise ValueError("invalid telegram channel")
        feed_url = f"https://t.me/s/{channel_name}"
        kind = "telegram"
        raw = await _fetch_bytes(fetch_fn, feed_url)
        name = channel_name
        m_title = re.search(r"<title[^>]*>(.*?)</title>", raw.decode("utf-8", errors="replace"), re.IGNORECASE | re.DOTALL)
        if m_title:
            raw_title = html.unescape(m_title.group(1)).strip()
            cleaned = re.sub(r"\s*[-–—]\s*Telegram.*$", "", raw_title, flags=re.IGNORECASE).strip()
            if cleaned:
                name = cleaned
        return kind, feed_url, name

    m_tg = re.search(r"(?:https?://)?(?:www\.)?t\.me/(?:s/)?([A-Za-z0-9_]+)", clean_link, re.IGNORECASE)
    if m_tg:
        channel_name = m_tg.group(1).strip()
        feed_url = f"https://t.me/s/{channel_name}"
        kind = "telegram"
        raw = await _fetch_bytes(fetch_fn, feed_url)
        name = channel_name
        m_title = re.search(r"<title[^>]*>(.*?)</title>", raw.decode("utf-8", errors="replace"), re.IGNORECASE | re.DOTALL)
        if m_title:
            raw_title = html.unescape(m_title.group(1)).strip()
            cleaned = re.sub(r"\s*[-–—]\s*Telegram.*$", "", raw_title, flags=re.IGNORECASE).strip()
            if cleaned:
                name = cleaned
        return kind, feed_url, name

    # 2. YouTube: /channel/UC... or /@handle
    m_yt_id = re.search(r"(?:https?://)?(?:www\.)?youtube\.com/channel/(UC[\w-]+)", clean_link, re.IGNORECASE)
    if m_yt_id:
        channel_id = m_yt_id.group(1)
        feed_url = f"https://www.youtube.com/feeds/videos.xml?channel_id={channel_id}"
        kind = "youtube"
        raw = await _fetch_bytes(fetch_fn, feed_url)
        name = _extract_feed_title(raw) or channel_id
        return kind, feed_url, name

    m_yt_handle = re.search(r"(?:https?://)?(?:www\.)?youtube\.com/@([^\s/?#]+)", clean_link, re.IGNORECASE)
    if m_yt_handle:
        handle = m_yt_handle.group(1)
        page_url = f"https://www.youtube.com/@{handle}"
        raw = await _fetch_bytes(fetch_fn, page_url)
        text = raw.decode("utf-8", errors="replace")
        m_id = (
            re.search(r"/channel/(UC[\w-]+)", text)
            or re.search(r'["\']channelId["\']\s*:\s*["\'](UC[\w-]+)["\']', text)
        )
        if not m_id:
            raise ValueError("youtube channel id not found")
        channel_id = m_id.group(1)
        feed_url = f"https://www.youtube.com/feeds/videos.xml?channel_id={channel_id}"
        kind = "youtube"
        feed_raw = await _fetch_bytes(fetch_fn, feed_url)
        name = _extract_feed_title(feed_raw) or handle
        return kind, feed_url, name

    # 3. Website / RSS: <link rel="alternate"> or the URL itself
    if "://" in clean_link:
        scheme = clean_link.split("://", 1)[0].lower()
        if scheme not in ("http", "https"):
            raise NewsFetchRefused(f"unsupported scheme: {scheme}")
        url = clean_link
    else:
        url = f"https://{clean_link}"

    raw = await _fetch_bytes(fetch_fn, url)
    finder = _AlternateFeedFinder()
    try:
        finder.feed(raw.decode("utf-8", errors="replace"))
    except Exception:
        pass

    if finder.feed_url:
        feed_url = urllib.parse.urljoin(url, finder.feed_url)
        kind = "rss"
        feed_raw = await _fetch_bytes(fetch_fn, feed_url)
        name = _extract_feed_title(feed_raw) or finder.feed_title or finder.html_title or url
        return kind, feed_url, name

    if _is_feed(raw):
        feed_url = url
        kind = "rss"
        name = _extract_feed_title(raw) or url
        return kind, feed_url, name

    raise ValueError("not an RSS or Atom feed")


class News:
    def __init__(
        self,
        *,
        database_url: str | None,
        enabled: bool,
        collect_enabled: bool = True,
        fetch: Any = None,
        interval_s: float = COLLECT_INTERVAL_S,
        resolve: Any = None,
        max_channels: int = 50,
    ) -> None:
        from app import news_fetch

        self.database_url = database_url
        self.enabled = enabled
        self.collect_enabled = collect_enabled
        self.resolve = resolve or news_fetch._default_resolve
        self.fetch = fetch or self._default_fetch
        self.interval_s = interval_s
        self.max_channels = max_channels
        self.last_check = float("-inf")
        self.thread: threading.Thread | None = None
        self._stop = threading.Event()

    async def _default_fetch(self, url: str) -> bytes:
        from app import news_fetch

        result = await news_fetch.fetch(url, resolve=self.resolve)
        if result.status >= 400:
            raise ValueError(f"HTTP {result.status}")
        return result.body

    async def connect(self) -> asyncpg.Connection:
        if not self.database_url:
            raise Unavailable
        try:
            return await asyncpg.connect(self.database_url)
        except Exception as exc:  # noqa: BLE001
            logger.warning("news: database failed: %s", type(exc).__name__)
            raise Unavailable from None

    def soon(self) -> None:
        """Start periodic collection in background thread if due."""
        if not self.enabled or not self.collect_enabled or not self.database_url:
            return
        if self.thread is not None and self.thread.is_alive():
            return
        if time.monotonic() - self.last_check < self.interval_s:
            return
        self.last_check = time.monotonic()
        self.thread = threading.Thread(target=self._run_loop, name="news-collector", daemon=True)
        self.thread.start()

    def _run_loop(self) -> None:
        while not self._stop.is_set():
            try:
                from app import news_collect

                if self.database_url:
                    asyncio.run(news_collect.collect_once(self.database_url))
                    asyncio.run(news_collect.purge_news(self.database_url))
            except Exception as exc:  # noqa: BLE001
                logger.warning("news: collect loop failed: %s", type(exc).__name__)
            if self._stop.wait(timeout=self.interval_s):
                break

    def stop(self) -> None:
        self._stop.set()


def news_from_env(env: Mapping[str, str], database_url: str | None) -> News:
    """By default news and collection are enabled.

    `NEWS_ENABLED=0` disables news API and collection.
    `NEWS_COLLECT=0` disables only the periodic collection thread (in tests).
    """
    enabled = str(env.get("NEWS_ENABLED", "")).strip() != "0"
    collect_enabled = enabled and str(env.get("NEWS_COLLECT", "1")).strip() != "0"
    try:
        max_channels = int(str(env.get("NEWS_MAX_CHANNELS", "50")).strip() or "50")
    except ValueError:
        max_channels = 50
    return News(
        database_url=database_url,
        enabled=enabled,
        collect_enabled=collect_enabled,
        max_channels=max_channels,
    )


router = APIRouter()


def _owner(request: Request) -> UUID:
    return UUID(request.state.user["id"])


async def _open(request: Request) -> asyncpg.Connection:
    return await request.app.state.news.connect()


def _disabled(request: Request) -> bool:
    return not request.app.state.news.enabled


def _unavailable() -> JSONResponse:
    return JSONResponse({"status": "news_unavailable"}, status_code=503)

# --- subscribed artist releases (FT-574) -----------------------------------
async def _release_cards(conn: asyncpg.Connection, request: Request, artist_ids: list[UUID]) -> list[dict[str, Any]]:
    """Fresh releases by subscribed artists from local MusicBrainz copy, without network.

    Release is a group with `first_date` within 30 days; a group with multiple
    editions produces one card. `album_id` is the same album id as on the
    artist page: opens `/v1/albums/{id}` and cover `/v1/covers/{id}`. Cover
    art is served like on the artist page: returns what is already cached,
    queues the rest.
    Neither artist name nor title enters the log (docs/logs.md, Р-A83).
    """
    if not artist_ids:
        return []
    cutoff = (date.today() - timedelta(days=30)).isoformat()
    rows = await conn.fetch(
        """
        SELECT g.mbid::text AS album_id, g.title, g.first_date, a.name AS artist
        FROM mb_release_group g
        JOIN mb_artist a ON a.mbid = g.artist_mbid
        WHERE g.artist_mbid = ANY($1::uuid[])
          AND g.first_date >= $2
          AND EXISTS (
              SELECT 1 FROM mb_release r
              JOIN mb_medium m ON m.release_mbid = r.mbid
              JOIN mb_track t ON t.medium_id = m.id
              WHERE r.group_mbid = g.mbid AND r.status = 'Official'
          )
        ORDER BY g.first_date DESC, g.mbid
        LIMIT 50
        """,
        artist_ids,
        cutoff,
    )
    if not rows:
        return []
    from app import images

    pages = request.app.state.catalog_pages
    covers = await images.covers_of(conn, [row["album_id"] for row in rows])
    cards: list[dict[str, Any]] = []
    for row in rows:
        await pages.covers_soon(conn, row["artist"], [(row["album_id"], row["title"], False)])
        cards.append({
            "type": "release",
            "id": row["album_id"],
            "artist": row["artist"],
            "title": row["title"],
            "album_id": row["album_id"],
            "published": row["first_date"],
            "cover": covers.get(row["album_id"]),
        })
    return cards


# --- feed -----------------------------------------------------------------

@router.get("/v1/news")
async def news(request: Request) -> Any:
    if _disabled(request):
        return JSONResponse(DISABLED)
    try:
        conn = await _open(request)
    except Unavailable:
        return _unavailable()

    user_id = _owner(request)
    try:
        artist_rows = await conn.fetch(
            """
            SELECT f.artist_mbid, a.name
            FROM news_follows f
            JOIN mb_artist a ON a.mbid = f.artist_mbid
            WHERE f.user_id = $1
            """,
            user_id,
        )
        channel_rows = await conn.fetch(
            "SELECT feed_url FROM news_channels WHERE user_id = $1",
            user_id,
        )
        off_rows = await conn.fetch(
            "SELECT channel_id FROM news_curated_pref WHERE user_id = $1 AND NOT enabled",
            user_id,
        )

        followed_ids = [r["artist_mbid"] for r in artist_rows]
        followed_artists = [r["name"] for r in artist_rows]
        own_feeds = {r["feed_url"] for r in channel_rows}
        # Curated channel disabled by this user is hidden from their feed
        # (FT-582); channel id is its feed URL.
        off_feeds = {r["channel_id"] for r in off_rows}

        if not followed_artists and not own_feeds:
            return {"items": []}

        artist_patterns: list[tuple[str, re.Pattern[str]]] = []
        for name in followed_artists:
            first = name[0]
            last = name[-1]
            pre = r"\b" if first.isalnum() or first == "_" else r"(?<!\S)"
            suf = r"\b" if last.isalnum() or last == "_" else r"(?!\S)"
            pat = re.compile(rf"{pre}{re.escape(name)}{suf}", re.IGNORECASE)
            artist_patterns.append((name, pat))

        rows = await conn.fetch(
            """
            SELECT id, feed_url, channel, title, text, link, image_url, published, is_curated
            FROM news_items
            ORDER BY published DESC, id DESC
            LIMIT 500
            """
        )

        feed_items: list[dict[str, Any]] = []
        for row in rows:
            is_own = row["feed_url"] in own_feeds
            matched_artist: str | None = None
            if is_own:
                matched_artist = None
            elif row["is_curated"]:
                if row["feed_url"] in off_feeds:
                    continue
                text_to_search = f"{row['title']} {row['text']}"
                for artist_name, pattern in artist_patterns:
                    if pattern.search(text_to_search):
                        matched_artist = artist_name
                        break
                if matched_artist is None:
                    continue
            else:
                continue

            img_url = f"/v1/photos/news/{row['id']}" if row["image_url"] else None
            feed_items.append({
                "type": "article",
                "id": str(row["id"]),
                "channel": row["channel"],
                "title": row["title"],
                "text": row["text"],
                "link": row["link"],
                "image": img_url,
                "published": row["published"].isoformat() if row["published"] else None,
                "artist": matched_artist,
            })
            if len(feed_items) == 50:
                break

        release_items = await _release_cards(conn, request, followed_ids)
        items = sorted(feed_items + release_items, key=lambda i: i["published"] or "", reverse=True)
        return {"items": items[:50]}
    finally:
        await conn.close()


# --- serving news photos --------------------------------------------

@router.get("/v1/photos/news/{news_id}", include_in_schema=False)
async def news_photo(request: Request, news_id: int) -> Response:
    if _disabled(request):
        return JSONResponse(NOT_FOUND, status_code=404)
    try:
        conn = await _open(request)
    except Unavailable:
        return _unavailable()

    try:
        row = await conn.fetchrow("SELECT image_url FROM news_items WHERE id = $1", news_id)
    except asyncpg.DataError:
        return JSONResponse(NOT_FOUND, status_code=404)
    finally:
        await conn.close()

    if row is None or not row["image_url"]:
        return JSONResponse(NOT_FOUND, status_code=404)

    image_url = row["image_url"]
    try:
        res = await request.app.state.news.fetch(image_url)
        content = res.body if hasattr(res, "body") else res
    except Exception as exc:  # noqa: BLE001
        logger.warning("news: photo fetch failed: %s", type(exc).__name__)
        return JSONResponse(NOT_FOUND, status_code=404)

    if not content:
        return JSONResponse(NOT_FOUND, status_code=404)

    media_type = "image/jpeg"
    if content.startswith(b"\x89PNG\r\n\x1a\n"):
        media_type = "image/png"
    elif content.startswith(b"GIF8"):
        media_type = "image/gif"
    elif content.startswith(b"RIFF") and b"WEBP" in content[:16]:
        media_type = "image/webp"
    elif content.startswith(b"\xff\xd8"):
        media_type = "image/jpeg"
    elif image_url.lower().endswith(".png"):
        media_type = "image/png"
    elif image_url.lower().endswith(".webp"):
        media_type = "image/webp"
    elif image_url.lower().endswith(".gif"):
        media_type = "image/gif"

    return Response(content=content, media_type=media_type)


# --- artist subscriptions ---------------------------------------------------
 
async def _soft_fetch(fetch: Any, url: str) -> bytes:
    """Failure reading artist link results in empty page, not subscription refusal.

    YouTube channel address is visible from the link itself, so network glitch
    does not hide their channel: resolution works off the link, and feed title is
    retrieved only if the feed opens successfully.
    """
    try:
        return await fetch(url)
    except Exception:  # noqa: BLE001
        return b""


async def _artist_channels(
    news: Any,
    user_id: UUID,
    artist_mbid: UUID,
    artist_name: str,
) -> None:
    """Official artist links from MusicBrainz copy — their channels (FT-578).

    Channel kind — FT-577 resolution (`resolve_channel_link`); social media
    does not become a channel; link read failure does not break subscription. Log —
    error type only, not artist name or channel URL (docs/logs.md, Р-A83).
    """
    try:
        conn = await news.connect()
    except Unavailable:
        return
    try:
        await _add_artist_channels(conn, news.fetch, user_id, artist_mbid, artist_name)
    except Exception as exc:  # noqa: BLE001 — background task: failure does not crash server
        logger.warning("news: artist channels failed: %s", type(exc).__name__)
    finally:
        await conn.close()


async def _add_artist_channels(
    conn: asyncpg.Connection,
    fetch: Any,
    user_id: UUID,
    artist_mbid: UUID,
    artist_name: str,
) -> None:
    rows = await conn.fetch(
        "SELECT kind, url FROM mb_artist_url WHERE artist_mbid = $1", artist_mbid
    )
    for row in rows:
        if row["kind"] == "social":
            continue
        try:
            kind, feed_url, _name = await resolve_channel_link(
                row["url"], lambda url: _soft_fetch(fetch, url)
            )
        except Exception as exc:  # noqa: BLE001
            logger.warning("news: artist channel add failed: %s", type(exc).__name__)
            continue
        await conn.execute(
            "INSERT INTO news_channels (user_id, kind, feed_url, name, artist_mbid)"
            " VALUES ($1, $2, $3, $4, $5)"
            " ON CONFLICT (user_id, feed_url) DO NOTHING",
            user_id, kind, feed_url, artist_name, artist_mbid,
        )


@router.get("/v1/news/follows")
async def follows(request: Request) -> Any:
    if _disabled(request):
        return JSONResponse(DISABLED)
    try:
        conn = await _open(request)
    except Unavailable:
        return _unavailable()
    try:
        rows = await conn.fetch(
            """
            SELECT f.artist_mbid, a.name
            FROM news_follows f JOIN mb_artist a ON a.mbid = f.artist_mbid
            WHERE f.user_id = $1 ORDER BY f.added_at, f.artist_mbid
            """,
            _owner(request),
        )
        return {"artists": [{"id": str(row["artist_mbid"]), "name": row["name"]} for row in rows]}
    finally:
        await conn.close()


@router.post("/v1/news/follows")
async def follows_add(request: Request, body: ArtistIn, background: BackgroundTasks) -> Any:
    if _disabled(request):
        return JSONResponse(DISABLED)
    try:
        conn = await _open(request)
    except Unavailable:
        return _unavailable()
    try:
        # Can only follow an artist known to the catalog.
        artist_name = await conn.fetchval(
            "SELECT name FROM mb_artist WHERE mbid = $1", body.artist_id
        )
        if artist_name is None:
            return JSONResponse(NOT_FOUND, status_code=404)
        user_id = _owner(request)
        # Duplicate follow is idempotent.
        await conn.execute(
            "INSERT INTO news_follows (user_id, artist_mbid) VALUES ($1, $2)"
            " ON CONFLICT (user_id, artist_mbid) DO NOTHING",
            user_id,
            body.artist_id,
        )
        # Artist channels run after response: resolution accesses network (up to 15s per
        # link), and the "Follow" button must not wait on artist's website.
        background.add_task(
            _artist_channels, request.app.state.news, user_id, body.artist_id, artist_name
        )
        return {"status": "ok"}
    finally:
        await conn.close()


@router.post("/v1/news/follows/remove")
async def follows_remove(request: Request, body: ArtistIn) -> Any:
    if _disabled(request):
        return JSONResponse(DISABLED)
    try:
        conn = await _open(request)
    except Unavailable:
        return _unavailable()
    try:
        user_id = _owner(request)
        await conn.execute(
            "DELETE FROM news_follows WHERE user_id = $1 AND artist_mbid = $2",
            user_id,
            body.artist_id,
        )
        # Unfollowing removes channels added by the subscription too.
        await conn.execute(
            "DELETE FROM news_channels WHERE user_id = $1 AND artist_mbid = $2",
            user_id,
            body.artist_id,
        )
        return {"status": "ok"}
    finally:
        await conn.close()


# --- custom channels -----------------------------------------------------------

@router.get("/v1/news/channels")
async def news_channels_list(request: Request) -> Any:
    if _disabled(request):
        return JSONResponse(DISABLED)
    try:
        conn = await _open(request)
    except Unavailable:
        return _unavailable()
    try:
        rows = await conn.fetch(
            """
            SELECT c.feed_url, c.kind, c.name, a.name AS artist
            FROM news_channels c
            LEFT JOIN mb_artist a ON a.mbid = c.artist_mbid
            WHERE c.user_id = $1
            ORDER BY c.added_at, c.feed_url
            """,
            _owner(request),
        )
        return {
            "channels": [
                {
                    "id": row["feed_url"],
                    "kind": row["kind"],
                    "name": row["name"],
                    "feed_url": row["feed_url"],
                    "artist": row["artist"],
                }
                for row in rows
            ]
        }
    finally:
        await conn.close()


@router.post("/v1/news/channels")
async def news_channels_add(request: Request, body: ChannelIn) -> Any:
    if _disabled(request):
        return JSONResponse(DISABLED)
    try:
        conn = await _open(request)
    except Unavailable:
        return _unavailable()
    try:
        user_id = _owner(request)
        max_channels = getattr(request.app.state.news, "max_channels", 50)
        count = await conn.fetchval(
            # Limit is on custom channels; channels from artist subscriptions do not count.
            "SELECT count(*) FROM news_channels WHERE user_id = $1 AND artist_mbid IS NULL",
            user_id,
        )
        if count >= max_channels:
            return JSONResponse({"error": "too_many"}, status_code=409)

        try:
            kind, feed_url, name = await resolve_channel_link(body.link, request.app.state.news.fetch)
        except NewsFetchRefused:
            return JSONResponse({"error": "not_public"}, status_code=400)
        except Exception as exc:  # noqa: BLE001
            logger.warning("news: channel add failed: %s", type(exc).__name__)
            return JSONResponse({"error": "not_feed"}, status_code=400)

        await conn.execute(
            """
            INSERT INTO news_channels (user_id, kind, feed_url, name)
            VALUES ($1, $2, $3, $4)
            ON CONFLICT (user_id, feed_url) DO UPDATE
            SET kind = EXCLUDED.kind, name = EXCLUDED.name
            """,
            user_id,
            kind,
            feed_url,
            name,
        )
        return {
            "channel": {
                "id": feed_url,
                "kind": kind,
                "name": name,
                "feed_url": feed_url,
            }
        }
    finally:
        await conn.close()


@router.post("/v1/news/channels/remove")
async def news_channels_remove(request: Request, body: ChannelRemoveIn) -> Any:
    if _disabled(request):
        return JSONResponse(DISABLED)
    try:
        conn = await _open(request)
    except Unavailable:
        return _unavailable()
    try:
        await conn.execute(
            "DELETE FROM news_channels WHERE user_id = $1 AND feed_url = $2",
            _owner(request),
            body.id,
        )
        return {"status": "ok"}
    finally:
        await conn.close()


# --- curated list and popular (FT-582) -----------------------------------

def _curated_channels() -> list[dict[str, str]]:
    """Curated list (FT-573): same file as news collection.

    Channel `id` is its feed URL: it does not change on file edits and the feed
    uses it to hide a disabled channel.
    """
    from app import news_collect

    channels: list[dict[str, str]] = []
    for entry in news_collect.load_curated_channels():
        feed_url = entry.get("feed_url")
        if feed_url:
            channels.append({
                "id": feed_url,
                "name": entry.get("name", ""),
                "lang": entry.get("lang", ""),
            })
    return channels


@router.get("/v1/news/curated")
async def news_curated(request: Request) -> Any:
    """Curated list with this user's toggle (enabled by default)."""
    if _disabled(request):
        return JSONResponse(DISABLED)
    try:
        conn = await _open(request)
    except Unavailable:
        return _unavailable()
    try:
        rows = await conn.fetch(
            "SELECT channel_id, enabled FROM news_curated_pref WHERE user_id = $1",
            _owner(request),
        )
        prefs = {row["channel_id"]: row["enabled"] for row in rows}
        return {
            "channels": [
                {**channel, "enabled": prefs.get(channel["id"], True)}
                for channel in _curated_channels()
            ]
        }
    finally:
        await conn.close()


@router.post("/v1/news/curated")
async def news_curated_set(request: Request, body: CuratedIn) -> Any:
    if _disabled(request):
        return JSONResponse(DISABLED)
    try:
        conn = await _open(request)
    except Unavailable:
        return _unavailable()
    if body.id not in {channel["id"] for channel in _curated_channels()}:
        await conn.close()
        return JSONResponse({"error": "not_curated"}, status_code=404)
    try:
        await conn.execute(
            """
            INSERT INTO news_curated_pref (user_id, channel_id, enabled)
            VALUES ($1, $2, $3)
            ON CONFLICT (user_id, channel_id)
            DO UPDATE SET enabled = EXCLUDED.enabled, updated_at = now()
            """,
            _owner(request),
            body.id,
            body.enabled,
        )
        return {"status": "ok"}
    finally:
        await conn.close()


@router.get("/v1/news/channels/popular")
async def news_channels_popular(request: Request) -> Any:
    """Custom channels added manually by at least three users: channels from
    artist subscriptions (FT-578) were not selected by anyone, they do not count.

    Response contains only user count — neither names nor ids (FT-582 contract).
    """
    if _disabled(request):
        return JSONResponse(DISABLED)
    try:
        conn = await _open(request)
    except Unavailable:
        return _unavailable()
    try:
        rows = await conn.fetch(
            """
            SELECT feed_url, min(kind) AS kind, min(name) AS name,
                   count(DISTINCT user_id) AS people
            FROM news_channels
            WHERE artist_mbid IS NULL
            GROUP BY feed_url
            HAVING count(DISTINCT user_id) >= 3
            ORDER BY people DESC, feed_url
            """
        )
        return {
            "channels": [
                {
                    "kind": row["kind"],
                    "feed_url": row["feed_url"],
                    "name": row["name"],
                    "people": row["people"],
                }
                for row in rows
            ]
        }
    finally:
        await conn.close()


def install_news(app: FastAPI, *, database_url: str | None, env: Mapping[str, str]) -> None:
    """Attach news to application. Single line in main.py."""
    from app.news_suggest import router as suggestions_router

    app.state.news = news_from_env(env, database_url)
    app.include_router(router)
    # Empty feed suggestions live in their own module (FT-580).
    app.include_router(suggestions_router)
    if app.state.news.collect_enabled:
        app.state.news.soon()
