"""FT-580 (Р-A83): empty feed suggestions — artists from user listening history.

Contract (card FT-580):
- `GET /v1/news/suggestions` → `{"source": "history"|"popular", "artists": [{"id", "name"}]}`;
- `history`: artists from `listens` of this user, found in `mb_artist` by case-insensitive name,
  more frequently listened first, at most 10, excluding those already followed; other users' listens
  are not counted;
- no own history — `popular`: popular catalog artists (list may be empty).
"""

from __future__ import annotations

import asyncio
import uuid

import asyncpg
import pytest
from fastapi.testclient import TestClient
from test_news_rss import _app, _login, _prepare

# Constant IDs: repeated run in same DB does not duplicate artists of the same name.
TIDAL = uuid.UUID("5800a0c1-0000-4000-8000-000000000001")
SECOND = uuid.UUID("5800a0c1-0000-4000-8000-000000000002")
FOLLOWED = uuid.UUID("5800a0c1-0000-4000-8000-000000000003")


async def _seed(url: str, me: str, other: str) -> None:
    await _prepare(url)
    conn = await asyncpg.connect(url)
    try:
        await conn.execute(
            "INSERT INTO mb_artist (mbid, name, sort_name, ended) VALUES ($1, 'Tidal Choir Suggest', 'Tidal Choir Suggest', false),"
            " ($2, 'Second Sun', 'Second Sun', false), ($3, 'Already Followed', 'Already Followed', false) ON CONFLICT (mbid) DO NOTHING",
            TIDAL, SECOND, FOLLOWED,
        )
        plays = [(me, "tidal choir suggest")] * 3 + [(me, "Second Sun")] + [(me, "Already Followed")] * 5
        plays += [(me, "Nobody In Catalog")] * 9 + [(other, "Second Sun")] * 20
        await conn.executemany(
            "INSERT INTO listens (canonical_key, track_id, title, artist, duration_ms, user_id)"
            " VALUES ('k', $1, 't', $2, 1000, $3)",
            [(uuid.uuid4(), artist, uuid.UUID(user)) for user, artist in plays],
        )
    finally:
        await conn.close()


@pytest.mark.real_auth
def test_suggestions_come_from_own_history(postgres_url: str) -> None:
    asyncio.run(_prepare(postgres_url))
    headers, me = _login(postgres_url)
    _, other = _login(postgres_url)
    asyncio.run(_seed(postgres_url, me, other))
    client = TestClient(_app(postgres_url), headers=headers)
    assert client.post("/v1/news/follows", json={"artist_id": str(FOLLOWED)}).status_code == 200

    answer = client.get("/v1/news/suggestions").json()
    assert answer["source"] == "history"
    assert answer["artists"] == [
        {"id": str(TIDAL), "name": "Tidal Choir Suggest"},
        {"id": str(SECOND), "name": "Second Sun"},
    ]

    fresh, _ = _login(postgres_url)
    empty = TestClient(_app(postgres_url), headers=fresh).get("/v1/news/suggestions").json()
    assert empty["source"] == "popular" and isinstance(empty["artists"], list)
