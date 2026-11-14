"""Podcast episodes before subscription (FT-723).

`GET /v1/podcasts/episodes` returns episodes of subscribed feeds only: stored by crawler.
When opening a podcast from catalog or search before subscribing,
the client queries `GET /v1/podcasts/preview?feed_url=…`: server fetches the feed
using the same safe method as crawler (`podcast_crawl.default_fetch`), parses it, and
returns episodes in the same format without storing anything. The response is cached for `FRESH_S` seconds
so reopening does not hit the network. The feed URL is not logged.
"""

from __future__ import annotations

import asyncio
import logging
import time
from collections import OrderedDict
from collections.abc import Awaitable, Callable
from datetime import datetime
from typing import Any

from fastapi import APIRouter, FastAPI, Request
from fastapi.responses import JSONResponse

from app import podcasts
from app.podcast_api import _format_dt
from app.podcast_crawl import FEED_TIMEOUT_S, MAX_FEED_BYTES, default_fetch
from app.podcast_feed import Episode, parse_podcast

logger = logging.getLogger("apertonodo")

FRESH_S: float = 10 * 60
MAX_KEYS: int = 200
MAX_EPISODES: int = 200

BAD_URL = {"status": "bad_url"}
NOT_A_FEED = {"status": "not_a_feed"}
UNAVAILABLE = {"status": "podcast_feed_unavailable"}

router = APIRouter()


def episode_json(e: Episode) -> dict[str, Any]:
    return {
        "guid": e.guid,
        "title": e.title,
        "description": e.description,
        "audio_url": e.audio_url,
        "audio_type": e.audio_type,
        "audio_bytes": e.audio_bytes,
        "duration_ms": e.duration_ms,
        "published": _format_dt(e.published),
        "image": e.image,
        "season": e.season,
        "number": e.number,
        "explicit": e.explicit,
    }


def _episode_published(e: Episode) -> datetime:
    assert e.published is not None
    return e.published


def _sort_oldest(episodes: list[Episode]) -> list[Episode]:
    dated = [e for e in episodes if e.published is not None]
    undated = [e for e in episodes if e.published is None]
    rev_dated = list(reversed(dated))
    oldest_dated = sorted(rev_dated, key=_episode_published)
    return oldest_dated + list(reversed(undated))


class PreviewCache:
    def __init__(self, clock: Callable[[], float] = time.monotonic) -> None:
        self._clock = clock
        self._items: OrderedDict[str, tuple[float, dict[str, list[dict[str, Any]]]]] = (
            OrderedDict()
        )

    def get(self, key: str, order: str | None = None) -> list[dict[str, Any]] | None:
        hit = self._items.get(key)
        if hit is None:
            return None
        if self._clock() - hit[0] >= FRESH_S:
            self._items.pop(key, None)
            return None
        self._items.move_to_end(key)
        bucket = "oldest" if order == "oldest" else "newest"
        return hit[1][bucket]

    def put(
        self,
        key: str,
        newest: list[dict[str, Any]],
        oldest: list[dict[str, Any]] | None = None,
    ) -> None:
        self._items[key] = (
            self._clock(),
            {"newest": newest, "oldest": oldest if oldest is not None else newest},
        )
        self._items.move_to_end(key)
        while len(self._items) > MAX_KEYS:
            self._items.popitem(last=False)


@router.get("/v1/podcasts/preview")
async def preview(request: Request) -> Any:
    clean = podcasts.normalize_feed_url(request.query_params.get("feed_url"))
    if clean is None:
        return JSONResponse(BAD_URL, status_code=400)
    fetch: Callable[[str], Awaitable[bytes]] | None = (
        request.app.state.podcast_preview_fetch
    )
    if fetch is None:
        return JSONResponse(UNAVAILABLE, status_code=503)
    order = request.query_params.get("order")
    cache: PreviewCache = request.app.state.podcast_preview_cache
    cached = cache.get(clean, order)
    if cached is not None:
        return {"episodes": cached}
    try:
        async with asyncio.timeout(FEED_TIMEOUT_S):
            raw = await fetch(clean)
    except asyncio.CancelledError:
        raise
    except Exception as exc:  # noqa: BLE001
        logger.info("podcasts: preview fetch failed: %s", type(exc).__name__)
        return JSONResponse(UNAVAILABLE, status_code=503)
    if not isinstance(raw, (bytes, bytearray)) or len(raw) > MAX_FEED_BYTES:
        return JSONResponse(UNAVAILABLE, status_code=503)
    try:
        podcast = await asyncio.to_thread(parse_podcast, bytes(raw))
    except Exception:  # noqa: BLE001
        podcast = None
    if podcast is None:
        return JSONResponse(NOT_A_FEED, status_code=404)
    newest = [episode_json(e) for e in podcast.episodes[:MAX_EPISODES]]
    oldest = [episode_json(e) for e in _sort_oldest(podcast.episodes)[:MAX_EPISODES]]
    cache.put(clean, newest, oldest)
    items = oldest if order == "oldest" else newest
    return {"episodes": items}


def install_podcast_preview(
    app: FastAPI,
    *,
    live: bool,
    fetch: Callable[[str], Awaitable[bytes]] = default_fetch,
    clock: Callable[[], float] = time.monotonic,
) -> None:
    app.state.podcast_preview_fetch = fetch if live else None
    app.state.podcast_preview_cache = PreviewCache(clock=clock)
    app.include_router(router)
