"""FT-575 (Р-A83): YouTube channel in feed — title, full description, preview, video link.

Contract (card FT-575):
- `app.news_rss.parse_feed` parses feed `https://www.youtube.com/feeds/videos.xml?channel_id=…`:
  `text` — full `media:description`, `image` — `media:thumbnail`, `link` — link to video;
- channel `news_channels.kind = 'youtube'` is collected by `collect_once` with same `fetch` as RSS, and its videos
  reach user feed, just like everything from their custom channels.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
import asyncio
import uuid
from pathlib import Path

import asyncpg
import pytest
from fastapi.testclient import TestClient
from test_news_rss import _app, _login, _prepare

from app import news_collect, news_rss

FIX = Path(__file__).parent / "fixtures" / "news"


def _feed() -> bytes:
    fresh = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()
    return (FIX / "youtube_atom.xml").read_text().replace("{FRESH_ISO}", fresh).encode()


def test_youtube_entry_has_full_description_thumbnail_and_video_link() -> None:
    [video] = news_rss.parse_feed(_feed())
    assert video["title"] == "Winter tour — rehearsal diary"
    assert video["link"] == "https://www.youtube.com/watch?v=abcDEF12345"
    assert video["image"] == "https://i1.ytimg.com/vi/abcDEF12345/hqdefault.jpg"
    assert video["text"] == "Twelve cities, one van.\nFull setlist in the comments & more."
    assert video["published"] is not None


YT = "https://www.youtube.com/feeds/videos.xml?channel_id=UCqloTEST000000000000000"


@pytest.mark.real_auth
def test_own_youtube_channel_reaches_the_feed(postgres_url: str) -> None:
    asyncio.run(_prepare(postgres_url))
    headers, user_id = _login(postgres_url)

    async def add() -> None:
        conn = await asyncpg.connect(postgres_url)
        try:
            await conn.execute(
                "INSERT INTO news_channels (user_id, kind, feed_url, name) VALUES ($1, 'youtube', $2, 'QLO')",
                uuid.UUID(user_id), YT,
            )
        finally:
            await conn.close()

    async def fetch(url: str) -> bytes:
        assert url == YT, f"unexpected URL {url}"
        return _feed()

    asyncio.run(add())
    assert asyncio.run(news_collect.collect_once(postgres_url, fetch=fetch, curated=[])) == 1
    [item] = TestClient(_app(postgres_url), headers=headers).get("/v1/news").json()["items"]
    assert item["link"] == "https://www.youtube.com/watch?v=abcDEF12345"
    assert item["image"] == f"/v1/photos/news/{item['id']}"
    assert "Full setlist" in item["text"]
