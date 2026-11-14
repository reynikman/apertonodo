"""FT-630 (P-A49): history management — delete row, clear all, pause recording."""

from __future__ import annotations

from datetime import datetime
from typing import Any
from uuid import UUID

import asyncpg
from fastapi import APIRouter, FastAPI, Request
from fastapi.responses import JSONResponse
from pydantic import (
    AwareDatetime,
    BaseModel,
    ConfigDict,
    FutureDatetime,
    StrictBool,
    field_validator,
)

from app.library import UNAVAILABLE, Library, Unavailable
from app.play_reports import drop_waiting

router = APIRouter()


class HistoryRemoveIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    track_id: UUID
    played_at: AwareDatetime


class HistoryPauseIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    paused: StrictBool
    # FT-853: the person chooses the duration (an hour, until tomorrow, "until I turn it on again" —
    # that is just a far-off deadline). Without it, the previous three hours.
    until: FutureDatetime | None = None

    @field_validator("until")
    @classmethod
    def _with_zone(cls, value: datetime | None) -> datetime | None:
        if value is not None and value.tzinfo is None:
            raise ValueError("until needs a time zone")
        return value


def _owner(request: Request) -> UUID:
    return UUID(request.state.user["id"])


async def _open(request: Request) -> asyncpg.Connection:
    library: Library | None = getattr(
        request.app.state, "history_control_library", None
    )
    if library is None:
        library = getattr(request.app.state, "library", None)
    if library is None:
        raise Unavailable
    return await library.connect()


async def history_paused(conn: asyncpg.Connection, user_id: UUID) -> bool:
    """True only if the user has a pause row with an expiration in the future."""
    result = await conn.fetchval(
        "SELECT EXISTS (SELECT 1 FROM history_pause WHERE user_id = $1 AND until > now())",
        user_id,
    )
    return bool(result)


@router.post("/v1/history/remove")
async def history_remove(request: Request, body: HistoryRemoveIn) -> Any:
    try:
        conn = await _open(request)
    except Unavailable:
        return JSONResponse(UNAVAILABLE, status_code=503)
    try:
        user_id = _owner(request)
        deleted_id = await conn.fetchval(
            """
            DELETE FROM listens
            WHERE id = (
                SELECT id FROM listens
                WHERE user_id = $1 AND track_id = $2 AND played_at = $3
                ORDER BY id DESC
                LIMIT 1
            )
            RETURNING id
            """,
            user_id,
            body.track_id,
            body.played_at,
        )
        return {"removed": 1 if deleted_id is not None else 0}
    finally:
        await conn.close()


@router.post("/v1/history/clear")
async def history_clear(request: Request) -> Any:
    try:
        conn = await _open(request)
    except Unavailable:
        return JSONResponse(UNAVAILABLE, status_code=503)
    try:
        user_id = _owner(request)
        removed = await conn.fetchval(
            """
            WITH deleted AS (
                DELETE FROM listens
                WHERE user_id = $1
                RETURNING 1
            )
            SELECT count(*) FROM deleted
            """,
            user_id,
        )
        return {"removed": int(removed or 0)}
    finally:
        await conn.close()


@router.post("/v1/history/pause")
async def history_pause_set(request: Request, body: HistoryPauseIn) -> Any:
    try:
        conn = await _open(request)
    except Unavailable:
        return JSONResponse(UNAVAILABLE, status_code=503)
    try:
        user_id = _owner(request)
        if body.paused:
            until = await conn.fetchval(
                """
                INSERT INTO history_pause (user_id, until)
                VALUES ($1, COALESCE($2, now() + interval '3 hours'))
                ON CONFLICT (user_id)
                DO UPDATE SET until = EXCLUDED.until
                RETURNING until
                """,
                user_id,
                body.until,
            )
            # D1 item 9: requests waiting for external dispatch are cancelled; sent ones are not.
            await drop_waiting(conn, user_id)
            return {"paused": True, "until": until.isoformat()}
        await conn.execute("DELETE FROM history_pause WHERE user_id = $1", user_id)
        return {"paused": False, "until": None}
    finally:
        await conn.close()


@router.get("/v1/history/pause")
async def history_pause_get(request: Request) -> Any:
    try:
        conn = await _open(request)
    except Unavailable:
        return JSONResponse(UNAVAILABLE, status_code=503)
    try:
        user_id = _owner(request)
        until = await conn.fetchval(
            "SELECT until FROM history_pause WHERE user_id = $1 AND until > now()",
            user_id,
        )
        if until is None:
            return {"paused": False, "until": None}
        return {"paused": True, "until": until.isoformat()}
    finally:
        await conn.close()


def install_history_control(app: FastAPI, *, database_url: str | None) -> None:
    """Attach history management to the application."""
    app.state.history_control_library = Library(app, database_url=database_url)
    app.include_router(router)
