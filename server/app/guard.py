from __future__ import annotations

import logging
import secrets
from collections.abc import Mapping
from typing import Any
from uuid import UUID

import asyncpg
from fastapi.responses import JSONResponse

from app.auth import user_for_token
from app.store import token_hash

logger = logging.getLogger("apertonodo")

# Header where application passes the key. Intentionally not a query parameter:
# query parameters do not reach access log (app/access_log.py), but remain in proxy
# history and in shareable URLs that can be forwarded accidentally.
API_KEY_HEADER = b"x-apertonodo-key"
# Old header name: production CI, owner scripts and installed apps still send it.
OLD_API_KEY_HEADER = b"x-flowtune-key"  # old name, accepted until clients are moved

# Exactly six paths are open. /v1/health has public smoke test and must
# work without credentials. /v1/auth/login — client does not carry shared key
# and logs in with username and password; if locked, nobody could log in.
# /v1/auth/claim (FT-856) — first login by invitation code: the person has no
# password yet and invents it here.
# Three /admin page files (FT-699): contain no data, page logs in via
# /v1/auth/login, while its /v1/admin/* endpoints remain locked.
# Everything else is locked — /v1/ready, /docs, /openapi.json and the stream itself.
# An allowlist rather than a blocklist: any new endpoint is locked by default,
# rather than remaining exposed until remembered.
OPEN_PATHS = frozenset(
    {"/v1/health", "/v1/auth/login", "/v1/auth/claim", "/admin", "/admin/admin.css", "/admin/admin.js"}
)

# A shorter key is a typo or placeholder like "test", not real security.
MIN_API_KEY_LEN = 32

GENERATE_HINT = "python3 -c 'import secrets; print(secrets.token_urlsafe(32))'"


def require_api_key(env: Mapping[str, str]) -> str:
    """Retrieve key from environment or fail startup.

    Failing fast was chosen over "start up and lock everything": a server
    silently responding 401 to every request looks like a broken client,
    and debugging would start on the phone. A failed process reports the
    cause directly — and public smoke test fails in CI immediately.
    """
    key = str(env.get("MUSIC_API_KEY", "")).strip()
    if len(key) < MIN_API_KEY_LEN:
        raise RuntimeError(
            f"MUSIC_API_KEY is not set or shorter than {MIN_API_KEY_LEN} characters — "
            "public perimeter must not be opened without a key. "
            f"Generate: {GENERATE_HINT}"
        )
    return key


def _key_ok(headers: Any, key: bytes) -> bool:
    """At most one header per name; every key header sent (new, old or both) must be right."""
    new = [v for n, v in headers if n.lower() == API_KEY_HEADER]
    old = [v for n, v in headers if n.lower() == OLD_API_KEY_HEADER]
    if len(new) > 1 or len(old) > 1 or not (new or old):
        return False
    return all(secrets.compare_digest(v, key) for v in new + old)


class ApiKeyGuard:
    """Guard for public perimeter: ASGI middleware, not `@app.middleware`.

    `@app.middleware("http")` wraps every response in BaseHTTPMiddleware,
    which wraps the long-running StreamingResponse of audio streams — an extra
    task group on every client disconnect mid-song is undesirable here. This
    implementation wraps nothing: it either returns 401 directly or steps aside.
    """

    def __init__(self, app: Any, key: str) -> None:
        self.app = app
        self.key = key.strip().encode()

    async def __call__(self, scope: dict[str, Any], receive: Any, send: Any) -> None:
        # Check websocket as well, not only http: otherwise "new endpoint is
        # locked by default" would only be half true — websocket routes would
        # bypass the guard. Only lifespan is allowed through unconditionally.
        kind = scope.get("type")
        if kind not in ("http", "websocket") or self._allowed(scope):
            await self.app(scope, receive, send)
            return
        # Neither provided value nor request path with query are logged.
        logger.info("unauthorized")
        if kind == "websocket":
            # Close before accept — per ASGI spec this rejects with 403.
            await send({"type": "websocket.close", "code": 1008})
            return
        response = JSONResponse({"status": "unauthorized"}, status_code=401)
        await response(scope, receive, send)

    def _allowed(self, scope: dict[str, Any]) -> bool:
        path = str(scope.get("path", "")).rstrip("/") or "/"
        if path in OPEN_PATHS:
            return True
        # A bearer is let through only where UserGuard checks it against the token table:
        # under /v1/. Outside it a made-up "Bearer x" opened /docs and /openapi.json.
        for name, value in scope.get("headers") or () if path.startswith("/v1/") else ():
            if name.lower() == b"authorization":
                parts = value.split(b" ", 1)
                if len(parts) == 2 and parts[0].lower() == b"bearer":
                    return True
        if not self.key:
            # Guard without key is locked, not open: otherwise an empty
            # environment variable would quietly expose the entire perimeter.
            return False
        # compare_digest, not ==: standard comparison aborts on the
        # first mismatched byte, leaking key timing information.
        return _key_ok(scope.get("headers") or (), self.key)


class UserGuard:
    """Resolve a live bearer once for each protected API request."""

    OPEN_PATHS = frozenset({"/v1/health", "/v1/auth/login", "/v1/auth/claim"})

    def __init__(
        self, app: Any, database_url: str | None, api_key: str | None = None
    ) -> None:
        self.app = app
        self.database_url = database_url
        self.api_key_bytes = api_key.strip().encode() if api_key and api_key.strip() else None

    async def __call__(self, scope: dict[str, Any], receive: Any, send: Any) -> None:
        kind = scope.get("type")
        path = str(scope.get("path", ""))
        if kind not in ("http", "websocket") or not path.startswith("/v1/") or path in self.OPEN_PATHS:
            await self.app(scope, receive, send)
            return
        headers = [value for name, value in scope.get("headers", ()) if name.lower() == b"authorization"]
        if headers:
            parts = headers[0].split(b" ", 1) if len(headers) == 1 else []
            if len(parts) != 2 or parts[0] != b"Bearer" or not parts[1].isascii() or not parts[1]:
                await self._deny(scope, receive, send, 401)
                return
            if not self.database_url:
                await self._deny(scope, receive, send, 503)
                return
            try:
                conn = await asyncpg.connect(self.database_url)
                try:
                    user_id = await user_for_token(conn, parts[1].decode("ascii"))
                    user = await conn.fetchrow(
                        "SELECT id, is_admin FROM users WHERE id = $1 AND is_active", UUID(user_id)
                    ) if user_id else None
                finally:
                    await conn.close()
            except Exception:
                await self._deny(scope, receive, send, 503)
                return
            if user is None:
                await self._deny(scope, receive, send, 401)
                return
            scope.setdefault("state", {})["user"] = {"id": str(user["id"]), "is_admin": user["is_admin"]}
            scope["state"]["bearer_hash"] = token_hash(parts[1].decode("ascii"))
            await self.app(scope, receive, send)
            return

        if self.api_key_bytes is not None:
            if _key_ok(scope.get("headers", ()), self.api_key_bytes):
                owner_id: UUID | None = None
                if self.database_url:
                    try:
                        conn = await asyncpg.connect(self.database_url)
                        try:
                            from app.users import ensure_owner_id

                            owner_id = await ensure_owner_id(conn)
                            owner_active = await conn.fetchval(
                                "SELECT is_active FROM users WHERE id = $1", owner_id
                            )
                        finally:
                            await conn.close()
                    except Exception:
                        await self._deny(scope, receive, send, 503)
                        return
                    if not owner_active:
                        await self._deny(scope, receive, send, 401)
                        return
                elif owner_id is None:
                    owner_id = UUID(int=0)
                scope.setdefault("state", {})["user"] = {"id": str(owner_id), "is_admin": False}
                await self.app(scope, receive, send)
                return

        await self._deny(scope, receive, send, 401)

    @staticmethod
    async def _deny(scope: dict[str, Any], receive: Any, send: Any, status: int) -> None:
        if scope["type"] == "websocket":
            await send({"type": "websocket.close", "code": 1013 if status == 503 else 1008})
            return
        body = {"status": "unavailable" if status == 503 else "unauthorized"}
        await JSONResponse(body, status_code=status)(scope, receive, send)
