"""External listen scrobble delivery wiring (contract D1, FT-641): pass once per minute.

The queue `play_deliveries` is filled by `play_reports.report` from `POST /v1/history`;
here `play_sender.run_once` drains it and cleans up old entries (`drop_outdated`,
`purge`). The worker is enabled only with `PLAY_SENDER=1` in deployment environment: tests
do not see it, not a single request goes outside from tests (guard —
`tests/test_hermetic_sources.py`).

ListenBrainz — via `MUSICBRAINZ_PROXY`: it is the same MetaBrainz, and from production
server it does not respond directly. Last.fm — via `LASTFM_PROXY`, and only
when both key and secret are present. Log: outcome word from `run_once`, without songs.
"""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Mapping
from typing import Any
from uuid import UUID

import asyncpg
import httpx
from fastapi import FastAPI

from app.lastfm_connect import install_lastfm_connect
from app.lastfm_scrobble import lastfm
from app.play_reports import drop_outdated, purge
from app.play_sender import Sender, Song, listenbrainz, run_once
from app.scrobble import install_scrobble

logger = logging.getLogger("apertonodo")

EVERY_S = 60.0
TIMEOUT_S = 20.0
# Last.fm connection holds DB connection during request (FT-645).
CONNECT_TIMEOUT_S = 15.0


class PlaySender:
    def __init__(
        self,
        app: FastAPI,
        database_url: str,
        env: Mapping[str, str],
        *,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        self.app = app
        self.database_url = database_url
        self._clients: list[httpx.AsyncClient] = []
        self.senders: dict[str, Sender] = {
            "listenbrainz": listenbrainz(
                self._client(env.get("MUSICBRAINZ_PROXY"), transport)
            )
        }
        key = (env.get("LASTFM_API_KEY") or "").strip()
        secret = (env.get("LASTFM_API_SECRET") or "").strip()
        if key and secret:
            self.senders["lastfm"] = lastfm(
                self._client(env.get("LASTFM_PROXY"), transport),
                api_key=key,
                api_secret=secret,
            )

    def _client(
        self, proxy: str | None, transport: httpx.AsyncBaseTransport | None
    ) -> httpx.AsyncClient:
        client = httpx.AsyncClient(
            proxy=(proxy or "").strip() or None,
            timeout=TIMEOUT_S,
            transport=transport,
        )
        self._clients.append(client)
        return client

    async def _lookup(self, track_id: str) -> Song | None:
        try:
            track = await self.app.state.library.track(UUID(track_id))
        except ValueError:
            return None
        if track is None:
            return None
        return Song(
            artist=str(track["artist"]),
            title=str(track["title"]),
            duration_ms=int(track.get("duration_ms") or 0),
        )

    async def once(self) -> dict[str, int]:
        conn = await asyncpg.connect(self.database_url)
        try:
            counts = await run_once(conn, senders=self.senders, lookup=self._lookup)
            await drop_outdated(conn)
            await purge(conn)
            return counts
        finally:
            await conn.close()

    async def run(self) -> None:
        while True:
            try:
                await self.once()
            except (OSError, asyncpg.PostgresError) as exc:
                logger.info("play delivery pass failed: %s", type(exc).__name__)
            await asyncio.sleep(EVERY_S)

    async def close(self) -> None:
        for client in self._clients:
            await client.aclose()


def install_play_sender(
    app: FastAPI, *, database_url: str | None, env: Mapping[str, Any]
) -> None:
    """`app.state.play_sender` — worker for `lifespan` or `None`."""
    on = str(env.get("PLAY_SENDER", "") or "").strip() == "1"
    app.state.play_sender = (
        PlaySender(app, database_url, {k: str(v) for k, v in env.items()})
        if on and database_url
        else None
    )


def install_scrobbling(
    app: FastAPI, *, database_url: str | None, env: Mapping[str, Any]
) -> None:
    """External listen scrobbling complete: service connections and delivery worker."""
    install_scrobble(app, database_url=database_url)
    key = str(env.get("LASTFM_API_KEY", "") or "").strip()
    secret = str(env.get("LASTFM_API_SECRET", "") or "").strip()
    client = (
        httpx.AsyncClient(
            proxy=str(env.get("LASTFM_PROXY", "") or "").strip() or None,
            timeout=CONNECT_TIMEOUT_S,
        )
        if key and secret
        else None
    )
    install_lastfm_connect(
        app, database_url=database_url, api_key=key, api_secret=secret, client=client
    )
    install_play_sender(app, database_url=database_url, env=env)
