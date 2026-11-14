from __future__ import annotations

import secrets

import asyncpg
import httpx
import pytest
from fastapi import Request

from app.main import create_app
from app.migrate import apply
from app.users import create_user, ensure_owner_id


@pytest.mark.real_auth
async def test_bearer_only_returns_200_on_library_route(postgres_url: str) -> None:
    await apply(postgres_url)
    api_key = secrets.token_urlsafe(32)
    username = "user_" + secrets.token_hex(8)
    password = secrets.token_urlsafe(24)

    conn = await asyncpg.connect(postgres_url)
    try:
        await create_user(conn, username, password)
    finally:
        await conn.close()

    app = create_app(database_url=postgres_url, catalog=[], api_key=api_key)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
        login_resp = await client.post(
            "/v1/auth/login",
            json={"username": username, "password": password, "device_name": "test-device"},
        )
        # Without x-apertonodo-key, how the app logs in: it has no shared key.
        assert login_resp.status_code == 200
        token = login_resp.json()["token"]

        # 1. Bearer only (NO x-apertonodo-key) -> 200
        resp = await client.get("/v1/favorites", headers={"Authorization": f"Bearer {token}"})
        assert resp.status_code == 200

        # 2. Bearer AND wrong key -> judged by bearer alone -> 200
        wrong_key = secrets.token_urlsafe(32)
        resp_wrong = await client.get(
            "/v1/favorites",
            headers={"Authorization": f"Bearer {token}", "x-apertonodo-key": wrong_key},
        )
        assert resp_wrong.status_code == 200


@pytest.mark.real_auth
async def test_no_bearer_no_key_returns_401(postgres_url: str) -> None:
    await apply(postgres_url)
    api_key = secrets.token_urlsafe(32)
    app = create_app(database_url=postgres_url, catalog=[], api_key=api_key)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
        resp = await client.get("/v1/favorites")
        assert resp.status_code == 401
        assert resp.json() == {"status": "unauthorized"}


@pytest.mark.real_auth
async def test_invalid_bearer_no_key_returns_401(postgres_url: str) -> None:
    await apply(postgres_url)
    api_key = secrets.token_urlsafe(32)
    app = create_app(database_url=postgres_url, catalog=[], api_key=api_key)
    fake_token = secrets.token_urlsafe(32)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
        resp = await client.get("/v1/favorites", headers={"Authorization": f"Bearer {fake_token}"})
        assert resp.status_code == 401
        assert resp.json() == {"status": "unauthorized"}


@pytest.mark.real_auth
async def test_key_only_still_the_owner(postgres_url: str) -> None:
    await apply(postgres_url)
    api_key = secrets.token_urlsafe(32)

    conn = await asyncpg.connect(postgres_url)
    try:
        owner_id = await ensure_owner_id(conn)
    finally:
        await conn.close()

    app = create_app(database_url=postgres_url, catalog=[], api_key=api_key)

    @app.get("/v1/_whoami")
    async def whoami(request: Request) -> dict[str, object]:
        return request.state.user

    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
        # Key only -> 200 on library route
        resp_fav = await client.get("/v1/favorites", headers={"x-apertonodo-key": api_key})
        assert resp_fav.status_code == 200

        # Key only -> resolves as owner with is_admin=False
        resp_who = await client.get("/v1/_whoami", headers={"x-apertonodo-key": api_key})
        assert resp_who.status_code == 200
        user = resp_who.json()
        assert user["id"] == str(owner_id)
        assert user["is_admin"] is False
