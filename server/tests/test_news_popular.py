"""FT-582 (Р-A83): curated list with toggles and "popular on server" without names.

Contract (card FT-582):
- `GET /v1/news/curated` → `{"channels": [{"id", "name", "lang", "enabled"}]}` — curated list FT-573
  (default file or `NEWS_CHANNELS_FILE`; `collect_once` without `curated` takes the same list),
  all enabled by default; `POST /v1/news/curated {"id", "enabled"}` — toggle for this user;
  disabled channel does not provide news to this user, but does to others;
- `GET /v1/news/channels/popular` → `{"channels": [{"kind", "feed_url", "name", "people"}]}` — custom
  channels added by at least three users; `people` — count; neither names nor user IDs in response.
"""

from __future__ import annotations

import asyncio
import json
import uuid
from pathlib import Path
from typing import Any

import asyncpg
import pytest
from fastapi.testclient import TestClient
from test_news_rss import CURATED, QLO, _app, _login, _prepare, fake_fetch

from app import news_collect


def _client(url: str, headers: dict[str, str]) -> TestClient:
    return TestClient(_app(url), headers=headers)


async def _own(url: str, users: list[str], feed_url: str) -> None:
    conn = await asyncpg.connect(url)
    try:
        for user in users:
            await conn.execute(
                "INSERT INTO news_channels (user_id, kind, feed_url, name) VALUES ($1, 'rss', $2, 'Shared zine')",
                uuid.UUID(user), feed_url,
            )
    finally:
        await conn.close()


@pytest.mark.real_auth
def test_popular_shows_three_people_as_a_number(postgres_url: str) -> None:
    asyncio.run(_prepare(postgres_url))
    people = [_login(postgres_url) for _ in range(5)]
    ids = [user for _, user in people]
    asyncio.run(_own(postgres_url, ids[:3], "https://three.example.org/rss"))
    asyncio.run(_own(postgres_url, ids[3:5], "https://two.example.org/rss"))

    answer = _client(postgres_url, people[0][0]).get("/v1/news/channels/popular")
    assert answer.status_code == 200
    assert answer.json() == {
        "channels": [{"kind": "rss", "feed_url": "https://three.example.org/rss", "name": "Shared zine", "people": 3}]
    }, "channel of two users is visible, or of three is not visible"
    body = answer.text
    for user in ids:
        assert user not in body


@pytest.mark.real_auth
def test_curated_switch_is_per_person(
    postgres_url: str, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    curated = tmp_path / "channels.json"
    curated.write_text(json.dumps(CURATED))
    monkeypatch.setenv("NEWS_CHANNELS_FILE", str(curated))
    asyncio.run(_prepare(postgres_url))
    (mine, _), (theirs, _) = _login(postgres_url), _login(postgres_url)
    me, them = _client(postgres_url, mine), _client(postgres_url, theirs)
    for client in (me, them):
        assert client.post("/v1/news/follows", json={"artist_id": QLO}).status_code == 200

    async def collect() -> None:
        await news_collect.collect_once(postgres_url, fetch=fake_fetch)

    asyncio.run(collect())
    channels: list[dict[str, Any]] = me.get("/v1/news/curated").json()["channels"]
    assert channels and all(c["enabled"] for c in channels)
    loud = next(c for c in channels if c["name"] == "Loud Pages")
    assert me.post("/v1/news/curated", json={"id": loud["id"], "enabled": False}).status_code == 200

    assert not next(c for c in me.get("/v1/news/curated").json()["channels"] if c["id"] == loud["id"])["enabled"]
    assert [i for i in me.get("/v1/news").json()["items"] if i["channel"] == "Loud Pages"] == []
    assert [i for i in them.get("/v1/news").json()["items"] if i["channel"] == "Loud Pages"], (
        "toggle of one user disabled channel for everyone"
    )
    assert json.dumps(them.get("/v1/news/curated").json()).count('"enabled": false') == 0
