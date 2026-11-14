from __future__ import annotations

import json
import secrets
from pathlib import Path

import asyncpg
import httpx
import pytest

from app.main import create_app
from app.migrate import apply
from app.users import create_user

CONTRACTS = Path(__file__).resolve().parents[2] / "contracts"


@pytest.mark.real_auth
async def test_login_speaks_the_contract_the_app_reads(postgres_url: str) -> None:
    """The P3 app and server were written separately: the app did not send device_name and
    expected user_id, while the server required the former and did not return the latter. Login from phone
    answered 400. Now both sides check against the same contract file."""
    await apply(postgres_url)
    request = json.loads((CONTRACTS / "auth-login.request.json").read_text())
    response = json.loads((CONTRACTS / "auth-login.response.json").read_text())
    username = "user_" + secrets.token_hex(8)
    password = secrets.token_urlsafe(24)
    conn = await asyncpg.connect(postgres_url)
    try:
        user_id = await create_user(conn, username, password)
    finally:
        await conn.close()

    app = create_app(database_url=postgres_url, catalog=[], api_key=secrets.token_urlsafe(32))
    body = {**request, "username": username, "password": password, "device_name": "contract"}
    assert set(body) == set(request)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
        resp = await client.post("/v1/auth/login", json=body)
    assert resp.status_code == 200, resp.text
    assert set(resp.json()) == set(response)
    assert resp.json()["user_id"] == str(user_id)
