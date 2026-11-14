"""FT-645 (P-A96, P-A97, contract D1, item 11; feature B6, step C6b-2): Last.fm connect.

Endpoints:
- GET /v1/scrobble/lastfm — current state (unavailable, pending, on, bad_token, off).
- POST /v1/scrobble/lastfm/start — request one-time token (auth.getToken) and approval URL.
- POST /v1/scrobble/lastfm/finish — exchange approved token for session key (auth.getSession).
- POST /v1/scrobble/lastfm/remove — disconnect: remove Last.fm token and key.
"""

from __future__ import annotations

from typing import Any
from uuid import UUID

import asyncpg
import httpx
from fastapi import APIRouter, FastAPI, Request
from fastapi.responses import JSONResponse

from app.lastfm_scrobble import approve_url, get_session, request_token
from app.library import UNAVAILABLE, Library, Unavailable

SERVICE = "lastfm"
# First lock key component "authorization check in progress"; second is user.
_CHECKING = 645

router = APIRouter()


def _library(request: Request) -> Library:
    return request.app.state.lastfm_library


def _api_key(request: Request) -> str:
    return str(getattr(request.app.state, "lastfm_api_key", ""))


def _api_secret(request: Request) -> str:
    return str(getattr(request.app.state, "lastfm_api_secret", ""))


def _client(request: Request) -> httpx.AsyncClient | None:
    return getattr(request.app.state, "lastfm_client", None)


def _is_available(request: Request) -> bool:
    return bool(
        _api_key(request) and _api_secret(request) and _client(request) is not None
    )


def _owner(request: Request) -> UUID:
    return UUID(str(request.state.user["id"]))


def _unavailable() -> JSONResponse:
    return JSONResponse(UNAVAILABLE, status_code=503)


async def _get_living_token(conn: asyncpg.Connection, user_id: UUID) -> str | None:
    row = await conn.fetchrow(
        "SELECT token, (created_at >= now() - interval '60 minutes') AS alive "
        "FROM lastfm_pending WHERE user_id = $1",
        user_id,
    )
    if row is None:
        return None
    if not row["alive"]:
        await conn.execute(
            "DELETE FROM lastfm_pending WHERE user_id = $1 AND token = $2",
            user_id,
            row["token"],
        )
        return None
    return str(row["token"])


async def _get_state(conn: asyncpg.Connection, user_id: UUID) -> str:
    token = await _get_living_token(conn, user_id)
    if token is not None:
        return "pending"
    account = await conn.fetchrow(
        "SELECT bad FROM scrobble_accounts WHERE user_id = $1 AND service = $2",
        user_id,
        SERVICE,
    )
    if account is None:
        return "off"
    return "bad_token" if account["bad"] else "on"


@router.get("/v1/scrobble/lastfm")
async def lastfm_state(request: Request) -> Any:
    if not _is_available(request):
        return JSONResponse({"lastfm": "unavailable"}, status_code=200)
    try:
        conn = await _library(request).connect()
    except Unavailable:
        return _unavailable()
    try:
        state = await _get_state(conn, _owner(request))
        return JSONResponse({"lastfm": state}, status_code=200)
    finally:
        await conn.close()


@router.post("/v1/scrobble/lastfm/start")
async def lastfm_start(request: Request) -> Any:
    if not _is_available(request):
        return JSONResponse({"lastfm": "unavailable"}, status_code=404)
    try:
        conn = await _library(request).connect()
    except Unavailable:
        return _unavailable()
    try:
        client = _client(request)
        assert client is not None
        api_key = _api_key(request)
        api_secret = _api_secret(request)
        token = await request_token(
            client,
            api_key=api_key,
            api_secret=api_secret,
        )
        if token is None:
            return JSONResponse({"lastfm": "failed"}, status_code=502)
        user_id = _owner(request)
        # Users who abandoned without approving will not clean up their token.
        await conn.execute(
            "DELETE FROM lastfm_pending WHERE created_at < now() - interval '60 minutes'"
        )
        await conn.execute(
            """
            INSERT INTO lastfm_pending (user_id, token, created_at)
            VALUES ($1, $2, now())
            ON CONFLICT (user_id) DO UPDATE
            SET token = EXCLUDED.token, created_at = now()
            """,
            user_id,
            token,
        )
        url = approve_url(api_key, token)
        return JSONResponse({"lastfm": "pending", "url": url}, status_code=200)
    finally:
        await conn.close()


@router.post("/v1/scrobble/lastfm/finish")
async def lastfm_finish(request: Request) -> Any:
    if not _is_available(request):
        return JSONResponse({"lastfm": "unavailable"}, status_code=404)
    try:
        conn = await _library(request).connect()
    except Unavailable:
        return _unavailable()
    try:
        user_id = _owner(request)
        # Token is single-use: concurrent check along with first would get "expired" from Last.fm
        # and erase token before first writes key. Lock holds connection and releases with it.
        alone = await conn.fetchval(
            "SELECT pg_try_advisory_lock($1, hashtext($2))", _CHECKING, str(user_id)
        )
        token = await _get_living_token(conn, user_id)
        if token is None or not alone:
            state = await _get_state(conn, user_id)
            return JSONResponse({"lastfm": state}, status_code=200)

        client = _client(request)
        assert client is not None
        status, session_key = await get_session(
            client,
            api_key=_api_key(request),
            api_secret=_api_secret(request),
            token=token,
        )

        if status == "pending":
            return JSONResponse({"lastfm": "pending"}, status_code=200)

        if status == "expired":
            await conn.execute(
                "DELETE FROM lastfm_pending WHERE user_id = $1 AND token = $2",
                user_id,
                token,
            )
            return JSONResponse({"lastfm": "expired"}, status_code=200)

        if status == "ok" and session_key is not None:
            async with conn.transaction():
                deleted = await conn.execute(
                    "DELETE FROM lastfm_pending WHERE user_id = $1 AND token = $2",
                    user_id,
                    token,
                )
                if deleted == "DELETE 1":
                    await conn.execute(
                        """
                        INSERT INTO scrobble_accounts (user_id, service, token, bad, updated_at)
                        VALUES ($1, $2, $3, false, now())
                        ON CONFLICT (user_id, service) DO UPDATE
                        SET token = EXCLUDED.token, bad = false, updated_at = now()
                        """,
                        user_id,
                        SERVICE,
                        session_key,
                    )
            state = await _get_state(conn, user_id)
            return JSONResponse({"lastfm": state}, status_code=200)

        return JSONResponse({"lastfm": "failed"}, status_code=502)
    finally:
        await conn.close()


@router.post("/v1/scrobble/lastfm/remove")
async def lastfm_remove(request: Request) -> Any:
    try:
        conn = await _library(request).connect()
    except Unavailable:
        return _unavailable()
    try:
        user_id = _owner(request)
        async with conn.transaction():
            await conn.execute(
                "DELETE FROM lastfm_pending WHERE user_id = $1",
                user_id,
            )
            await conn.execute(
                "DELETE FROM scrobble_accounts WHERE user_id = $1 AND service = $2",
                user_id,
                SERVICE,
            )
        state = "unavailable" if not _is_available(request) else "off"
        return JSONResponse({"lastfm": state}, status_code=200)
    finally:
        await conn.close()


def install_lastfm_connect(
    app: FastAPI,
    *,
    database_url: str | None,
    api_key: str,
    api_secret: str,
    client: httpx.AsyncClient | None,
) -> None:
    app.state.lastfm_library = Library(app, database_url=database_url)
    app.state.lastfm_api_key = api_key
    app.state.lastfm_api_secret = api_secret
    app.state.lastfm_client = client
    app.include_router(router)
