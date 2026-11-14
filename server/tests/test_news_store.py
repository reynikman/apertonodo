"""FT-571 (Р-A83): artist subscriptions for news — per user, in backup, toggleable by admin.

Contract enforced by this file (card FT-571):
- tables `news_follows` (user_id, artist_mbid) and `news_channels` (user_id, kind, feed_url, name) —
  unique per (user, artist/URL) pair, both in `PERSONAL` in `scripts/backup.sh`;
- `GET /v1/news` → `{"items": [...]}` (empty list for now);
- `GET /v1/news/follows` → `{"artists": [{"id", "name"}]}`; `POST /v1/news/follows` and
  `POST /v1/news/follows/remove` with `{"artist_id": <mbid>}`; unknown artist — 404;
- `NEWS_ENABLED=0` — every `/v1/news*` returns 200 `{"enabled": false}`;
- log contains no artist name from subscription (Р-A83, `docs/logs.md`).
"""

from __future__ import annotations

import asyncio
import json
import logging
import re
import secrets
import uuid
from pathlib import Path
from typing import Any

import asyncpg
import pytest
from fastapi.testclient import TestClient

from app.main import create_app
from app.migrate import apply
from app.users import create_user

ROOT = Path(__file__).resolve().parents[2]
CATALOG = json.loads((ROOT / "contracts" / "fixtures" / "catalog.json").read_text())["tracks"]
ARTIST = str(uuid.uuid4())
ARTIST_NAME = "Quiet Lighthouse Orchestra"
OTHER = str(uuid.uuid4())


async def _prepare(url: str) -> None:
    await apply(url)
    conn = await asyncpg.connect(url)
    try:
        await conn.execute("TRUNCATE news_follows, news_channels")
        await conn.execute(
            "INSERT INTO mb_artist (mbid, name, sort_name, ended) VALUES ($1, $2, $2, false), ($3, 'Second Artist', 'Second Artist', false)"
            " ON CONFLICT (mbid) DO NOTHING",
            uuid.UUID(ARTIST), ARTIST_NAME, uuid.UUID(OTHER),
        )
    finally:
        await conn.close()


def _app(url: str) -> Any:
    return create_app(database_url=url, catalog=CATALOG)


def _login(url: str) -> dict[str, str]:
    username, password = f"news_{uuid.uuid4().hex}", secrets.token_urlsafe(32)

    async def add() -> None:
        conn = await asyncpg.connect(url)
        try:
            await create_user(conn, username, password)
        finally:
            await conn.close()

    asyncio.run(add())
    answer = TestClient(_app(url)).post(
        "/v1/auth/login", json={"username": username, "password": password, "device_name": "news-test"}
    )
    assert answer.status_code == 200
    return {"Authorization": f"Bearer {answer.json()['token']}"}


@pytest.fixture
def db(postgres_url: str) -> str:
    asyncio.run(_prepare(postgres_url))
    return postgres_url


@pytest.mark.real_auth
def test_follow_is_kept_listed_and_removed_for_its_owner_only(db: str, caplog: pytest.LogCaptureFixture) -> None:
    caplog.set_level(logging.DEBUG)
    me = TestClient(_app(db), headers=_login(db))
    stranger = TestClient(_app(db), headers=_login(db))

    assert me.get("/v1/news").json() == {"items": []}
    assert me.post("/v1/news/follows", json={"artist_id": ARTIST}).status_code == 200
    assert me.post("/v1/news/follows", json={"artist_id": ARTIST}).status_code == 200  # repeat is not a duplicate
    assert me.get("/v1/news/follows").json() == {"artists": [{"id": ARTIST, "name": ARTIST_NAME}]}
    assert stranger.get("/v1/news/follows").json() == {"artists": []}

    assert me.post("/v1/news/follows", json={"artist_id": str(uuid.uuid4())}).status_code == 404

    assert me.post("/v1/news/follows/remove", json={"artist_id": ARTIST}).status_code == 200
    assert me.get("/v1/news/follows").json() == {"artists": []}

    assert ARTIST_NAME not in caplog.text, "artist name from subscription leaked into log"


@pytest.mark.real_auth
def test_admin_switch_turns_every_news_address_off(db: str, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("NEWS_ENABLED", "0")
    client = TestClient(_app(db), headers=_login(db))
    for answer in (
        client.get("/v1/news"),
        client.get("/v1/news/follows"),
        client.post("/v1/news/follows", json={"artist_id": ARTIST}),
        client.post("/v1/news/follows/remove", json={"artist_id": ARTIST}),
    ):
        assert answer.status_code == 200
        assert answer.json() == {"enabled": False}


@pytest.mark.real_auth
def test_news_requires_login(db: str) -> None:
    assert TestClient(_app(db)).get("/v1/news").status_code == 401


async def _columns(url: str, table: str) -> set[str]:
    conn = await asyncpg.connect(url)
    try:
        rows = await conn.fetch("SELECT column_name FROM information_schema.columns WHERE table_name = $1", table)
        return {r["column_name"] for r in rows}
    finally:
        await conn.close()


def test_tables_and_backup(db: str) -> None:
    assert {"user_id", "artist_mbid"} <= asyncio.run(_columns(db, "news_follows"))
    assert {"user_id", "kind", "feed_url", "name"} <= asyncio.run(_columns(db, "news_channels"))
    personal = re.search(r"^PERSONAL='([^']*)'", (ROOT / "scripts" / "backup.sh").read_text(), re.M)
    assert personal and {"news_follows", "news_channels"} <= set(personal.group(1).split())
