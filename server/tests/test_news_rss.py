"""FT-573 (Р-A83): news from RSS and Atom — in user's feed, complete, without others' or old items.

Contract (card FT-573):
- `app.news_rss.parse_feed(raw: bytes) -> list[dict]`: `title`, `text` (clean text without HTML, up to 4000
  chars), `link`, `published` (timezone-aware datetime or None), `image` (first image URL or None);
  RSS 2.0 and Atom;
- `app.news_collect.collect_once(database_url, *, fetch, curated) -> int` — single collection pass:
  channels from `curated` list (`[{"name", "feed_url", "lang"}]`) and user custom channels (`news_channels`);
  `fetch(url) -> bytes` — async, on production this is `news_fetch.fetch`; returns number of new items;
  broken channel does not crash others; repeated link is not a duplicate;
- `app.news_collect.purge_news(database_url, *, now) -> int` — deletes news older than 14 days;
- `GET /v1/news` → `{"items": [{"id", "channel", "title", "text", "link", "image", "published", "artist"}]}`,
  newest first, up to 50: from curated list — only about subscribed artist (whole word, case-insensitive;
  `artist` — their name), from user's custom channels — all (`artist` — null);
- `image` — `/v1/photos/news/{id}` or null; `GET /v1/photos/news/{id}` serves image downloaded by server
  via `app.state.news.fetch`; unknown id — 404;
- log contains no titles, channel URLs, or artist names.
"""

from __future__ import annotations

import asyncio
import json
import logging
import secrets
import uuid
from datetime import datetime, timedelta, timezone
from email.utils import format_datetime
from pathlib import Path
from typing import Any

import asyncpg
import pytest
from fastapi.testclient import TestClient

from app import news_collect, news_rss
from app.main import create_app
from app.migrate import apply
from app.users import create_user

ROOT = Path(__file__).resolve().parents[2]
FIX = Path(__file__).parent / "fixtures" / "news"
CATALOG = json.loads((ROOT / "contracts" / "fixtures" / "catalog.json").read_text())["tracks"]
NOW = datetime.now(timezone.utc)
EDITION = "https://loudpages.example.org/rss"
ZINE = "https://zine.example.org/atom"
BROKEN = "https://broken.example.org/rss"
CURATED = [
    {"name": "Loud Pages", "feed_url": EDITION, "lang": "en"},
    {"name": "Broken", "feed_url": BROKEN, "lang": "en"},
]
QLO = str(uuid.uuid4())
MUSE = str(uuid.uuid4())
PNG = b"\x89PNG\r\n\x1a\n" + b"0" * 32


def _feed(name: str) -> bytes:
    text = (FIX / name).read_text()
    return (
        text.replace("{FRESH}", format_datetime(NOW - timedelta(hours=2)))
        .replace("{OLD}", format_datetime(NOW - timedelta(days=20)))
        .replace("{FRESH_ISO}", (NOW - timedelta(hours=1)).isoformat())
        .encode()
    )


async def fake_fetch(url: str) -> bytes:
    if url == EDITION:
        return _feed("edition_rss.xml")
    if url == ZINE:
        return _feed("own_atom.xml")
    if url == BROKEN:
        return b"<html>not a feed"
    raise AssertionError(f"unexpected URL {url}")


def test_rss_item_is_plain_full_text_with_image() -> None:
    items = news_rss.parse_feed(_feed("edition_rss.xml"))
    first = next(i for i in items if i["link"].endswith("qlo-tour"))
    assert first["title"] == "Quiet Lighthouse Orchestra announce a winter tour"
    assert "<" not in first["text"] and "&amp;" not in first["text"]
    assert "twelve cities" in first["text"] and "Tickets go on sale Friday & sell fast." in first["text"]
    assert first["image"] == "https://cdn.loudpages.example.org/qlo.jpg"
    assert first["published"] is not None and first["published"].tzinfo is not None
    muse = next(i for i in items if i["link"].endswith("/muse"))
    assert muse["image"] == "https://cdn.loudpages.example.org/muse.png"


def test_atom_item_and_image_from_content() -> None:
    [item] = news_rss.parse_feed(_feed("own_atom.xml"))
    assert item["link"] == "https://zine.example.org/12"
    assert item["text"] == "Long read about tape loops."
    assert item["image"] == "https://zine.example.org/cover12.jpg"


def test_text_is_capped() -> None:
    raw = f"<rss><channel><item><title>t</title><link>https://x.example.org/1</link><description>{'a' * 9000}</description></item></channel></rss>"
    [item] = news_rss.parse_feed(raw.encode())
    assert len(item["text"]) <= 4000


async def _prepare(url: str) -> None:
    await apply(url)
    conn = await asyncpg.connect(url)
    try:
        await conn.execute("TRUNCATE news_follows, news_channels, news_items")
        await conn.execute(
            "INSERT INTO mb_artist (mbid, name, sort_name, ended) VALUES"
            " ($1, 'Quiet Lighthouse Orchestra', 'Quiet Lighthouse Orchestra', false), ($2, 'Muse', 'Muse', false)"
            " ON CONFLICT (mbid) DO NOTHING",
            uuid.UUID(QLO), uuid.UUID(MUSE),
        )
    finally:
        await conn.close()


def _app(url: str) -> Any:
    return create_app(database_url=url, catalog=CATALOG)


def _login(url: str) -> tuple[dict[str, str], str]:
    username, password = f"rss_{uuid.uuid4().hex}", secrets.token_urlsafe(32)

    async def add() -> str:
        conn = await asyncpg.connect(url)
        try:
            await create_user(conn, username, password)
            return str(await conn.fetchval("SELECT id FROM users WHERE username = $1", username))
        finally:
            await conn.close()

    user_id = asyncio.run(add())
    answer = TestClient(_app(url)).post(
        "/v1/auth/login", json={"username": username, "password": password, "device_name": "rss-test"}
    )
    assert answer.status_code == 200
    return {"Authorization": f"Bearer {answer.json()['token']}"}, user_id


async def _own_channel(url: str, user_id: str) -> None:
    conn = await asyncpg.connect(url)
    try:
        await conn.execute(
            "INSERT INTO news_channels (user_id, kind, feed_url, name) VALUES ($1, 'rss', $2, 'A tiny zine')",
            uuid.UUID(user_id), ZINE,
        )
    finally:
        await conn.close()


async def _count(url: str) -> int:
    conn = await asyncpg.connect(url)
    try:
        return int(await conn.fetchval("SELECT count(*) FROM news_items"))
    finally:
        await conn.close()


@pytest.mark.real_auth
def test_feed_shows_followed_artist_and_own_channels_only(postgres_url: str, caplog: pytest.LogCaptureFixture) -> None:
    caplog.set_level(logging.DEBUG)
    asyncio.run(_prepare(postgres_url))
    headers, user_id = _login(postgres_url)
    asyncio.run(_own_channel(postgres_url, user_id))
    app = _app(postgres_url)
    client = TestClient(app, headers=headers)
    assert client.post("/v1/news/follows", json={"artist_id": QLO}).status_code == 200
    assert client.post("/v1/news/follows", json={"artist_id": MUSE}).status_code == 200

    # Broken channel in the list does not break collection of the rest.
    fresh = asyncio.run(news_collect.collect_once(postgres_url, fetch=fake_fetch, curated=CURATED))
    assert fresh >= 5
    assert asyncio.run(news_collect.collect_once(postgres_url, fetch=fake_fetch, curated=CURATED)) == 0
    assert asyncio.run(_count(postgres_url)) == fresh, "repeated link multiplied rows"

    asyncio.run(news_collect.purge_news(postgres_url, now=NOW))
    items = client.get("/v1/news").json()["items"]
    by_link = {i["link"]: i for i in items}
    assert set(by_link) == {
        "https://loudpages.example.org/news/qlo-tour",   # subscribed artist in title
        "https://loudpages.example.org/news/muse",       # "Muse" as whole word
        "https://zine.example.org/12",                   # custom channel — all
    }, "extra: 'museum' caught as Muse, foreign artist, or old news (>14 days)"
    assert by_link["https://loudpages.example.org/news/qlo-tour"]["artist"] == "Quiet Lighthouse Orchestra"
    assert by_link["https://zine.example.org/12"]["artist"] is None
    assert [i["published"] for i in items] == sorted((i["published"] for i in items), reverse=True)
    tour = by_link["https://loudpages.example.org/news/qlo-tour"]
    assert tour["channel"] == "Loud Pages" and "twelve cities" in tour["text"]
    assert tour["image"] == f"/v1/photos/news/{tour['id']}"
    # Contract contracts/news.response.json: id is a string. Number broke parsing in
    # the app, and the News tab displayed 'Server did not respond' (FT-701).
    assert all(isinstance(i["id"], str) for i in items), [type(i["id"]).__name__ for i in items]

    async def fake_image(url: str) -> bytes:
        assert url == "https://cdn.loudpages.example.org/qlo.jpg"
        return PNG

    app.state.news.fetch = fake_image
    picture = client.get(tour["image"])
    assert picture.status_code == 200 and picture.content == PNG
    assert picture.headers["content-type"].startswith("image/")
    assert client.get("/v1/photos/news/999999999").status_code == 404

    stranger, _ = _login(postgres_url)
    assert TestClient(_app(postgres_url), headers=stranger).get("/v1/news").json() == {"items": []}

    for secret in ("Quiet Lighthouse Orchestra", "winter tour", "loudpages.example.org", "zine.example.org"):
        assert secret not in caplog.text, f"in log: {secret}"
