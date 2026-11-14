from __future__ import annotations

import asyncio
import secrets
from typing import Any

import asyncpg
import httpx
import pytest
from fastapi import Request

from app.main import create_app
from app.users import ensure_owner_id, main as users_cli_main


@pytest.mark.real_auth
@pytest.mark.asyncio
# New header and the old one (old name, accepted until clients are moved).
@pytest.mark.parametrize("header", ["x-apertonodo-key", "x-flowtune-key"])
async def test_legacy_key_authorizes_as_owner_non_admin(postgres_url: str, header: str) -> None:
    key = secrets.token_urlsafe(32)
    conn = await asyncpg.connect(postgres_url)
    try:
        owner_id = await ensure_owner_id(conn)
        await conn.execute("UPDATE users SET is_admin = true WHERE id = $1", owner_id)
    finally:
        await conn.close()

    app = create_app(database_url=postgres_url, api_key=key)

    def whoami(request: Request) -> dict[str, Any]:
        return request.state.user

    app.add_api_route("/v1/_whoami", whoami, methods=["GET"])

    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
        resp = await client.get("/v1/_whoami", headers={header: key})
        assert resp.status_code == 200
        user = resp.json()
        assert user["id"] == str(owner_id)
        assert user["is_admin"] is False

        wrong_key = secrets.token_urlsafe(32)
        assert (await client.get("/v1/_whoami")).status_code == 401

        resp_wrong = await client.get("/v1/_whoami", headers={header: wrong_key})
        assert resp_wrong.status_code == 401

        resp_bad_bearer = await client.get(
            "/v1/_whoami",
            headers={header: key, "Authorization": f"Bearer {secrets.token_urlsafe(32)}"},
        )
        assert resp_bad_bearer.status_code == 401

        resp_admin = await client.post("/v1/admin/api-keys", headers={header: key}, json={})
        assert resp_admin.status_code in (401, 403, 404)

        resp_health = await client.get("/v1/health")
        assert resp_health.status_code == 200
        assert resp_health.json() == {"status": "ok"}


@pytest.mark.real_auth
@pytest.mark.asyncio
async def test_legacy_key_denied_after_cli_deactivates_owner(
    postgres_url: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    key = secrets.token_urlsafe(32)
    conn = await asyncpg.connect(postgres_url)
    try:
        owner_id = await ensure_owner_id(conn)
        await conn.execute("UPDATE users SET is_admin = true, is_active = true WHERE id = $1", owner_id)
    finally:
        await conn.close()

    app = create_app(database_url=postgres_url, api_key=key)

    def whoami(request: Request) -> dict[str, Any]:
        return request.state.user

    app.add_api_route("/v1/_whoami", whoami, methods=["GET"])
    monkeypatch.setenv("DATABASE_URL", postgres_url)

    try:
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
            resp_before = await client.get("/v1/_whoami", headers={"x-apertonodo-key": key})
            assert resp_before.status_code == 200
            assert resp_before.json() == {"id": str(owner_id), "is_admin": False}

            await asyncio.to_thread(users_cli_main, ["deactivate", "owner"])

            resp_after = await client.get("/v1/_whoami", headers={"x-apertonodo-key": key})
            assert resp_after.status_code == 401
    finally:
        conn = await asyncpg.connect(postgres_url)
        try:
            await conn.execute("UPDATE users SET is_active = true WHERE id = $1", owner_id)
        finally:
            await conn.close()


@pytest.mark.real_auth
@pytest.mark.asyncio
async def test_legacy_key_does_not_reactivate_disabled_owner(postgres_url: str) -> None:
    key = secrets.token_urlsafe(32)
    conn = await asyncpg.connect(postgres_url)
    try:
        owner_id = await ensure_owner_id(conn)
        await conn.execute("UPDATE users SET is_active = false WHERE id = $1", owner_id)
    finally:
        await conn.close()

    app = create_app(database_url=postgres_url, api_key=key)

    def whoami(request: Request) -> dict[str, Any]:
        return request.state.user

    app.add_api_route("/v1/_whoami", whoami, methods=["GET"])

    try:
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
            resp = await client.get("/v1/_whoami", headers={"x-apertonodo-key": key})
            assert resp.status_code == 401

        conn = await asyncpg.connect(postgres_url)
        try:
            owner = await conn.fetchrow("SELECT id, is_active FROM users WHERE username = 'owner'")
        finally:
            await conn.close()
        assert owner is not None
        assert owner["id"] == owner_id
        assert owner["is_active"] is False
    finally:
        conn = await asyncpg.connect(postgres_url)
        try:
            await conn.execute("UPDATE users SET is_active = true WHERE id = $1", owner_id)
        finally:
            await conn.close()


@pytest.mark.real_auth
@pytest.mark.asyncio
async def test_legacy_key_switched_off_when_no_api_key(postgres_url: str) -> None:
    key = secrets.token_urlsafe(32)
    app = create_app(database_url=postgres_url, api_key=None)

    def whoami(request: Request) -> dict[str, Any]:
        return request.state.user

    app.add_api_route("/v1/_whoami", whoami, methods=["GET"])

    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
        resp = await client.get("/v1/_whoami", headers={"x-apertonodo-key": key})
        assert resp.status_code == 401

        resp_health = await client.get("/v1/health")
        assert resp_health.status_code == 200
        assert resp_health.json() == {"status": "ok"}


def test_cli_add_argument_refused() -> None:
    pw_arg = secrets.token_urlsafe(16)
    with pytest.raises(SystemExit) as exc:
        users_cli_main(["add", "testuser", pw_arg])
    assert exc.value.code != 0


@pytest.mark.real_auth
@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("both", "expected"),
    [
        ([("x-apertonodo-key", "K"), ("x-flowtune-key", "K")], 200),
        ([("x-apertonodo-key", "K"), ("x-flowtune-key", "bad")], 401),
        ([("x-apertonodo-key", "bad"), ("x-flowtune-key", "K")], 401),
        ([("x-apertonodo-key", "K"), ("x-apertonodo-key", "K")], 401),
        ([("x-flowtune-key", "K"), ("x-flowtune-key", "K")], 401),
    ],
)
async def test_both_key_headers_must_agree(postgres_url: str, both: list[tuple[str, str]], expected: int) -> None:
    key = secrets.token_urlsafe(32)
    conn = await asyncpg.connect(postgres_url)
    try:
        await ensure_owner_id(conn)
    finally:
        await conn.close()
    app = create_app(database_url=postgres_url, api_key=key)
    app.add_api_route("/v1/_whoami", lambda: {"ok": True}, methods=["GET"])
    headers = [(n, key if v == "K" else "bad" * 12) for n, v in both]
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
        assert (await client.get("/v1/_whoami", headers=headers)).status_code == expected
