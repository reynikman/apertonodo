"""FT-577 (Р-A83): custom link → channel; internal address — refused; at most 50 custom channels.

Contract (card FT-577):
- `POST /v1/news/channels {"link"}` → 200 `{"channel": {"id", "kind", "name", "feed_url"}}`:
  `@channel`, `t.me/channel`, `https://t.me/channel` → `telegram`, `https://t.me/s/channel`;
  `youtube.com/channel/<id>` → `youtube`, `https://www.youtube.com/feeds/videos.xml?channel_id=<id>`;
  `youtube.com/@name` → channel page, ID from it (`/channel/UC…` or `"channelId":"UC…"`);
  any site → `<link rel="alternate" type="application/rss+xml|application/atom+xml" href>` from page,
  otherwise the link itself if it serves RSS/Atom; `kind` = `rss`;
- all requests go through `app.state.news.fetch(url) -> bytes`, which goes through `news_fetch.fetch` with
  `resolve=app.state.news.resolve`; rejection by `news_fetch` → 400 `{"error": "not_public"}`;
- limit `NEWS_MAX_CHANNELS` (default 50): exceeding → 409 `{"error": "too_many"}`;
- `GET /v1/news/channels` → `{"channels": [...]}` — custom only; `POST /v1/news/channels/remove {"id"}`.
"""

from __future__ import annotations

import asyncio
import uuid
from pathlib import Path
from typing import Any

import asyncpg
import pytest
from fastapi.testclient import TestClient
from test_news_rss import _app, _feed, _login, _prepare

FIX = Path(__file__).parent / "fixtures" / "news"
UC = "UCqloTEST000000000000000"
PAGES = {
    "https://t.me/s/qlo_band": (FIX / "telegram_s.html").read_bytes(),
    f"https://www.youtube.com/feeds/videos.xml?channel_id={UC}": (FIX / "youtube_atom.xml").read_bytes(),
    "https://www.youtube.com/@qloband": (
        f'<html><head><link rel="canonical" href="https://www.youtube.com/channel/{UC}"></head>'
        f'<body><script>var d = {{"channelId":"{UC}"}};</script></body></html>'
    ).encode(),
    "https://zine.example.org/": (
        b'<html><head><title>A tiny zine</title>'
        b'<link rel="alternate" type="application/atom+xml" title="Zine" href="/atom"></head><body>hi</body></html>'
    ),
}


async def fake_fetch(url: str) -> bytes:
    if url == "https://zine.example.org/atom":
        return _feed("own_atom.xml")
    if url == "https://plain.example.org/feed":
        return _feed("edition_rss.xml")
    if url in PAGES:
        return PAGES[url]
    raise AssertionError(f"unexpected URL {url}")


def _client(url: str, headers: dict[str, str], fetch: Any = fake_fetch) -> tuple[TestClient, Any]:
    app = _app(url)
    if fetch is not None:
        app.state.news.fetch = fetch
    return TestClient(app, headers=headers), app


@pytest.mark.real_auth
@pytest.mark.parametrize(
    ("link", "kind", "feed_url"),
    [
        ("@qlo_band", "telegram", "https://t.me/s/qlo_band"),
        ("t.me/qlo_band", "telegram", "https://t.me/s/qlo_band"),
        ("https://t.me/qlo_band", "telegram", "https://t.me/s/qlo_band"),
        (f"https://www.youtube.com/channel/{UC}", "youtube", f"https://www.youtube.com/feeds/videos.xml?channel_id={UC}"),
        ("https://www.youtube.com/@qloband", "youtube", f"https://www.youtube.com/feeds/videos.xml?channel_id={UC}"),
        ("https://zine.example.org/", "rss", "https://zine.example.org/atom"),
        ("https://plain.example.org/feed", "rss", "https://plain.example.org/feed"),
    ],
)
def test_link_becomes_channel(postgres_url: str, link: str, kind: str, feed_url: str) -> None:
    asyncio.run(_prepare(postgres_url))
    headers, _ = _login(postgres_url)
    client, _ = _client(postgres_url, headers)
    answer = client.post("/v1/news/channels", json={"link": link})
    assert answer.status_code == 200, answer.text
    channel = answer.json()["channel"]
    assert (channel["kind"], channel["feed_url"]) == (kind, feed_url)
    assert [c["id"] for c in client.get("/v1/news/channels").json()["channels"]] == [channel["id"]]


@pytest.mark.real_auth
@pytest.mark.parametrize("link", ["http://192.168.1.1/", "https://intranet.example.org/feed"])
def test_internal_address_is_refused_before_any_request(postgres_url: str, link: str) -> None:
    asyncio.run(_prepare(postgres_url))
    headers, _ = _login(postgres_url)
    client, app = _client(postgres_url, headers, fetch=None)
    # Name resolves to internal network: check must inspect IP, not name.
    app.state.news.resolve = lambda host: ["10.0.0.7"]
    answer = client.post("/v1/news/channels", json={"link": link})
    assert answer.status_code == 400 and answer.json() == {"error": "not_public"}, answer.text
    assert client.get("/v1/news/channels").json()["channels"] == []


@pytest.mark.real_auth
def test_limit_owner_only_and_remove(postgres_url: str) -> None:
    asyncio.run(_prepare(postgres_url))
    headers, user_id = _login(postgres_url)

    async def fill() -> None:
        conn = await asyncpg.connect(postgres_url)
        try:
            for n in range(50):
                await conn.execute(
                    "INSERT INTO news_channels (user_id, kind, feed_url, name) VALUES ($1, 'rss', $2, 'x')",
                    uuid.UUID(user_id), f"https://filler.example.org/{n}",
                )
        finally:
            await conn.close()

    asyncio.run(fill())
    client, _ = _client(postgres_url, headers)
    answer = client.post("/v1/news/channels", json={"link": "@qlo_band"})
    assert answer.status_code == 409 and answer.json() == {"error": "too_many"}, "51st channel was accepted"

    channels = client.get("/v1/news/channels").json()["channels"]
    assert len(channels) == 50
    stranger, _ = _login(postgres_url)
    other, _ = _client(postgres_url, stranger)
    assert other.get("/v1/news/channels").json()["channels"] == [], "other users' channels are visible"
    other.post("/v1/news/channels/remove", json={"id": channels[0]["id"]})
    assert len(client.get("/v1/news/channels").json()["channels"]) == 50, "another user deleted the channel"
    assert client.post("/v1/news/channels/remove", json={"id": channels[0]["id"]}).status_code == 200
    assert len(client.get("/v1/news/channels").json()["channels"]) == 49
