"""FT-569 (R-A82 p. 6): "Popular" track gets an ID if it is the artist's own recording.

Owner's finding 05.10: "Popular" rows are dim, tapping opens search.
Two reasons in production:

- the artist's own recording is marked `cover`: Alexandra Burke "Hallelujah" is
  a true cover, Amy Winehouse "You Know I'm No Good" — home recording
  chosen by year, tied with Ghostface Killah remix. ID was searched only
  among `original`;
- edition tail on Last.fm: "- Single Version", "- Edit", "- From Barbie The
  Album", '(From "Lakmé")', while dash-separated version — "Pool - Stripped" —
  is in brackets on the recording: "Pool (stripped)".

A version remains a version: "- Live" is not replaced by a studio recording
(test_top_featured.py, Remix/Live/Acoustic is a different recording).
"""

from __future__ import annotations

import json

import asyncpg
import pytest

import app.local_search as local_search
from app import lastfm
from app.migrate import apply
from app.names import norm

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


async def _artist(conn: asyncpg.Connection, name: str) -> str:
    return await conn.fetchval(
        "INSERT INTO mb_artist (mbid, name, sort_name, ended) VALUES (gen_random_uuid(), $1, $1, false) RETURNING mbid",
        name,
    )


async def _recording(conn: asyncpg.Connection, artist: str, title: str, kind: str = "original") -> str:
    rec = await conn.fetchval(
        "INSERT INTO mb_recording (mbid, artist_mbid, title, length_ms) VALUES (gen_random_uuid(), $1, $2, 200000) RETURNING mbid",
        artist, title,
    )
    # As in production: a song made entirely of covers has no "original" of its own.
    song = await conn.fetchval(
        "INSERT INTO song (artist_mbid, title, original_recording_mbid) VALUES ($1, $2, $3) RETURNING id",
        artist, title, rec if kind == "original" else None,
    )
    await conn.execute(
        "INSERT INTO song_version (song_id, recording_mbid, kind, year) VALUES ($1, $2, $3, 2006)",
        song, rec, kind,
    )
    return str(rec)


async def test_own_recording_marked_cover_gets_a_number(postgres_url: str) -> None:
    conn = await asyncpg.connect(postgres_url)
    try:
        burke = await _artist(conn, "Alexandra Burke")
        hallelujah = await _recording(conn, burke, "Hallelujah", kind="cover")
        amy = await _artist(conn, "Amy Winehouse")
        good = await _recording(conn, amy, "You Know I’m No Good", kind="cover")

        found = await local_search.top_track_ids(conn, "Alexandra Burke", ["Hallelujah"])
        assert found.get(norm("Hallelujah"), {}).get("id") == hallelujah, "own cover recording without ID"
        found = await local_search.top_track_ids(conn, "Amy Winehouse", ["You Know I'm No Good"])
        assert found.get(norm("You Know I'm No Good"), {}).get("id") == good, "Amy recording marked cover — without ID"
    finally:
        await conn.close()


async def test_original_beats_cover_of_the_same_title(postgres_url: str) -> None:
    conn = await asyncpg.connect(postgres_url)
    try:
        art = await _artist(conn, "Barry White")
        await _recording(conn, art, "Just the Way You Are", kind="cover")
        original = await _recording(conn, art, "Just the Way You Are")
        found = await local_search.top_track_ids(conn, "Barry White", ["Just The Way You Are"])
        assert found.get(norm("Just The Way You Are"), {}).get("id") == original
    finally:
        await conn.close()


async def test_edition_tail_does_not_hide_the_song(postgres_url: str) -> None:
    conn = await asyncpg.connect(postgres_url)
    try:
        cases = [
            ("Breaking Benjamin", "The Diary of Jane", "The Diary of Jane - Single Version"),
            ("Barry White", "You’re the First, the Last, My Everything", "You're The First, The Last, My Everything - Edit"),
            ("Dua Lipa", "Dance the Night", "Dance The Night - From Barbie The Album"),
            ("Katherine Jenkins", "The Flower Duet", 'The Flower Duet (From "Lakmé")'),
        ]
        for artist, recorded, shown in cases:
            rec = await _recording(conn, await _artist(conn, artist), recorded)
            found = await local_search.top_track_ids(conn, artist, [shown])
            assert found.get(norm(shown), {}).get("id") == rec, f"tail not stripped: {shown}"
    finally:
        await conn.close()


async def test_version_after_dash_matches_version_in_brackets(postgres_url: str) -> None:
    conn = await asyncpg.connect(postgres_url)
    try:
        samia = await _artist(conn, "Samia")
        await _recording(conn, samia, "Pool")
        stripped = await _recording(conn, samia, "Pool (stripped)")
        found = await local_search.top_track_ids(conn, "Samia", ["Pool - Stripped"])
        assert found.get(norm("Pool - Stripped"), {}).get("id") == stripped, "'- Stripped' did not match '(stripped)'"

        pavarotti = await _artist(conn, "Luciano Pavarotti")
        live = await _recording(conn, pavarotti, "We Are the World (live)", kind="live")
        found = await local_search.top_track_ids(conn, "Luciano Pavarotti", ["We Are The World - Live"])
        assert found.get(norm("We Are The World - Live"), {}).get("id") == live, "own live recording without ID"
    finally:
        await conn.close()


async def test_live_is_not_replaced_by_the_studio_song(postgres_url: str) -> None:
    conn = await asyncpg.connect(postgres_url)
    try:
        art = await _artist(conn, "Luciano Pavarotti")
        await _recording(conn, art, "We Are the World")
        found = await local_search.top_track_ids(conn, "Luciano Pavarotti", ["We Are The World - Live"])
        assert found == {}
    finally:
        await conn.close()


async def test_top_saved_by_the_old_rule_is_recounted(postgres_url: str) -> None:
    # In production, top was already calculated with rule 2: "Hallelujah" without ID. The page
    # must recalculate it itself, otherwise the fix won't reach the phone.
    conn = await asyncpg.connect(postgres_url)
    try:
        await conn.execute(LOADED)
        rec = await _recording(conn, await _artist(conn, "Alexandra Burke"), "Hallelujah", kind="cover")
        await conn.execute(
            "INSERT INTO lastfm_artists (artist_key, found, top_tracks, similar_artists, top_track_ids) "
            "VALUES ($1, true, $2, '{}', $3::jsonb)",
            norm("Alexandra Burke"), ["Hallelujah"], json.dumps({"$rule": 2}),
        )
        page = await lastfm.blocks(conn, "Alexandra Burke")
        assert page["top_tracks"][0].get("id") == rec, "top by rule 2 was not recalculated"
    finally:
        await conn.close()
