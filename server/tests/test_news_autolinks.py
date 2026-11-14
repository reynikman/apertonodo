"""FT-578 (Р-A83): subscription autolinks — YouTube and RSS from artist's relationships.

Contract (card FT-578):
- when subscribing (`POST /v1/news/follows {"artist_id": <mbid>}`) the server finds links in the copy:
  with YouTube channel (`https://www.youtube.com/channel/<UC…>`) —
  a `youtube` channel (`https://www.youtube.com/feeds/videos.xml?channel_id=<UC…>`), with official site —
  an `rss` channel via FT-577 autodetection (via `app.state.news.fetch`); in `GET /v1/news/channels` they have
  `artist` field — artist name (for user's own channels — null); social networks do not become channels;
- an artist without links and a site that failed to open do not break the subscription: response 200.
"""

from __future__ import annotations

import asyncio
import io
import tarfile
import uuid
from pathlib import Path
from typing import Any

import asyncpg
import pytest
from fastapi.testclient import TestClient
from test_mbcopy import METALLICA, _ample_disk_space, _load, db, pack_dump  # noqa: F401  (db, _ample_disk_space — fixtures)
from test_news_rss import _app, _feed, _login, _prepare

from app.mbcopy import format_copy_row

OFFICIAL = "fe33d22f-c3b0-4d68-bd53-a856badf2b15"
YOUTUBE = "6a540e5b-58c6-4192-b6ba-dbc71ec8fcf0"
SOCIAL = "99429741-f3f6-484b-84f8-23af51991770"
DISCOGS = "04a5b104-a4c2-4bac-99a1-7b837c37d9e4"
UC = "UCqloTEST000000000000000"

EXTRA: dict[str, list[dict[str, Any]]] = {
    "link_type": [
        {"id": 10 + n, "child_order": 0, "gid": gid, "entity_type0": "artist", "entity_type1": "url",
         "name": name, "link_phrase": name, "reverse_link_phrase": name, "long_link_phrase": name}
        for n, (gid, name) in enumerate(
            ((OFFICIAL, "official homepage"), (YOUTUBE, "youtube"), (SOCIAL, "social network"), (DISCOGS, "discogs"))
        )
    ],
    "link": [{"id": 10 + n, "link_type": 10 + n, "attribute_count": 0, "ended": False} for n in range(4)],
    "url": [
        {"id": 1, "gid": str(uuid.uuid4()), "url": "https://www.metallica.com/", "edits_pending": 0},
        {"id": 2, "gid": str(uuid.uuid4()), "url": f"https://www.youtube.com/channel/{UC}", "edits_pending": 0},
        {"id": 3, "gid": str(uuid.uuid4()), "url": "https://twitter.com/metallica", "edits_pending": 0},
        {"id": 4, "gid": str(uuid.uuid4()), "url": "https://www.discogs.com/artist/18839", "edits_pending": 0},
    ],
    "l_artist_url": [
        {"id": n, "link": 9 + n, "entity0": 1, "entity1": n, "edits_pending": 0, "link_order": 0,
         "entity0_credit": "", "entity1_credit": ""}
        for n in range(1, 5)
    ],
}


def _with_artist_urls(path: Path) -> None:
    """Regular loader test dump plus four Metallica URL relationships."""
    pack_dump(path)
    members: list[tuple[tarfile.TarInfo, bytes]] = []
    with tarfile.open(path, "r:bz2") as tar:
        for info in tar.getmembers():
            fh = tar.extractfile(info)
            members.append((info, fh.read() if fh else b""))
    seen = {info.name for info, _ in members}
    with tarfile.open(path, "w:bz2") as tar:
        for info, data in members:
            table = info.name.removeprefix("mbdump/")
            if table in EXTRA:
                data += "".join(format_copy_row(table, row) for row in EXTRA[table]).encode()
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
        for table in ("url", "l_artist_url"):
            if f"mbdump/{table}" not in seen:
                data = "".join(format_copy_row(table, row) for row in EXTRA[table]).encode()
                info = tarfile.TarInfo(f"mbdump/{table}")
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))


async def test_loader_keeps_only_official_youtube_and_social(db: str, tmp_path: Path) -> None:  # noqa: F811
    dump = tmp_path / "mbdump.tar.bz2"
    _with_artist_urls(dump)
    await _load(db, files=[str(dump)])
    conn = await asyncpg.connect(db)
    try:
        rows = {(str(r["artist_mbid"]), r["kind"], r["url"]) for r in await conn.fetch("SELECT * FROM mb_artist_url")}
    finally:
        await conn.close()
    assert rows == {
        (METALLICA, "official", "https://www.metallica.com/"),
        (METALLICA, "youtube", f"https://www.youtube.com/channel/{UC}"),
        (METALLICA, "social", "https://twitter.com/metallica"),
    }


LINKED = uuid.uuid4()
BARE = uuid.uuid4()


async def _seed(url: str) -> None:
    await _prepare(url)
    conn = await asyncpg.connect(url)
    try:
        await conn.execute(
            "INSERT INTO mb_artist (mbid, name, sort_name, ended) VALUES ($1, 'Linked Band', 'Linked Band', false),"
            " ($2, 'Bare Band', 'Bare Band', false) ON CONFLICT (mbid) DO NOTHING",
            LINKED, BARE,
        )
        await conn.execute("DELETE FROM mb_artist_url WHERE artist_mbid = $1", LINKED)
        await conn.executemany(
            "INSERT INTO mb_artist_url (artist_mbid, kind, url) VALUES ($1, $2, $3)",
            [
                (LINKED, "youtube", f"https://www.youtube.com/channel/{UC}"),
                (LINKED, "official", "https://linked.example.org/"),
                (LINKED, "social", "https://twitter.com/linked"),
            ],
        )
    finally:
        await conn.close()


@pytest.mark.real_auth
@pytest.mark.parametrize("site_opens", [True, False])
def test_follow_adds_artist_channels(postgres_url: str, site_opens: bool) -> None:
    asyncio.run(_seed(postgres_url))
    headers, _ = _login(postgres_url)
    app = _app(postgres_url)

    async def fetch(url: str) -> bytes:
        if url == "https://linked.example.org/" and site_opens:
            return b'<html><head><link rel="alternate" type="application/rss+xml" href="/rss"></head></html>'
        if url == "https://linked.example.org/rss" and site_opens:
            return _feed("edition_rss.xml")
        raise OSError("failed to open")

    app.state.news.fetch = fetch
    client = TestClient(app, headers=headers)
    assert client.post("/v1/news/follows", json={"artist_id": str(BARE)}).status_code == 200
    assert client.get("/v1/news/channels").json()["channels"] == [], "an artist without links got a channel"

    assert client.post("/v1/news/follows", json={"artist_id": str(LINKED)}).status_code == 200
    channels = {(c["kind"], c["feed_url"], c["artist"]) for c in client.get("/v1/news/channels").json()["channels"]}
    expected = {("youtube", f"https://www.youtube.com/feeds/videos.xml?channel_id={UC}", "Linked Band")}
    if site_opens:
        expected.add(("rss", "https://linked.example.org/rss", "Linked Band"))
    assert channels == expected


@pytest.mark.real_auth
def test_unfollow_removes_artist_channels_and_they_do_not_count(postgres_url: str) -> None:
    """Unsubscribing removes channels brought by the subscription; custom channels limit does not count them."""
    asyncio.run(_seed(postgres_url))
    headers, _ = _login(postgres_url)
    app = _app(postgres_url)

    async def fetch(url: str) -> bytes:
        if url == "https://own.example.org/rss":
            return _feed("edition_rss.xml")
        raise OSError("failed to open")

    app.state.news.fetch = fetch
    app.state.news.max_channels = 1
    client = TestClient(app, headers=headers)
    assert client.post("/v1/news/follows", json={"artist_id": str(LINKED)}).status_code == 200
    assert len(client.get("/v1/news/channels").json()["channels"]) == 1
    added = client.post("/v1/news/channels", json={"link": "https://own.example.org/rss"})
    assert added.status_code == 200, "subscription channel took up a slot of a custom channel"

    assert client.post("/v1/news/follows/remove", json={"artist_id": str(LINKED)}).status_code == 200
    left = [c["feed_url"] for c in client.get("/v1/news/channels").json()["channels"]]
    assert left == ["https://own.example.org/rss"]
