from __future__ import annotations

import asyncio
import hashlib
import secrets
import time
from uuid import uuid4

import asyncpg
import httpx
import pytest
from fastapi.responses import Response

from app.main import RevocableResponse, create_app
from app.media import StreamAborted
from app.migrate import apply
from app.users import create_user


@pytest.mark.real_auth
async def test_devices_are_private_and_revocation_is_per_device(postgres_url: str) -> None:
    await apply(postgres_url)
    names = ["device_" + secrets.token_hex(8) for _ in range(3)]
    users = ["user_" + secrets.token_hex(8) for _ in range(2)]
    passwords = [secrets.token_urlsafe(32) for _ in users]
    conn = await asyncpg.connect(postgres_url)
    try:
        for name, password in zip(users, passwords, strict=True):
            await create_user(conn, name, password)
    finally:
        await conn.close()

    app = create_app(database_url=postgres_url, catalog=[], api_key=None)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
        async def login(index: int, device: str) -> dict[str, str]:
            result = await client.post("/v1/auth/login", json={
                "username": users[index], "password": passwords[index], "device_name": device,
            })
            assert result.status_code == 200
            return {"Authorization": "Bearer " + result.json()["token"]}

        first = await login(0, names[0])
        second = await login(0, names[1])
        foreign = await login(1, names[2])
        own_devices = (await client.get("/v1/auth/devices", headers=first)).json()
        foreign_devices = (await client.get("/v1/auth/devices", headers=foreign)).json()
        assert {d["device_name"] for d in own_devices} == set(names[:2])
        assert {d["device_name"] for d in foreign_devices} == {names[2]}
        assert all(set(d) == {"id", "device_name", "last_used_date"} for d in own_devices + foreign_devices)
        first_id = next(d["id"] for d in own_devices if d["device_name"] == names[0])
        refused = await client.delete("/v1/auth/devices/" + first_id, headers=foreign)
        unknown = await client.delete("/v1/auth/devices/" + str(uuid4()), headers=foreign)
        assert (refused.status_code, refused.content) == (unknown.status_code, unknown.content)
        assert refused.status_code == 404
        assert (await client.delete("/v1/auth/devices/" + first_id, headers=second)).status_code == 200
        assert (await client.get("/v1/auth/devices", headers=first)).status_code == 401
        assert len((await client.get("/v1/auth/devices", headers=second)).json()) == 1
        assert (await client.post("/v1/auth/logout", headers=second)).status_code == 200
        assert (await client.get("/v1/auth/devices", headers=second)).status_code == 401
        assert (await client.get("/v1/auth/devices", headers=foreign)).status_code == 200


class IdleResponse(Response):
    async def __call__(self, scope, receive, send) -> None:
        await send({"type": "http.response.start", "status": 200, "headers": []})
        await asyncio.sleep(20)
        await send({"type": "http.response.body", "body": secrets.token_bytes(8)})


@pytest.mark.parametrize("mode", ["local", "removed", "failed"])
async def test_idle_stream_stops_on_signal_or_recheck(monkeypatch, mode: str) -> None:
    digest = hashlib.sha256(secrets.token_bytes(32)).hexdigest()
    events: dict[str, set[asyncio.Event]] = {}
    response = RevocableResponse(IdleResponse(), "unused", digest, str(uuid4()), events)
    messages = []

    async def send(message):
        messages.append(message)

    if mode == "removed":
        class Gone:
            async def fetchval(self, *args):
                return None

            async def close(self):
                pass

        async def connect(*args, **kwargs):
            return Gone()

        monkeypatch.setattr(asyncpg, "connect", connect)
    elif mode == "failed":
        async def unavailable(*args, **kwargs):
            raise ConnectionError
        monkeypatch.setattr(asyncpg, "connect", unavailable)
    began = time.monotonic()
    task = asyncio.create_task(response({"type": "http"}, None, send))
    await asyncio.sleep(0.05)
    if mode == "local":
        next(iter(events[digest])).set()
    with pytest.raises(StreamAborted):
        await asyncio.wait_for(task, timeout=5)
    assert time.monotonic() - began < 5
    assert digest not in events
    assert not any(message.get("body") for message in messages)
