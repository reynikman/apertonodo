"""FT-574 (Р-A83): new release of subscribed artist — feed card, Play for album.

Contract (card FT-574):
- `GET /v1/news` returns cards `{"type": "release", "id", "artist", "title", "album_id",
  "published"}` alongside articles; FT-573 articles have `type` = `"article"`;
- release — MusicBrainz release group from own copy (no network) of subscribed artist, `first_date` <= 30 days old;
- `album_id` — same ID as album on artist page: opens `/v1/albums/{id}`;
- release group with multiple releases — one card;
- old release and release of non-subscribed artist do not enter the feed.
"""

from __future__ import annotations

import asyncio
import json
import secrets
import uuid
from datetime import date, timedelta
from pathlib import Path
from typing import Any

import asyncpg
import pytest
from fastapi.testclient import TestClient

from app import catalog_browse as browse
from app.main import create_app
from app.migrate import apply
from app.users import create_user

ROOT = Path(__file__).resolve().parents[2]
CATALOG = json.loads((ROOT / "contracts" / "fixtures" / "catalog.json").read_text())["tracks"]
FOLLOWED = uuid.uuid4()
STRANGER = uuid.uuid4()
TODAY = date.today()
_medium = 9_574_000


async def _album(conn: asyncpg.Connection, artist: uuid.UUID, title: str, when: date, editions: int = 1) -> uuid.UUID:
    global _medium
    group = uuid.uuid4()
    await conn.execute(
        "INSERT INTO mb_release_group (mbid, artist_mbid, title, primary_type, secondary_types, first_date) "
        "VALUES ($1, $2, $3, 'Album', '{}', $4)",
        group, artist, title, when.isoformat(),
    )
    for _ in range(editions):
        release = uuid.uuid4()
        await conn.execute(
            "INSERT INTO mb_release (mbid, group_mbid, title, status, date) VALUES ($1, $2, $3, 'Official', $4)",
            release, group, title, when.isoformat(),
        )
        _medium += 1
        await conn.execute(
            "INSERT INTO mb_medium (id, release_mbid, position, format) VALUES ($1, $2, 1, 'CD')", _medium, release
        )
        for position in (1, 2):
            rec = uuid.uuid4()
            await conn.execute(
                "INSERT INTO mb_recording (mbid, artist_mbid, title, length_ms) VALUES ($1, $2, $3, 200000)",
                rec, artist, f"{title} {position}",
            )
            await conn.execute(
                "INSERT INTO mb_track (mbid, medium_id, recording_mbid, position, title, length_ms) "
                "VALUES ($1, $2, $3, $4, $5, 200000)",
                uuid.uuid4(), _medium, rec, position, f"{title} {position}",
            )
    return group


async def _prepare(url: str) -> dict[str, uuid.UUID]:
    await apply(url)
    conn = await asyncpg.connect(url)
    try:
        await conn.execute("TRUNCATE news_follows, news_channels, news_items")
        await conn.execute(
            "INSERT INTO mb_artist (mbid, name, sort_name, ended) VALUES"
            " ($1, 'Tidal Choir', 'Tidal Choir', false), ($2, 'Nobody Follows', 'Nobody Follows', false)",
            FOLLOWED, STRANGER,
        )
        return {
            "fresh": await _album(conn, FOLLOWED, "Low Moon", TODAY - timedelta(days=3), editions=2),
            "old": await _album(conn, FOLLOWED, "Old Sun", TODAY - timedelta(days=60)),
            "stranger": await _album(conn, STRANGER, "Not Yours", TODAY - timedelta(days=2)),
        }
    finally:
        await conn.close()


def _app(url: str) -> Any:
    return create_app(database_url=url, catalog=CATALOG)


def _login(url: str) -> dict[str, str]:
    username, password = f"rel_{uuid.uuid4().hex}", secrets.token_urlsafe(32)

    async def add() -> None:
        conn = await asyncpg.connect(url)
        try:
            await create_user(conn, username, password)
        finally:
            await conn.close()

    asyncio.run(add())
    answer = TestClient(_app(url)).post(
        "/v1/auth/login", json={"username": username, "password": password, "device_name": "release-test"}
    )
    assert answer.status_code == 200
    return {"Authorization": f"Bearer {answer.json()['token']}"}


async def _tracks(url: str, group: str) -> int:
    conn = await asyncpg.connect(url)
    try:
        _group, _disc, tracks = await browse.get_album(conn, uuid.UUID(group))
        return len(tracks)
    finally:
        await conn.close()


@pytest.mark.real_auth
def test_fresh_release_of_followed_artist_is_one_card_with_album_id(postgres_url: str) -> None:
    groups = asyncio.run(_prepare(postgres_url))
    client = TestClient(_app(postgres_url), headers=_login(postgres_url))
    assert client.get("/v1/news").json()["items"] == [], "release without subscription is already in the feed"

    assert client.post("/v1/news/follows", json={"artist_id": str(FOLLOWED)}).status_code == 200
    items = client.get("/v1/news").json()["items"]
    releases = [i for i in items if i.get("type") == "release"]
    assert [r["album_id"] for r in releases] == [str(groups["fresh"])], (
        "feed does not contain single fresh release of subscribed artist: old (>30 days), foreign or duplicate releases"
    )
    card = releases[0]
    assert card["artist"] == "Tidal Choir" and card["title"] == "Low Moon"
    assert card["published"] and card["id"]
    assert asyncio.run(_tracks(postgres_url, card["album_id"])) == 2, "album does not open with tracks by album_id"
    assert client.get("/v1/news").json()["items"] == items, "feed changes on repeated request"
