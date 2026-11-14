"""FT-539: top track with guest in title gets an id and plays.

Last.fm includes the guest in the title — "Unholy (feat. Kim Petras)", "Dancing with a
Stranger (with Normani)", while MusicBrainz keeps them in artist credits, and the recording
is called simply "Unholy". The ID was not found, and clicking in "Popular"
for Sam Smith opened search instead of the track (owner finding on 03.10).
"""

from __future__ import annotations

import json

import asyncpg
import pytest

import app.local_search as local_search
from app import lastfm
from app.names import norm
from app.migrate import apply

LOADED = (
    "INSERT INTO mb_loads (dump_date, replication_sequence, row_counts, duration_ms, tablespace, size_bytes) "
    "VALUES ('2026-09-19', 189107, '{}'::jsonb, 100, 'pg_default', 1000)"
)


@pytest.fixture(autouse=True)
async def cleanup_db(postgres_url: str):
    await apply(postgres_url)
    for i in range(2):
        conn = await asyncpg.connect(postgres_url)
        try:
            await conn.execute("TRUNCATE mb_loads, song, mb_artist, lastfm_artists, catalog_artists CASCADE")
        finally:
            await conn.close()
        if i == 0:
            yield


async def _seed(conn: asyncpg.Connection, artist: str, titles: list[str]) -> dict[str, str]:
    art = await conn.fetchval(
        "INSERT INTO mb_artist (mbid, name, sort_name, ended) VALUES (gen_random_uuid(), $1, $1, false) RETURNING mbid",
        artist,
    )
    ids = {}
    for title in titles:
        rec = await conn.fetchval(
            "INSERT INTO mb_recording (mbid, artist_mbid, title, length_ms) VALUES (gen_random_uuid(), $1, $2, 200000) RETURNING mbid",
            art, title,
        )
        song = await conn.fetchval(
            "INSERT INTO song (artist_mbid, title, original_recording_mbid) VALUES ($1, $2, $3) RETURNING id",
            art, title, rec,
        )
        await conn.execute(
            "INSERT INTO song_version (song_id, recording_mbid, kind, year) VALUES ($1, $2, 'original', 2022)",
            song, rec,
        )
        ids[title] = str(rec)
    return ids


async def test_guest_in_title_finds_the_song(postgres_url: str) -> None:
    conn = await asyncpg.connect(postgres_url)
    try:
        ids = await _seed(conn, "Sam Smith", ["Unholy", "Dancing With a Stranger", "Stay With Me"])
        top = ["Unholy (feat. Kim Petras)", "Dancing with a Stranger (with Normani)", "Stay with Me"]
        found = await local_search.top_track_ids(conn, "Sam Smith", top)
        # Key is the title as displayed by the page (from Last.fm): via this key
        # `lastfm.blocks` retrieves the id.
        assert found.get(norm(top[0]), {}).get("id") == ids["Unholy"], "\"(feat. ...)\" was not stripped"
        assert found.get(norm(top[1]), {}).get("id") == ids["Dancing With a Stranger"], "\"(with ...)\" was not stripped"
        assert found.get(norm(top[2]), {}).get("id") == ids["Stay With Me"]
    finally:
        await conn.close()


async def test_version_in_brackets_is_another_recording(postgres_url: str) -> None:
    # Remix, Live, Acoustic — different recording: they must not be replaced by the original.
    conn = await asyncpg.connect(postgres_url)
    try:
        await _seed(conn, "Sam Smith", ["Unholy"])
        found = await local_search.top_track_ids(conn, "Sam Smith", ["Unholy (Acoustic)", "Unholy (Nova Twins remix)"])
        assert found == {}
    finally:
        await conn.close()


async def test_artist_page_gives_number_to_top_saved_before(postgres_url: str) -> None:
    # On prod Sam Smith top is already saved under old rule without id for
    # "Unholy (feat. Kim Petras)". The page must recompute it itself — otherwise
    # the fix will not reach the phone until crawler revisits the artist.
    conn = await asyncpg.connect(postgres_url)
    try:
        await conn.execute(LOADED)
        ids = await _seed(conn, "Sam Smith", ["Unholy", "Stay With Me"])
        top = ["Unholy (feat. Kim Petras)", "Stay with Me"]
        saved = {norm("Stay with Me"): {"id": ids["Stay With Me"], "duration_ms": 200000}, "$rule": 1}
        await conn.execute(
            "INSERT INTO lastfm_artists (artist_key, found, top_tracks, similar_artists, top_track_ids) "
            "VALUES ($1, true, $2, '{}', $3::jsonb)",
            norm("Sam Smith"), top, json.dumps(saved),
        )
        page = await lastfm.blocks(conn, "Sam Smith")
        by_title = {item["title"]: item for item in page["top_tracks"]}
        assert by_title["Unholy (feat. Kim Petras)"].get("id") == ids["Unholy"], (
            "old top is not recomputed: song with guest still lacks an id"
        )
        assert by_title["Stay with Me"].get("id") == ids["Stay With Me"]
    finally:
        await conn.close()
