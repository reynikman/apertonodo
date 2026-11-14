"""Song cover in "My Music" is the cover of its album (p4-fixes, B: 18, 19, 27).

Owner 02.10: in "Favorite Songs", in "recently played", and in player opened from them, there is a letter instead of a cover.
Reason: covers exist only for albums (`album_images`, key is release group), and a song only knows its cover
if it was started from the album page. In `favorites` there is no cover column at all, in `listens` whatever
the phone sent is recorded — usually empty. The server knows the song's album from the MusicBrainz dump:
recording -> `mb_track` -> `mb_medium` -> `mb_release` -> group; on prod 26 songs take 24 ms via indexes.
"""

from __future__ import annotations

import asyncio
import random
import uuid
from typing import Any

import asyncpg

from tests.test_library import ALBUM_ID, OTHER_ID, _client, db, prepared_db  # noqa: F401

SINGLE = str(uuid.uuid4())  # 2003 single with a cover
ALBUM = str(uuid.uuid4())  # 2004 album with a cover — this is what we expect
BARE = str(uuid.uuid4())  # album whose cover was searched for and not found


async def _seed(url: str) -> None:
    conn = await asyncpg.connect(url)
    try:
        groups = [SINGLE, ALBUM, BARE]
        await conn.execute("DELETE FROM mb_track WHERE recording_mbid = ANY($1::uuid[])", [ALBUM_ID, OTHER_ID])
        await conn.execute(
            "DELETE FROM mb_medium WHERE release_mbid IN (SELECT mbid FROM mb_release WHERE group_mbid = ANY($1::uuid[]))",
            groups,
        )
        await conn.execute("DELETE FROM mb_release WHERE group_mbid = ANY($1::uuid[])", groups)
        await conn.execute("DELETE FROM mb_release_group WHERE mbid = ANY($1::uuid[])", groups)
        await conn.execute("DELETE FROM album_images WHERE album_id = ANY($1::uuid[])", groups)
        artist = await conn.fetchval(
            "INSERT INTO mb_artist (mbid, name, sort_name, ended) VALUES (gen_random_uuid(), 'Cover Test', "
            "'Cover Test', false) RETURNING mbid"
        )
        for group, title, kind, year, rec in (
            (SINGLE, "Paper Lanterns", "Single", "2003", ALBUM_ID),
            (ALBUM, "Lanterns", "Album", "2004", ALBUM_ID),
            (BARE, "Northern", "Album", "2005", OTHER_ID),
        ):
            release, medium = uuid.uuid4(), random.randint(10**8, 2 * 10**9)
            await conn.execute(
                "INSERT INTO mb_release_group (mbid, artist_mbid, title, primary_type, first_date) "
                "VALUES ($1::uuid, $2, $3, $4, $5)",
                group, artist, title, kind, year,
            )
            await conn.execute(
                "INSERT INTO mb_release (mbid, group_mbid, title, status, date) VALUES ($1, $2::uuid, $3, 'Official', $4)",
                release, group, title, year,
            )
            await conn.execute(
                "INSERT INTO mb_medium (id, release_mbid, position, format) VALUES ($1, $2, 1, 'CD')", medium, release
            )
            await conn.execute(
                "INSERT INTO mb_track (mbid, medium_id, recording_mbid, position, title, length_ms) "
                "VALUES (gen_random_uuid(), $1, $2::uuid, 1, $3, 240000)",
                medium, rec, title,
            )
        await conn.execute(
            "INSERT INTO album_images (album_id, path) VALUES ($1::uuid, '/data/covers/single.jpg'), "
            "($2::uuid, '/data/covers/album.jpg'), ($3::uuid, NULL)",
            SINGLE, ALBUM, BARE,
        )
    finally:
        await conn.close()


def _covers(answer: dict[str, Any]) -> dict[str, str]:
    return {track["id"]: track["artwork_url"] for track in answer["tracks"]}


def test_favorites_show_the_album_cover(db: str) -> None:  # noqa: F811
    asyncio.run(_seed(db))
    with _client(db) as client:
        for track_id in (ALBUM_ID, OTHER_ID):
            assert client.post("/v1/favorites", json={"track_id": track_id}).status_code == 200
        covers = _covers(client.get("/v1/favorites").json())
    assert covers == {ALBUM_ID: f"/v1/covers/{ALBUM}", OTHER_ID: ""}


def test_recently_played_shows_the_album_cover(db: str) -> None:  # noqa: F811
    asyncio.run(_seed(db))
    with _client(db) as client:
        assert client.post("/v1/history", json={"track_id": ALBUM_ID, "listened_ms": 60_000}).json()["recorded"]
        covers = _covers(client.get("/v1/history").json())
    assert covers == {ALBUM_ID: f"/v1/covers/{ALBUM}"}


def test_playlist_rows_show_the_album_cover(db: str) -> None:  # noqa: F811
    asyncio.run(_seed(db))
    with _client(db) as client:
        playlist = client.post("/v1/playlists", json={"name": "Обложки"}).json()["id"]
        for track_id in (ALBUM_ID, OTHER_ID):
            assert client.post(f"/v1/playlists/{playlist}/tracks", json={"track_id": track_id}).status_code == 200
        covers = _covers(client.get(f"/v1/playlists/{playlist}").json())
    assert covers == {ALBUM_ID: f"/v1/covers/{ALBUM}", OTHER_ID: ""}


def test_cover_sent_by_the_phone_wins(db: str) -> None:  # noqa: F811
    """Song was started from the single page — phone sent its cover, and that cover stays."""
    asyncio.run(_seed(db))
    with _client(db) as client:
        assert client.post(
            "/v1/history",
            json={"track_id": ALBUM_ID, "listened_ms": 60_000, "artwork_url": f"/v1/covers/{SINGLE}"},
        ).json()["recorded"]
        covers = _covers(client.get("/v1/history").json())
    assert covers == {ALBUM_ID: f"/v1/covers/{SINGLE}"}
