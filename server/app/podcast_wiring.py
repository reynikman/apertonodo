"""Complete podcast setup on the server: endpoints, network client, and feed crawler (FT-702).

In `main.py` — single line `install_podcast_suite(...)`.

`PODCASTS_LIVE=1` — live mode: search and catalog access Apple directory, background
thread crawls subscription feeds every `CRAWL_INTERVAL_S`, subscription wakes it up immediately.
Without the variable, nothing accesses the network: search and catalog return 503, no crawler.
This keeps tests from seeing live sources (guard — `tests/test_hermetic_sources.py`).
"""

from __future__ import annotations

import asyncio
import logging
import threading
from collections.abc import Callable, Mapping

import asyncpg
import httpx
from fastapi import FastAPI

from app import podcast_crawl
from app.podcast_api import install_podcasts
from app.podcast_catalog import install_podcast_catalog
from app.podcast_covers import install_podcast_covers
from app.podcast_preview import install_podcast_preview

logger = logging.getLogger("apertonodo")

CRAWL_INTERVAL_S = 30 * 60
CLIENT_TIMEOUT_S = 10.0


def live_from_env(env: Mapping[str, str]) -> bool:
    return str(env.get("PODCASTS_LIVE", "")).strip() == "1"


class Crawler:
    """Background feed crawler thread. `kick()` — crawl now without waiting for interval."""

    def __init__(
        self, one_pass: Callable[[], None], *, interval_s: float = CRAWL_INTERVAL_S
    ) -> None:
        self.one_pass = one_pass
        self.interval_s = interval_s
        self._wake = threading.Event()
        self._stop = threading.Event()
        self.thread = threading.Thread(
            target=self._loop, name="podcast-crawler", daemon=True
        )

    def start(self) -> None:
        self.thread.start()

    def kick(self) -> None:
        self._wake.set()

    def stop(self) -> None:
        self._stop.set()
        self._wake.set()
        if self.thread.is_alive():
            self.thread.join(timeout=5)

    def _loop(self) -> None:
        while not self._stop.is_set():
            try:
                self.one_pass()
            except Exception as exc:  # noqa: BLE001
                logger.warning("podcasts: crawl pass failed: %s", type(exc).__name__)
            self._wake.wait(timeout=self.interval_s)
            self._wake.clear()


def _crawl_pass(database_url: str) -> Callable[[], None]:
    async def run() -> None:
        conn = await asyncpg.connect(database_url)
        try:
            counts = await podcast_crawl.run_once(conn)
        finally:
            await conn.close()
        if any(counts.values()):
            logger.info(
                "podcasts: crawl saved=%d failed=%d not_a_feed=%d",
                counts["saved"],
                counts["failed"],
                counts["not_a_feed"],
            )

    return lambda: asyncio.run(run())


def install_podcast_suite(
    app: FastAPI, *, database_url: str | None, env: Mapping[str, str]
) -> None:
    client: httpx.AsyncClient | None = None
    crawler: Crawler | None = None
    if live_from_env(env):
        client = httpx.AsyncClient(timeout=CLIENT_TIMEOUT_S, follow_redirects=True)
        if database_url:
            crawler = Crawler(_crawl_pass(database_url))
    install_podcasts(
        app,
        database_url=database_url,
        client=client,
        kick=crawler.kick if crawler else None,
    )
    install_podcast_catalog(app, client=client)
    install_podcast_preview(app, live=live_from_env(env))
    install_podcast_covers(app, env=env, live=live_from_env(env))
    app.state.podcast_crawler = crawler
    if crawler is not None:
        crawler.start()
