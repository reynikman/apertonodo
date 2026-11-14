"""Password login and digest-only device token storage."""

from __future__ import annotations

import asyncio
import hashlib
import json
import secrets
from collections.abc import Callable
from datetime import datetime, timezone
from uuid import UUID

import app.auth as auth_module
import asyncpg
from argon2.exceptions import InvalidHashError, VerificationError
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from app import login_limits
from app.admin import MAX_PASSWORD, MIN_PASSWORD, invite_digest
from app.users import PASSWORD_HASHER, normalize_username

_UNAUTHORIZED = {"status": "unauthorized"}
# Verify a real Argon2 hash for missing/disabled accounts, too, without a fixed secret.
_DUMMY_HASH = PASSWORD_HASHER.hash(secrets.token_urlsafe(32))
_MAX_BODY = 4096


def verify_password(stored_hash: str | None, password: str) -> bool:
    """An absent account incurs the same Argon2 verification as a real account."""
    try:
        verified = PASSWORD_HASHER.verify(stored_hash or _DUMMY_HASH, password)
    except (VerificationError, InvalidHashError):
        return False
    return stored_hash is not None and verified


async def user_for_token(conn: asyncpg.Connection, token: str) -> str | None:
    if len(token) != 43 or not token.isascii():
        return None
    digest = hashlib.sha256(token.encode("ascii")).hexdigest()
    row = await conn.fetchrow(
        """SELECT t.user_id, t.last_used_date <> CURRENT_DATE AS needs_touch
           FROM user_tokens AS t
           JOIN users AS u ON t.user_id = u.id
           WHERE t.token_hash = $1 AND u.is_active AND t.expires_at > now()""",
        digest,
    )
    if row is None:
        return None
    if row["needs_touch"]:
        user_id = await conn.fetchval(
            """UPDATE user_tokens AS t SET last_used_date = CURRENT_DATE
               FROM users AS u
               WHERE t.token_hash = $1 AND t.user_id = u.id
                 AND u.is_active AND t.expires_at > now()
               RETURNING t.user_id""",
            digest,
        )
        return str(user_id) if user_id is not None else None
    return str(row["user_id"])


def install_auth(
    app: FastAPI, database_url: str | None, *, now: Callable[[], datetime] | None = None
) -> None:
    clock = now or (lambda: datetime.now(timezone.utc))

    @app.post("/v1/auth/login")
    async def login(request: Request) -> JSONResponse:
        size = 0
        chunks = []
        async for chunk in request.stream():
            size += len(chunk)
            if size > _MAX_BODY:
                return JSONResponse({"status": "invalid_request"}, status_code=400)
            chunks.append(chunk)
        try:
            body = json.loads(b"".join(chunks))
        except (ValueError, UnicodeDecodeError):
            return JSONResponse({"status": "invalid_request"}, status_code=400)
        if not isinstance(body, dict) or any(
            not isinstance(body.get(key), str) for key in ("username", "password", "device_name")
        ):
            return JSONResponse({"status": "invalid_request"}, status_code=400)
        username, password, device_name = (body[key] for key in ("username", "password", "device_name"))
        if not (len(username) <= 128 and len(password) <= 1024
                and 1 <= len(device_name.strip()) <= 100 and device_name.strip().isprintable()):
            return JSONResponse({"status": "invalid_request"}, status_code=400)
        try:
            password.encode("utf-8")
        except UnicodeEncodeError:
            return JSONResponse({"status": "invalid_request"}, status_code=400)
        try:
            name = normalize_username(username)
        except ValueError:
            return JSONResponse(_UNAUTHORIZED, status_code=401)
        if database_url is None:
            return JSONResponse({"status": "unavailable"}, status_code=503)
        try:
            conn = await asyncpg.connect(database_url)
        except Exception:
            return JSONResponse({"status": "unavailable"}, status_code=503)
        try:
            row = await conn.fetchrow(
                "SELECT id, password_hash, is_active FROM users WHERE username = $1", name
            )
            stored = row["password_hash"] if row and row["is_active"] else None
            try:
                with login_limits.using(conn):
                    async with login_limits.admit(name, clock):
                        matches = await asyncio.to_thread(auth_module.verify_password, stored, password)
            except login_limits.LoginLimited as exc:
                return JSONResponse(
                    {"status": "too_many_attempts"}, status_code=429,
                    headers={"Retry-After": str(exc.retry_after)},
                )
            except Exception:
                return JSONResponse({"status": "unavailable"}, status_code=503)
            if not row or not row["is_active"] or not row["password_hash"] or not matches:
                try:
                    await login_limits.record_failure(conn, name, clock())
                except Exception:
                    return JSONResponse({"status": "unavailable"}, status_code=503)
                return JSONResponse(_UNAUTHORIZED, status_code=401)
            try:
                await login_limits.reset_failures(conn, name)
            except Exception:
                return JSONResponse({"status": "unavailable"}, status_code=503)
            token = secrets.token_urlsafe(32)
            issued = await conn.fetchval(
                """INSERT INTO user_tokens (user_id, token_hash, device_name, last_used_date, expires_at)
                   SELECT id, $2, $3, CURRENT_DATE, now() + interval '90 days'
                   FROM users WHERE id = $1 AND is_active AND password_hash = $4 FOR UPDATE
                   RETURNING id""",
                row["id"], hashlib.sha256(token.encode()).hexdigest(), device_name.strip(), stored,
            )
            if issued is None:
                return JSONResponse(_UNAUTHORIZED, status_code=401)
            # user_id is the key under which the application holds downloads for this user
            # (contracts/auth-login.response.json).
            return JSONResponse(
                {"token": token, "user_id": str(row["id"])}, headers={"Cache-Control": "no-store"}
            )
        finally:
            await conn.close()

    async def _connection() -> asyncpg.Connection | None:
        if not database_url:
            return None
        return await asyncpg.connect(database_url)

    def _signal(digest: str) -> None:
        for event in app.state.revocation_events.get(digest, ()):
            event.set()

    @app.get("/v1/auth/devices")
    async def devices(request: Request) -> JSONResponse:
        try:
            conn = await _connection()
            if conn is None:
                raise RuntimeError("database unavailable")
            try:
                rows = await conn.fetch(
                    """SELECT id, device_name, last_used_date FROM user_tokens
                       WHERE user_id = $1 AND expires_at > now()
                       ORDER BY created_at, id""",
                    UUID(request.state.user["id"]),
                )
            finally:
                await conn.close()
        except Exception:
            return JSONResponse({"status": "unavailable"}, status_code=503)
        return JSONResponse(
            [{"id": str(row["id"]), "device_name": row["device_name"],
              "last_used_date": row["last_used_date"].isoformat()} for row in rows],
            headers={"Cache-Control": "no-store"},
        )

    # The existing proxy rejects DELETE; keep this route out of the public
    # OpenAPI listing until that separate proxy rollout is authorized.
    @app.delete("/v1/auth/devices/{device_id}", include_in_schema=False)
    async def revoke_device(device_id: str, request: Request) -> JSONResponse:
        not_found = JSONResponse({"status": "not_found"}, status_code=404)
        try:
            target = UUID(device_id)
        except ValueError:
            return not_found
        try:
            conn = await _connection()
            if conn is None:
                raise RuntimeError("database unavailable")
            try:
                digest = await conn.fetchval(
                    """DELETE FROM user_tokens WHERE id = $1 AND user_id = $2
                       RETURNING token_hash""",
                    target, UUID(request.state.user["id"]),
                )
            finally:
                await conn.close()
        except Exception:
            return JSONResponse({"status": "unavailable"}, status_code=503)
        if digest is None:
            return not_found
        _signal(digest)
        return JSONResponse({"status": "revoked"}, headers={"Cache-Control": "no-store"})

    async def _json(request: Request) -> dict | None:
        size = 0
        chunks = []
        async for chunk in request.stream():
            size += len(chunk)
            if size > _MAX_BODY:
                return None
            chunks.append(chunk)
        try:
            body = json.loads(b"".join(chunks))
        except (ValueError, UnicodeDecodeError):
            return None
        return body if isinstance(body, dict) else None

    def _strong(password: str) -> bool:
        if not MIN_PASSWORD <= len(password) <= MAX_PASSWORD:
            return False
        try:
            password.encode("utf-8")
        except UnicodeEncodeError:
            return False
        return True

    @app.post("/v1/auth/claim")
    async def claim(request: Request) -> JSONResponse:
        """FT-856: an invited person makes up their own password and signs this device in."""
        body = await _json(request)
        keys = ("username", "code", "password", "device_name")
        if body is None or any(not isinstance(body.get(key), str) for key in keys):
            return JSONResponse({"status": "invalid_request"}, status_code=400)
        username, code, password, device_name = (body[key] for key in keys)
        device = device_name.strip()
        if not (len(username) <= 128 and len(code) <= 64 and 1 <= len(device) <= 100 and device.isprintable()):
            return JSONResponse({"status": "invalid_request"}, status_code=400)
        if not _strong(password):
            return JSONResponse({"status": "weak_password"}, status_code=422)
        refused = JSONResponse({"status": "invalid_code"}, status_code=401)
        try:
            name = normalize_username(username)
        except ValueError:
            return refused
        if database_url is None:
            return JSONResponse({"status": "unavailable"}, status_code=503)
        try:
            conn = await asyncpg.connect(database_url)
        except Exception:
            return JSONResponse({"status": "unavailable"}, status_code=503)
        try:
            try:
                with login_limits.using(conn):
                    async with login_limits.admit(name, clock):
                        row = await conn.fetchrow(
                            """SELECT u.id, i.code_hash FROM users u
                               JOIN user_invites i ON i.user_id = u.id
                               WHERE u.username = $1 AND u.is_active AND i.expires_at > now()""",
                            name,
                        )
            except login_limits.LoginLimited as exc:
                return JSONResponse(
                    {"status": "too_many_attempts"}, status_code=429,
                    headers={"Retry-After": str(exc.retry_after)},
                )
            if row is None or not secrets.compare_digest(row["code_hash"], invite_digest(code)):
                await login_limits.record_failure(conn, name, clock())
                return refused
            digest = await asyncio.to_thread(PASSWORD_HASHER.hash, password)
            token = secrets.token_urlsafe(32)
            async with conn.transaction():
                taken = await conn.fetchval(
                    "DELETE FROM user_invites WHERE user_id = $1 AND code_hash = $2 RETURNING user_id",
                    row["id"], row["code_hash"],
                )
                if taken is None:
                    return refused
                await conn.execute(
                    "UPDATE users SET password_hash = $2 WHERE id = $1", row["id"], digest
                )
                await conn.execute(
                    """INSERT INTO user_tokens (user_id, token_hash, device_name, last_used_date, expires_at)
                       VALUES ($1, $2, $3, CURRENT_DATE, now() + interval '90 days')""",
                    row["id"], hashlib.sha256(token.encode()).hexdigest(), device,
                )
            await login_limits.reset_failures(conn, name)
            return JSONResponse(
                {"token": token, "user_id": str(row["id"])}, headers={"Cache-Control": "no-store"}
            )
        except Exception:
            return JSONResponse({"status": "unavailable"}, status_code=503)
        finally:
            await conn.close()

    @app.post("/v1/auth/password")
    async def change_password(request: Request) -> JSONResponse:
        """FT-856: a signed-in person changes their own password; other devices sign out."""
        current = getattr(request.state, "bearer_hash", None)
        if current is None:
            return JSONResponse(_UNAUTHORIZED, status_code=401)
        body = await _json(request)
        if body is None or any(
            not isinstance(body.get(key), str) for key in ("old_password", "new_password")
        ):
            return JSONResponse({"status": "invalid_request"}, status_code=400)
        if len(body["old_password"]) > MAX_PASSWORD:
            return JSONResponse({"status": "invalid_request"}, status_code=400)
        if not _strong(body["new_password"]):
            return JSONResponse({"status": "weak_password"}, status_code=422)
        user_id = UUID(request.state.user["id"])
        try:
            conn = await _connection()
            if conn is None:
                raise RuntimeError("database unavailable")
            try:
                stored = await conn.fetchval("SELECT password_hash FROM users WHERE id = $1", user_id)
                if not await asyncio.to_thread(auth_module.verify_password, stored, body["old_password"]):
                    return JSONResponse({"status": "wrong_password"}, status_code=403)
                digest = await asyncio.to_thread(PASSWORD_HASHER.hash, body["new_password"])
                async with conn.transaction():
                    await conn.execute(
                        "UPDATE users SET password_hash = $2 WHERE id = $1", user_id, digest
                    )
                    gone = await conn.fetch(
                        "DELETE FROM user_tokens WHERE user_id = $1 AND token_hash <> $2 RETURNING token_hash",
                        user_id, current,
                    )
            finally:
                await conn.close()
        except Exception:
            return JSONResponse({"status": "unavailable"}, status_code=503)
        for row in gone:
            _signal(row["token_hash"])
        return JSONResponse({"status": "changed"}, headers={"Cache-Control": "no-store"})

    @app.post("/v1/auth/logout")
    async def logout(request: Request) -> JSONResponse:
        digest = getattr(request.state, "bearer_hash", None)
        if digest is None:
            # The legacy key has no device of its own to log out.
            return JSONResponse(_UNAUTHORIZED, status_code=401)
        try:
            conn = await _connection()
            if conn is None:
                raise RuntimeError("database unavailable")
            try:
                await conn.execute(
                    "DELETE FROM user_tokens WHERE token_hash = $1 AND user_id = $2",
                    digest, UUID(request.state.user["id"]),
                )
            finally:
                await conn.close()
        except Exception:
            return JSONResponse({"status": "unavailable"}, status_code=503)
        _signal(digest)
        return JSONResponse({"status": "logged_out"}, headers={"Cache-Control": "no-store"})