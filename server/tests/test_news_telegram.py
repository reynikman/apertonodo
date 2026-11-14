"""FT-576 (Р-A83): public Telegram channel in feed; its failure does not break other collection.

Contract (card FT-576):
- `app.news_telegram.parse_channel(raw: bytes) -> list[dict]` — posts from page `https://t.me/s/<channel>`
  with same fields as `news_rss.parse_feed`: `title` (first line of text, up to 120 chars), `text`
  (full plain text, line breaks preserved), `link` (`https://t.me/<channel>/<number>`), `published`,
  `image` (first image of post or None);
- channel `news_channels.kind = 'telegram'` is collected separately by `collect_once`: markup without
  posts yields zero posts and a log line without channel URL, while RSS in same pass is collected.
"""

from __future__ import annotations

import asyncio
import logging
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import asyncpg
import pytest
from fastapi.testclient import TestClient
from test_news_rss import ZINE, _app, _feed, _login, _prepare

from app import news_collect, news_telegram

FIX = Path(__file__).parent / "fixtures" / "news"
TG = "https://t.me/s/qlo_band"
TG_BROKEN = "https://t.me/s/renamed_markup"


def _page() -> bytes:
    fresh = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()
    return (FIX / "telegram_s.html").read_text().replace("{FRESH_ISO}", fresh).encode()


def test_posts_have_full_text_link_and_photo() -> None:
    posts = {p["link"]: p for p in news_telegram.parse_channel(_page())}
    assert set(posts) == {"https://t.me/qlo_band/101", "https://t.me/qlo_band/102"}
    first = posts["https://t.me/qlo_band/101"]
    assert first["text"] == "New single on Friday!\nPre-save & share here."
    assert first["title"] == "New single on Friday!"
    assert first["image"] == "https://cdn4.telesco.pe/file/qlo101.jpg"
    assert first["published"] is not None
    assert posts["https://t.me/qlo_band/102"]["image"] is None


def test_changed_markup_gives_no_posts() -> None:
    assert news_telegram.parse_channel(b"<html><body><div class='new_layout'>hi</div></body></html>") == []


@pytest.mark.real_auth
def test_broken_telegram_does_not_stop_rss(postgres_url: str, caplog: pytest.LogCaptureFixture) -> None:
    caplog.set_level(logging.DEBUG)
    asyncio.run(_prepare(postgres_url))
    headers, user_id = _login(postgres_url)

    async def add() -> None:
        conn = await asyncpg.connect(postgres_url)
        try:
            for kind, url in (("telegram", TG_BROKEN), ("telegram", TG), ("rss", ZINE)):
                await conn.execute(
                    "INSERT INTO news_channels (user_id, kind, feed_url, name) VALUES ($1, $2, $3, 'own')",
                    uuid.UUID(user_id), kind, url,
                )
        finally:
            await conn.close()

    async def fetch(url: str) -> bytes:
        if url == TG:
            return _page()
        if url == TG_BROKEN:
            return b"<html><body><div class='new_layout'>hi</div></body></html>"
        if url == ZINE:
            return _feed("own_atom.xml")
        raise AssertionError(f"unexpected URL {url}")

    asyncio.run(add())
    assert asyncio.run(news_collect.collect_once(postgres_url, fetch=fetch, curated=[])) == 3
    links = {i["link"] for i in TestClient(_app(postgres_url), headers=headers).get("/v1/news").json()["items"]}
    assert links == {"https://t.me/qlo_band/101", "https://t.me/qlo_band/102", "https://zine.example.org/12"}
    assert "renamed_markup" not in caplog.text and "qlo_band" not in caplog.text, "channel URL in log"
