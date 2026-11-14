"""Podcast images through our own server (FT-859, owner 14.10: "ok").

A podcast and an episode have an image — an address on someone else's site. The phone does not go there
itself: it asks for `GET /v1/covers/podcast/image?u=<address>`, the server downloads
the image once with the same protected loader as the feeds (`news_fetch.fetch`: outward only,
within the limit, every redirect is checked again), shrinks it
and stores it as a file next to the music covers (`IMAGE_DIR/podcasts/`). Then it
serves from disk.

The path lies under `/v1/covers/` because the proxy does not count images in the request
limit (`docs/reverse-proxy.md`): the podcasts screen asks for them a dozen at a time.
The image address is in neither the log nor the access log — the query string is cut by
`app/access_log.py`.
"""

from __future__ import annotations

import asyncio
import hashlib
import logging
import os
import time
from collections import OrderedDict
from collections.abc import Awaitable, Callable, Mapping
from pathlib import Path
from typing import Any

from fastapi import APIRouter, FastAPI, Request
from fastapi.responses import FileResponse, JSONResponse

from app import news_fetch
from app.images import CONTENT_TYPE, Store, kind_of, shrink

logger = logging.getLogger("apertonodo")

SIDE = 400
MAX_IMAGE_BYTES = 5_000_000
MAX_URL = 2048
FETCH_TIMEOUT_S = 15.0
# A link that did not return an image is not retried for a day: the screen asks for it on
# every open.
RETRY_S = 24 * 3600
FAILED_MAX = 10_000
PARALLEL = 4

NOT_FOUND = {"status": "not_found"}

Fetch = Callable[[str], Awaitable[bytes | None]]


async def _fetch(url: str) -> bytes | None:
    try:
        result = await news_fetch.fetch(url, max_bytes=MAX_IMAGE_BYTES, timeout=FETCH_TIMEOUT_S)
    except Exception as exc:  # address check refusal, network, limit
        logger.info("podcast cover failed %s", type(exc).__name__)
        return None
    if result.status != 200:
        logger.info("podcast cover failed status %s", result.status)
        return None
    return result.body


class PodcastCovers:
    def __init__(self, root: Path, fetch: Fetch | None) -> None:
        self.store = Store(root)
        self.fetch = fetch
        self.failed: OrderedDict[str, float] = OrderedDict()
        self.gate = asyncio.Semaphore(PARALLEL)

    def cached(self, name: str) -> Path | None:
        for ext in CONTENT_TYPE:
            path = self.store.open(f"podcasts/{name[:2]}/{name}.{ext}")
            if path is not None:
                return path
        return None

    def _gave_up(self, name: str) -> bool:
        at = self.failed.get(name)
        if at is None:
            return False
        if time.monotonic() - at < RETRY_S:
            return True
        del self.failed[name]
        return False

    def _fail(self, name: str) -> None:
        self.failed[name] = time.monotonic()
        self.failed.move_to_end(name)
        while len(self.failed) > FAILED_MAX:
            self.failed.popitem(last=False)

    async def path_for(self, url: str) -> Path | None:
        name = hashlib.sha256(url.encode()).hexdigest()
        path = self.cached(name)
        if path is not None or self.fetch is None or self._gave_up(name):
            return path
        async with self.gate:
            path = self.cached(name)
            if path is not None:
                return path
            blob = await self.fetch(url)
            if blob is None or kind_of(blob) is None:
                self._fail(name)
                return None
            small = await asyncio.to_thread(shrink, blob, SIDE)
            ext = kind_of(small)
            if ext is None:
                self._fail(name)
                return None
            relative = await asyncio.to_thread(self.store.save, "podcasts", name, small, ext)
            return self.store.open(relative)


router = APIRouter()


def _usable(url: str) -> bool:
    return (
        0 < len(url) <= MAX_URL
        and url.startswith("https://")
        and url.isprintable()
        and " " not in url
    )


@router.get("/v1/covers/podcast/image")
async def podcast_cover(request: Request, u: str = "") -> Any:
    covers: PodcastCovers | None = getattr(request.app.state, "podcast_covers", None)
    if covers is None or not _usable(u):
        return JSONResponse(NOT_FOUND, status_code=404)
    path = await covers.path_for(u)
    if path is None:
        return JSONResponse(NOT_FOUND, status_code=404)
    return FileResponse(
        path,
        media_type=CONTENT_TYPE[path.suffix.lstrip(".")],
        headers={"cache-control": "private, max-age=604800"},
    )


def install_podcast_covers(
    app: FastAPI, *, env: Mapping[str, str] = os.environ, live: bool, fetch: Fetch | None = None
) -> None:
    """Without `IMAGE_DIR` there are no podcast images; without a live network — only the already downloaded ones."""
    root = str(env.get("IMAGE_DIR", "")).strip()
    app.state.podcast_covers = (
        PodcastCovers(Path(root), fetch or (_fetch if live else None)) if root else None
    )
    app.include_router(router)
