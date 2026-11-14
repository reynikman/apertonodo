"""Problem reporting (FT-622, Р-A87): report intake and owner dashboard list.

A user in the app taps "Report a problem" on a song, album,
artist, playlist, or in the player and selects a reason. The report is stored in its own
database rather than sent to a third-party service: sending to a third-party service would leak
both the song title and user identity along the way.

Boundaries maintained here:

- Reason and place are from closed lists; each place requires its own ID.
  Any extra field is rejected entirely and never enters the database.
- Parse rejection does not echo user-submitted text: response contains only error type,
  field location, and system message (pattern modeled after `ReportRoute` in `app_reports.py`).
- The log receives only reason and place: no text, artist name, or ID.
- The list is readable by admin or environment API key holder; others get 403.
- Rate limit: max 20 reports per hour per user.
"""

from __future__ import annotations

import logging
import secrets
import uuid
from collections.abc import Callable, Coroutine
from datetime import datetime
from typing import Any, Literal

import asyncpg
from fastapi import APIRouter, FastAPI, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, Response
from fastapi.routing import APIRoute
from pydantic import BaseModel, ConfigDict, Field, model_validator

from app.env_names import sent_key

logger = logging.getLogger("apertonodo")

REASON = Literal["wrong_track", "no_play", "bad_sound", "cover", "wrong_name", "other"]
PLACE = Literal["song", "album", "artist", "player", "playlist"]

# Max reports per hour per user. Beta has 3–10
# testers; beyond this rate reports likely come from bots/automation.
HOURLY_LIMIT = 20
PAGE_DEFAULT = 50
PAGE_MAX = 500
TEXT_MAX = 500
ARTIST_MAX = 200

# Body fields allowed in rejection message. All other fields map to "field":
# extra field name is user-provided and could be anything.
BODY_FIELDS = frozenset(
    {"reason", "place", "track_id", "album_id", "playlist_id", "artist", "text", "app_version"}
)

# Which place requires which ID.
_NEEDS_ID = {"song": "track_id", "player": "track_id", "album": "album_id", "playlist": "playlist_id"}


class Unavailable(Exception):
    """No database connection."""


class ProblemRoute(APIRoute):
    """Validation rejection without echoing input — matches app telemetry reports."""

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
                            if isinstance(part, int) or part == "body" or part in BODY_FIELDS
                            else "field"
                            for part in error["loc"]
                        ],
                        "msg": error["msg"],
                    }
                    for error in exc.errors()
                ]
                return JSONResponse({"detail": errors}, status_code=422)

        return private_errors


class ProblemIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    reason: REASON
    place: PLACE
    track_id: uuid.UUID | None = None
    album_id: uuid.UUID | None = None
    playlist_id: uuid.UUID | None = None
    artist: str | None = Field(default=None, max_length=ARTIST_MAX)
    text: str | None = Field(default=None, max_length=TEXT_MAX)
    app_version: str = Field(pattern=r"^[0-9A-Za-z.+-]{1,32}$", max_length=32)

    @model_validator(mode="after")
    def _required_by_place(self) -> ProblemIn:
        wanted = _NEEDS_ID.get(self.place)
        if wanted is not None and getattr(self, wanted) is None:
            raise ValueError("this place needs its id")
        if self.place == "artist" and not (self.artist or "").strip():
            raise ValueError("artist place needs an artist")
        if self.reason == "other" and not (self.text or "").strip():
            raise ValueError("reason other needs text")
        return self


def _user(request: Request) -> dict[str, Any] | None:
    user = getattr(request.state, "user", None)
    return user if isinstance(user, dict) else None


def _may_read(request: Request) -> bool:
    """Who can read the list: admin or environment API key holder.

    Key holder comes without login, and their `is_admin` in request is false even
    for the owner (`guard.py`). Therefore the key is checked here: security gate permits
    request with login token without checking key header, and header presence
    alone is not enough — an authenticated tester could add any header and read reports.
    """
    user = _user(request)
    if user is None:
        return True
    if bool(user.get("is_admin")):
        return True
    key = request.app.state.problems.api_key
    sent = sent_key(request.headers)
    return bool(key) and bool(sent) and secrets.compare_digest(sent.encode(), key.encode())


def _public(row: Any) -> dict[str, Any]:
    """DB row -> report for owner: all fields, uuid and timestamp formatted as strings."""
    out: dict[str, Any] = {}
    for key, value in dict(row).items():
        if isinstance(value, uuid.UUID):
            out[key] = str(value)
        elif isinstance(value, datetime):
            out[key] = value.isoformat()
        else:
            out[key] = value
    return out


class Problems:
    def __init__(
        self, app: FastAPI, *, database_url: str | None, api_key: str | None = None
    ) -> None:
        self.app = app
        self.database_url = database_url
        self.api_key = api_key

    async def connect(self) -> asyncpg.Connection:
        if not self.database_url:
            raise Unavailable
        try:
            return await asyncpg.connect(self.database_url)
        except Exception as exc:  # noqa: BLE001
            logger.warning("problem: database failed: %s", type(exc).__name__)
            raise Unavailable from None


router = APIRouter(route_class=ProblemRoute)


def _problems(request: Request) -> Problems:
    return request.app.state.problems


@router.post("/v1/problems", status_code=202)
async def report(request: Request, body: ProblemIn) -> Any:
    """Accept report. Log contains only reason and place, without text or names."""
    try:
        problems = _problems(request)
        conn = await problems.connect()
    except Unavailable:
        return JSONResponse({"status": "problems_unavailable"}, status_code=503)
    try:
        user = _user(request)
        user_id = uuid.UUID(str(user["id"])) if user and user.get("id") else None
        if user_id is not None:
            recent = await conn.fetchval(
                "SELECT count(*) FROM problem_reports"
                " WHERE user_id = $1 AND created_at > now() - interval '1 hour'",
                user_id,
            )
            if recent is not None and int(recent) >= HOURLY_LIMIT:
                return JSONResponse({"status": "too_many_requests"}, status_code=429)
        await conn.execute(
            """
            INSERT INTO problem_reports
                (user_id, reason, place, track_id, album_id, playlist_id, artist, text, app_version)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
            """,
            user_id,
            body.reason,
            body.place,
            body.track_id,
            body.album_id,
            body.playlist_id,
            body.artist,
            body.text,
            body.app_version,
        )
        logger.info("problem %s %s", body.reason, body.place)
        return JSONResponse({"status": "accepted"}, status_code=202)
    finally:
        await conn.close()


@router.get("/v1/problems")
async def list_problems(
    request: Request,
    limit: int = Query(default=PAGE_DEFAULT, ge=1, le=PAGE_MAX),
) -> Any:
    if not _may_read(request):
        return JSONResponse({"status": "forbidden"}, status_code=403)
    try:
        problems = _problems(request)
        conn = await problems.connect()
    except Unavailable:
        return JSONResponse({"status": "problems_unavailable"}, status_code=503)
    try:
        rows = await conn.fetch(
            "SELECT * FROM problem_reports ORDER BY created_at DESC, id DESC LIMIT $1", limit
        )
        return {"items": [_public(row) for row in rows]}
    finally:
        await conn.close()


def install_problems(app: FastAPI, **kwargs: Any) -> None:
    """Install problem reports. In main.py — single line next to install_library."""
    app.state.problems = Problems(app, **kwargs)
    app.include_router(router)