"""Admin API: people, their devices and the state of the server.

Only an administrator or the holder of the contour key gets in. The module
never reads what people listen to; the log names actions, never people.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import secrets
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any
from uuid import UUID

import asyncpg
from fastapi import APIRouter, FastAPI, Request
from fastapi.responses import JSONResponse

from app.env_names import sent_key
from app.users import PASSWORD_HASHER, normalize_username

logger = logging.getLogger("apertonodo")

MIN_PASSWORD = 8
MAX_PASSWORD = 1024
_MAX_BODY = 16384
_STORAGE_KEYS = ("total_bytes", "free_bytes", "cache_bytes")
# FT-856: invite codes — no 0/O, 1/I/L, so a code read aloud is typed right.
INVITE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
INVITE_DAYS = 7

router = APIRouter(prefix="/v1/admin")

Handler = Callable[
    [Request, asyncpg.Connection, dict[str, UUID]], Awaitable[JSONResponse]
]


@dataclass
class _Admin:
    database_url: str | None
    api_key: str | None
    storage: Callable[[], Any] | None


def _reply(body: Any, status: int = 200) -> JSONResponse:
    return JSONResponse(body, status_code=status, headers={"Cache-Control": "no-store"})


def _status(name: str, code: int = 200) -> JSONResponse:
    return _reply({"status": name}, code)


def _allowed(request: Request, key: str | None) -> bool:
    user = getattr(request.state, "user", None)
    if isinstance(user, dict) and user.get("is_admin") is True:
        return True
    sent = sent_key(request.headers)
    if not key or not sent:
        return False
    return secrets.compare_digest(sent.encode(), key.encode())


def _uuid(raw: str) -> UUID | None:
    if len(raw) != 36:
        return None
    try:
        return UUID(raw)
    except ValueError:
        return None


def _guarded(handler: Handler) -> Callable[[Request], Awaitable[JSONResponse]]:
    # No **kwargs here: FastAPI would take them for query parameters.
    async def wrapper(request: Request) -> JSONResponse:
        settings: _Admin = request.app.state.admin
        if not _allowed(request, settings.api_key):
            return _status("forbidden", 403)
        ids: dict[str, UUID] = {}
        for name, raw in request.path_params.items():
            parsed = _uuid(str(raw))
            if parsed is None:
                return _status("not_found", 404)
            ids[name] = parsed
        if not settings.database_url:
            return _status("unavailable", 503)
        try:
            conn = await asyncpg.connect(settings.database_url)
        except Exception:
            return _status("unavailable", 503)
        try:
            return await handler(request, conn, ids)
        except Exception as exc:
            # Only the error type: a database message can quote a username.
            logger.error("admin: request failed: %s", type(exc).__name__)
            return _status("unavailable", 503)
        finally:
            await conn.close()

    return wrapper


async def _body(request: Request) -> dict[str, Any] | None:
    raw = await request.body()
    if len(raw) > _MAX_BODY:
        return None
    try:
        data = json.loads(raw)
    except ValueError:
        return None
    return data if isinstance(data, dict) else None


def _password(value: Any) -> str | None:
    if not isinstance(value, str) or not MIN_PASSWORD <= len(value) <= MAX_PASSWORD:
        return None
    try:
        value.encode("utf-8")
    except UnicodeEncodeError:
        return None
    return value


def _signal(request: Request, digests: list[str]) -> None:
    events = getattr(request.app.state, "revocation_events", None) or {}
    for digest in digests:
        for event in events.get(digest, ()):
            event.set()


def invite_digest(code: str) -> str:
    """Digest of a code as the person may type it: case, spaces and dashes do not count."""
    plain = "".join(code.split()).replace("-", "").upper()
    return hashlib.sha256(plain.encode()).hexdigest()


async def _new_invite(conn: asyncpg.Connection, user_id: UUID) -> dict[str, str]:
    plain = "".join(secrets.choice(INVITE_ALPHABET) for _ in range(8))
    expires = datetime.now(timezone.utc) + timedelta(days=INVITE_DAYS)
    await conn.execute(
        """INSERT INTO user_invites (user_id, code_hash, expires_at) VALUES ($1, $2, $3)
           ON CONFLICT (user_id) DO UPDATE
           SET code_hash = EXCLUDED.code_hash, expires_at = EXCLUDED.expires_at, created_at = now()""",
        user_id,
        invite_digest(plain),
        expires,
    )
    return {"code": f"{plain[:4]}-{plain[4:]}", "expires_at": expires.isoformat()}


def _person(row: asyncpg.Record) -> dict[str, Any]:
    return {
        "id": str(row["id"]),
        "username": row["username"],
        "is_admin": row["is_admin"],
        "is_active": row["is_active"],
        "created_at": row["created_at"].isoformat(),
        "devices": row["devices"],
    }


async def list_users(
    request: Request, conn: asyncpg.Connection, ids: dict[str, UUID]
) -> JSONResponse:
    rows = await conn.fetch(
        """SELECT u.id, u.username, u.is_admin, u.is_active, u.created_at,
                  count(t.id) FILTER (WHERE t.expires_at > now()) AS devices
           FROM users u LEFT JOIN user_tokens t ON u.id = t.user_id
           GROUP BY u.id ORDER BY u.username"""
    )
    return _reply({"users": [_person(r) for r in rows]})


async def add_user(
    request: Request, conn: asyncpg.Connection, ids: dict[str, UUID]
) -> JSONResponse:
    invalid = _status("invalid", 422)
    body = await _body(request)
    if body is None:
        return invalid
    username, is_admin = body.get("username"), body.get("is_admin", False)
    # FT-856: no password — the person makes it up with an invite code.
    invited = "password" not in body
    password = None if invited else _password(body.get("password"))
    if (
        not isinstance(username, str)
        or (password is None and not invited)
        or not isinstance(is_admin, bool)
    ):
        return invalid
    try:
        name = normalize_username(username)
    except ValueError:
        return invalid
    digest = None if password is None else await asyncio.to_thread(PASSWORD_HASHER.hash, password)
    try:
        async with conn.transaction():
            row = await conn.fetchrow(
                """INSERT INTO users (username, password_hash, is_admin) VALUES ($1, $2, $3)
                   RETURNING id, username, is_admin, is_active, created_at, 0 AS devices""",
                name,
                digest,
                is_admin,
            )
            invite = await _new_invite(conn, row["id"]) if invited else None
    except asyncpg.UniqueViolationError:
        return _status("exists", 409)
    logger.info("admin: user added")
    reply: dict[str, Any] = {"user": _person(row)}
    if invite is not None:
        reply["invite"] = invite
    return _reply(reply, 201)


async def give_invite(
    request: Request, conn: asyncpg.Connection, ids: dict[str, UUID]
) -> JSONResponse:
    """A new code: the old password, the old code and every session of the person end."""
    async with conn.transaction():
        found = await conn.fetchval(
            "UPDATE users SET password_hash = NULL WHERE id = $1 RETURNING id", ids["user_id"]
        )
        if found is None:
            return _status("not_found", 404)
        gone = await conn.fetch(
            "DELETE FROM user_tokens WHERE user_id = $1 RETURNING token_hash", ids["user_id"]
        )
        invite = await _new_invite(conn, ids["user_id"])
    _signal(request, [r["token_hash"] for r in gone])
    logger.info("admin: invite given")
    return _reply({"invite": invite})


async def set_password(
    request: Request, conn: asyncpg.Connection, ids: dict[str, UUID]
) -> JSONResponse:
    body = await _body(request)
    password = _password(body.get("password")) if body is not None else None
    if password is None:
        return _status("invalid", 422)
    digest = await asyncio.to_thread(PASSWORD_HASHER.hash, password)
    async with conn.transaction():
        found = await conn.fetchval(
            "UPDATE users SET password_hash = $2 WHERE id = $1 RETURNING id",
            ids["user_id"],
            digest,
        )
        if found is None:
            return _status("not_found", 404)
        gone = await conn.fetch(
            "DELETE FROM user_tokens WHERE user_id = $1 RETURNING token_hash",
            ids["user_id"],
        )
    _signal(request, [r["token_hash"] for r in gone])
    logger.info("admin: password changed")
    return _status("changed")


async def _change_flag(
    request: Request, conn: asyncpg.Connection, ids: dict[str, UUID], field: str
) -> JSONResponse:
    """Set is_active or is_admin; the last active administrator keeps both."""
    body = await _body(request)
    value = (
        body.get("active" if field == "is_active" else "admin")
        if body is not None
        else None
    )
    if not isinstance(value, bool):
        return _status("invalid", 422)
    user_id = ids["user_id"]
    gone: list[Any] = []
    async with conn.transaction():
        # One statement locks the person and all active admins; a rare deadlock rolls back to 503.
        rows = await conn.fetch(
            """SELECT id, is_admin, is_active FROM users
               WHERE id = $1 OR (is_admin AND is_active) ORDER BY id FOR UPDATE""",
            user_id,
        )
        target = next((r for r in rows if r["id"] == user_id), None)
        if target is None:
            return _status("not_found", 404)
        sole = (
            target["is_admin"]
            and target["is_active"]
            and sum(1 for r in rows if r["is_admin"] and r["is_active"]) == 1
        )
        if sole and not value:
            return _status("last_admin", 409)
        await conn.execute(
            f"UPDATE users SET {field} = $2 WHERE id = $1", user_id, value
        )
        if field == "is_active" and not value:
            gone = await conn.fetch(
                "DELETE FROM user_tokens WHERE user_id = $1 RETURNING token_hash",
                user_id,
            )
    _signal(request, [r["token_hash"] for r in gone])
    if field == "is_active":
        logger.info("admin: user enabled" if value else "admin: user disabled")
        return _status("active" if value else "inactive")
    logger.info("admin: rights changed")
    return _status("admin" if value else "user")


async def set_active(
    request: Request, conn: asyncpg.Connection, ids: dict[str, UUID]
) -> JSONResponse:
    return await _change_flag(request, conn, ids, "is_active")


async def set_admin(
    request: Request, conn: asyncpg.Connection, ids: dict[str, UUID]
) -> JSONResponse:
    return await _change_flag(request, conn, ids, "is_admin")


async def list_devices(
    request: Request, conn: asyncpg.Connection, ids: dict[str, UUID]
) -> JSONResponse:
    if await conn.fetchval("SELECT 1 FROM users WHERE id = $1", ids["user_id"]) is None:
        return _status("not_found", 404)
    rows = await conn.fetch(
        """SELECT id, device_name, last_used_date, created_at FROM user_tokens
           WHERE user_id = $1 AND expires_at > now() ORDER BY created_at, id""",
        ids["user_id"],
    )
    return _reply(
        {
            "devices": [
                {
                    "id": str(r["id"]),
                    "device_name": r["device_name"],
                    "last_used_date": r["last_used_date"].isoformat(),
                    "created_at": r["created_at"].isoformat(),
                }
                for r in rows
            ]
        }
    )


async def revoke_device(
    request: Request, conn: asyncpg.Connection, ids: dict[str, UUID]
) -> JSONResponse:
    digest = await conn.fetchval(
        "DELETE FROM user_tokens WHERE id = $1 AND user_id = $2 RETURNING token_hash",
        ids["device_id"],
        ids["user_id"],
    )
    if digest is None:
        return _status("not_found", 404)
    _signal(request, [digest])
    logger.info("admin: device revoked")
    return _status("revoked")


def _space(probe: Callable[[], Any] | None) -> dict[str, int] | None:
    if probe is None:
        return None
    try:
        data = probe()
        out = {k: data[k] for k in _STORAGE_KEYS}
    except Exception:
        return None
    if any(type(v) is not int or v < 0 for v in out.values()):
        return None
    return out


async def server_state(
    request: Request, conn: asyncpg.Connection, ids: dict[str, UUID]
) -> JSONResponse:
    people = await conn.fetchrow(
        """SELECT count(*) AS total, count(*) FILTER (WHERE is_active) AS active,
                  count(*) FILTER (WHERE is_admin AND is_active) AS admins FROM users"""
    )
    devices = await conn.fetchval(
        "SELECT count(*) FROM user_tokens WHERE expires_at > now()"
    )
    storage = await asyncio.to_thread(_space, request.app.state.admin.storage)
    return _reply(
        {
            "database": "ok",
            "users": {
                "total": people["total"],
                "active": people["active"],
                "admins": people["admins"],
            },
            "devices": devices,
            "storage": storage,
        }
    )


router.add_api_route("/users", _guarded(list_users), methods=["GET"])
router.add_api_route("/users", _guarded(add_user), methods=["POST"])
router.add_api_route(
    "/users/{user_id}/password", _guarded(set_password), methods=["POST"]
)
router.add_api_route("/users/{user_id}/invite", _guarded(give_invite), methods=["POST"])
router.add_api_route("/users/{user_id}/active", _guarded(set_active), methods=["POST"])
router.add_api_route("/users/{user_id}/admin", _guarded(set_admin), methods=["POST"])
router.add_api_route(
    "/users/{user_id}/devices", _guarded(list_devices), methods=["GET"]
)
router.add_api_route(
    "/users/{user_id}/devices/{device_id}/revoke",
    _guarded(revoke_device),
    methods=["POST"],
)
router.add_api_route("/state", _guarded(server_state), methods=["GET"])


def install_admin(
    app: FastAPI,
    *,
    database_url: str | None,
    api_key: str | None = None,
    storage: Callable[[], Any] | None = None,
) -> None:
    app.state.admin = _Admin(database_url, api_key, storage)
    app.include_router(router)
