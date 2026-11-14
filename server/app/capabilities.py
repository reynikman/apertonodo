"""FT-637 (P-A96, P-A97, contract D4): capability list and installation ID.

The server tells the application which features are enabled and configured, and also
reports its permanent installation ID, which helps the client distinguish
a server relocation from the appearance of another service at the same address.
"""

from __future__ import annotations

import inspect
import re
from typing import Any
from uuid import UUID

import asyncpg
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from app.library import Library, Unavailable, UNAVAILABLE

API_LEVEL: int = 1

CAPABILITY_PATTERN = re.compile(r"^[a-z][a-z0-9_]{0,39}\Z")


async def server_id(conn: asyncpg.Connection) -> UUID:
    """Return the server's persistent installation ID, creating it on first access."""
    await conn.execute(
        "INSERT INTO server_identity (is_singleton) VALUES (true) "
        "ON CONFLICT (is_singleton) DO NOTHING"
    )
    val = await conn.fetchval(
        "SELECT server_id FROM server_identity WHERE is_singleton"
    )
    if isinstance(val, UUID):
        return val
    return UUID(str(val))


def feature_off(word: str) -> JSONResponse:
    """Generic "feature disabled" response for other modules."""
    return JSONResponse(
        {"status": "feature_off", "feature": word},
        status_code=409,
    )


def install_capabilities(
    app: FastAPI,
    *,
    database_url: str | None,
    words: Any,
) -> None:
    """Install endpoint /v1/capabilities on the application."""
    library = Library(app, database_url=database_url)

    @app.get("/v1/capabilities")
    async def get_capabilities(request: Request) -> JSONResponse:
        try:
            conn = await library.connect()
        except Unavailable:
            return JSONResponse(UNAVAILABLE, status_code=503)

        try:
            sid = await server_id(conn)
        finally:
            await conn.close()

        try:
            raw = words(request)
            if inspect.isawaitable(raw):
                raw = await raw
            capabilities = sorted(
                {
                    w
                    for w in raw
                    if isinstance(w, str) and CAPABILITY_PATTERN.fullmatch(w)
                }
            )
        except Exception:
            return JSONResponse(
                {"status": "capabilities_unavailable"},
                status_code=503,
            )

        return JSONResponse(
            {
                "server_id": str(sid),
                "api": API_LEVEL,
                "capabilities": capabilities,
            },
            headers={"Cache-Control": "no-store"},
        )
