"""FT-631 (Р-A94): scrobbles submitted to ListenBrainz upon user request.

A user tracking history in ListenBrainz provides Apertonodo with their
token — and each counted playback is submitted there. Without a token, the server
sends nothing outside: this is the only place where song titles leave the
server, and strictly by user request.

We do not use a third-party library: this is a single POST via `httpx`, which is already in
dependencies. The client is provided externally — MetaBrainz does not respond directly
from production server, so lead passes a client with proxy upon wiring.
The module itself does not read the environment or instantiate the client.

Log — same as Last.fm: no token, track titles, artist names, or httpx exception
text (which contains URL and token). Only the outcome word: `sent`,
`failed`, `bad_token`. Guard — `tests/test_scrobble.py`.
"""

from __future__ import annotations

import logging
from collections.abc import Callable, Coroutine
from dataclasses import dataclass
from datetime import datetime
from typing import Any
from uuid import UUID

import asyncpg
import httpx
from fastapi import APIRouter, FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, Response
from fastapi.routing import APIRoute
from pydantic import BaseModel, ConfigDict, Field, field_validator

from app.library import UNAVAILABLE, Library, Unavailable

logger = logging.getLogger("apertonodo")

LISTENBRAINZ_URL = "https://api.listenbrainz.org/1/submit-listens"

SERVICE = "listenbrainz"
# Leading/trailing whitespace is stripped before validation; then 8 to 200 printable
# ASCII characters without spaces. Regex for `Field(pattern=…)`.
TOKEN_PATTERN = r"^[\x21-\x7e]{8,200}$"
# Body field names permitted in validation rejection. Extra field names
# could contain sensitive text, so everything else maps to "field".
BODY_FIELDS = frozenset({"token"})


@dataclass(frozen=True)
class Listen:
    artist: str
    title: str
    duration_ms: int
    played_at: datetime


def _payload(listen: Listen) -> dict[str, Any]:
    """Request payload following ListenBrainz specification. Zero duration is omitted."""
    info: dict[str, Any] = {
        "media_player": "Apertono",
        "submission_client": "Apertonodo",
    }
    if listen.duration_ms > 0:
        info["duration_ms"] = listen.duration_ms
    return {
        "listen_type": "single",
        "payload": [
            {
                "listened_at": int(listen.played_at.timestamp()),
                "track_metadata": {
                    "artist_name": listen.artist,
                    "track_name": listen.title,
                    "additional_info": info,
                },
            }
        ],
    }


async def scrobble(
    conn: asyncpg.Connection,
    user_id: UUID,
    listen: Listen,
    *,
    client: httpx.AsyncClient,
) -> str:
    """Send a single scrobble. Never raises network exceptions.

    Outcomes:
    - ``off`` — user has no token; no request made outside;
    - ``bad_token`` — ListenBrainz responded with 401 (or token was already marked bad
      by previous rejection); no further attempts until user provides a new one;
    - ``sent`` — 200 response;
    - ``failed`` — any other response (5xx, 429) or httpx error. Single
      request without retries; token is not marked bad.
    """
    row = await conn.fetchrow(
        "SELECT token, bad FROM scrobble_accounts WHERE user_id = $1 AND service = $2",
        user_id,
        SERVICE,
    )
    if row is None:
        return "off"
    if row["bad"]:
        return "bad_token"
    try:
        response = await client.post(
            LISTENBRAINZ_URL,
            headers={"Authorization": f"Token {str(row['token'])}"},
            json=_payload(listen),
        )
    except httpx.HTTPError:
        # Outcome only: httpx exception text includes URL and sometimes token.
        logger.info("scrobble listenbrainz failed")
        return "failed"
    if response.status_code == 200:
        logger.info("scrobble listenbrainz sent")
        return "sent"
    if response.status_code == 401:
        await conn.execute(
            "UPDATE scrobble_accounts SET bad = true, updated_at = now()"
            " WHERE user_id = $1 AND service = $2",
            user_id,
            SERVICE,
        )
        logger.info("scrobble listenbrainz bad_token")
        return "bad_token"
    logger.info("scrobble listenbrainz failed")
    return "failed"


class TokenIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    token: str = Field(pattern=TOKEN_PATTERN)

    @field_validator("token", mode="before")
    @classmethod
    def _trim(cls, value: Any) -> Any:
        return value.strip() if isinstance(value, str) else value


class ScrobbleRoute(APIRoute):
    """Validation rejection does not echo input: neither token nor unrecognized fields.

    Standard FastAPI response includes `input`, which echoes user input verbatim.
    Pattern modeled after `ReportRoute` in `server/app/app_reports.py`.
    """

    def get_route_handler(self) -> Callable[[Request], Coroutine[Any, Any, Response]]:
        handler = super().get_route_handler()

        async def private_errors(request: Request) -> Response:
            try:
                return await handler(request)
            except RequestValidationError as exc:
                errors = [
                    {
                        "type": error["type"],
                        "loc": [
                            part
                            if isinstance(part, int)
                            or part == "body"
                            or part in BODY_FIELDS
                            else "field"
                            for part in error["loc"]
                        ],
                        "msg": error["msg"],
                    }
                    for error in exc.errors()
                ]
                return JSONResponse({"detail": errors}, status_code=422)

        return private_errors


router = APIRouter(route_class=ScrobbleRoute)


def _library(request: Request) -> Library:
    return request.app.state.scrobble_library


def _owner(request: Request) -> UUID:
    return UUID(request.state.user["id"])


def _unavailable() -> JSONResponse:
    return JSONResponse(UNAVAILABLE, status_code=503)


def _answer(value: str) -> dict[str, str]:
    """Token is never returned — only state."""
    return {"listenbrainz": value}


async def _state(conn: asyncpg.Connection, user_id: UUID) -> str:
    row = await conn.fetchrow(
        "SELECT bad FROM scrobble_accounts WHERE user_id = $1 AND service = $2",
        user_id,
        SERVICE,
    )
    if row is None:
        return "off"
    return "bad_token" if row["bad"] else "on"


@router.get("/v1/scrobble")
async def scrobble_state(request: Request) -> Any:
    try:
        conn = await _library(request).connect()
    except Unavailable:
        return _unavailable()
    try:
        return _answer(await _state(conn, _owner(request)))
    finally:
        await conn.close()


@router.post("/v1/scrobble/listenbrainz")
async def scrobble_connect(request: Request, body: TokenIn) -> Any:
    """New token replaces previous one and clears the bad flag."""
    try:
        conn = await _library(request).connect()
    except Unavailable:
        return _unavailable()
    try:
        await conn.execute(
            """
            INSERT INTO scrobble_accounts (user_id, service, token, bad, updated_at)
            VALUES ($1, $2, $3, false, now())
            ON CONFLICT (user_id, service) DO UPDATE
            SET token = EXCLUDED.token, bad = false, updated_at = now()
            """,
            _owner(request),
            SERVICE,
            body.token,
        )
        return _answer("on")
    finally:
        await conn.close()


@router.post("/v1/scrobble/listenbrainz/remove")
async def scrobble_forget(request: Request) -> Any:
    try:
        conn = await _library(request).connect()
    except Unavailable:
        return _unavailable()
    try:
        await conn.execute(
            "DELETE FROM scrobble_accounts WHERE user_id = $1 AND service = $2",
            _owner(request),
            SERVICE,
        )
        return _answer("off")
    finally:
        await conn.close()


def install_scrobble(app: FastAPI, *, database_url: str | None) -> None:
    """Install scrobble submission. In main.py — single line."""
    app.state.scrobble_library = Library(app, database_url=database_url)
    app.include_router(router)
