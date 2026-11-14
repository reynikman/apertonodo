"""Lyrics proxy: core queries the lyrics extension (FT-624, P-A77, P-A88).

The client only knows the track ID and calls `GET /v1/lyrics/{track_id}`.
The core fetches artist, title, and duration from its `tracks` table and
queries the extension (`LYRICS_URL`, contract `contracts/lyrics-api.md`).
The extension response is returned to the client with the same fields — `found`,
`instrumental`, `plain`, `synced`, and nothing else.

Boundaries maintained here:

- Only the outcome is logged — `lyrics found|not_found|unavailable|off`.
  Neither artist, title, nor lyrics appear in logs (docs/logs.md).
- Only the extension reaches outside for lyrics: core contacts `LYRICS_URL`
  and nowhere else. Query text is sent in the `POST` body rather than URL,
  so the song title does not appear in the `httpx` request log.
- If `LYRICS_URL` is unset — extension is absent: `503 lyrics_off`, nobody to
  query. Similarly `503 unavailable` when extension is silent, responds non-200
  or returns an unexpected body.
"""

from __future__ import annotations

import logging
import os
from typing import Any
from uuid import UUID

import httpx
from fastapi import APIRouter, FastAPI, Request
from fastapi.responses import JSONResponse

from app.store import load_track

logger = logging.getLogger("apertonodo")

# Extension response timeout 8s: the lyrics screen does not wait long,
# which is enough for the extension to query LRCLIB (contract: 5s per query).
DEFAULT_TIMEOUT_S = 8.0

# What the extension returns to the client. `debug` and other extras are excluded.
FIELDS = ("instrumental", "plain", "synced")

OFF = {"error": "lyrics_off"}
UNAVAILABLE = {"error": "unavailable"}
NOT_FOUND = {"status": "not_found"}


class Lyrics:
    def __init__(self, *, database_url: str | None, url: str, timeout_s: float) -> None:
        self.database_url = database_url
        self.url = url
        self.timeout_s = timeout_s

    async def track(self, track_id: str) -> dict[str, Any] | None:
        """Track from own database. Without database — no way to know or play it."""
        if not self.database_url:
            return None
        return await load_track(self.database_url, track_id)

    async def ask(self, track: dict[str, Any]) -> dict[str, Any] | None:
        """Query the extension; `None` — did not respond or unexpected payload.

        There is no album in `tracks`, so `album` is not sent: the contract
        allows it, but inventing one is prohibited. Duration is in seconds;
        zero means honest "unknown", in which case the field is omitted.
        """
        body: dict[str, Any] = {"artist": track["artist"], "title": track["title"]}
        duration_ms = int(track.get("duration_ms") or 0)
        if duration_ms > 0:
            body["duration_s"] = round(duration_ms / 1000)
        try:
            async with httpx.AsyncClient(timeout=self.timeout_s) as client:
                response = await client.post(f"{self.url}/v1/lyrics", json=body)
        except httpx.HTTPError:
            return None
        if response.status_code != 200:
            return None
        try:
            answer = response.json()
        except ValueError:
            return None
        if not isinstance(answer, dict) or not isinstance(answer.get("found"), bool):
            return None
        if not answer["found"]:
            return {"found": False}
        return {"found": True, **{field: answer.get(field) for field in FIELDS}}


router = APIRouter()


def _lyrics(request: Request) -> Lyrics:
    return request.app.state.lyrics


@router.get("/v1/lyrics/{track_id}")
async def lyrics(request: Request, track_id: UUID) -> Any:
    service = _lyrics(request)
    track = await service.track(str(track_id))
    if track is None:
        return JSONResponse(NOT_FOUND, status_code=404)
    if not service.url:
        logger.info("lyrics off")
        return JSONResponse(OFF, status_code=503)
    answer = await service.ask(track)
    if answer is None:
        logger.info("lyrics unavailable")
        return JSONResponse(UNAVAILABLE, status_code=503)
    logger.info("lyrics %s", "found" if answer["found"] else "not_found")
    return answer


def install_lyrics(app: FastAPI, *, database_url: str | None) -> None:
    """Attach lyrics to the application. One line in main.py."""
    from app.main import env_float

    app.state.lyrics = Lyrics(
        database_url=database_url,
        url=str(os.environ.get("LYRICS_URL", "")).strip().rstrip("/"),
        timeout_s=env_float("LYRICS_TIMEOUT_S", DEFAULT_TIMEOUT_S),
    )
    app.include_router(router)
