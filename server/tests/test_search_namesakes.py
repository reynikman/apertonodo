"""Namesakes and "artist or song" in search over the MusicBrainz dump.

Prod, 30.09.2026: "prince purple rain" and "michael jackson thriller" — zero rows:
there are dozens of artists with that name, search took the first ten it found, and
the real one was not among them. "madonna" opened Drake's song "Madonna",
"blur" — Britney Spears' song "Blur".
"""

from __future__ import annotations

import json

import asyncpg

import app.local_search as local_search


async def _artist(conn: asyncpg.Connection, name: str, titles: list[str]) -> str:
    art = await conn.fetchval(
        "INSERT INTO mb_artist (mbid, name, sort_name, ended) VALUES (gen_random_uuid(), $1, $1, false) RETURNING mbid",
        name,
    )
    for title in titles:
        rec = await conn.fetchval(
            "INSERT INTO mb_recording (mbid, artist_mbid, title, length_ms) VALUES (gen_random_uuid(), $1, $2, 200000) RETURNING mbid",
            art,
            title,
        )
        song = await conn.fetchval(
            "INSERT INTO song (artist_mbid, title, original_recording_mbid) VALUES ($1, $2, $3) RETURNING id",
            art,
            title,
            rec,
        )
        await conn.execute(
            "INSERT INTO song_version (song_id, recording_mbid, kind, year) VALUES ($1, $2, 'original', 1984)",
            song,
            rec,
        )
    return str(art)


async def _lastfm(conn: asyncpg.Connection, key: str) -> None:
    await conn.execute(
        "INSERT INTO lastfm_artists (artist_key, found, top_track_ids) VALUES ($1, true, $2::jsonb) ON CONFLICT DO NOTHING",
        key,
        json.dumps({}),
    )


async def test_real_artist_found_among_many_namesakes(postgres_url: str) -> None:
    conn = await asyncpg.connect(postgres_url)
    try:
        # Twelve namesakes with one song each — ahead of the real one, as in the MusicBrainz dump.
        for n in range(12):
            await _artist(conn, "Prince", [f"Demo {n}"])
            await _artist(conn, "Michael Jackson", [f"Cover {n}"])
        prince = await _artist(conn, "Prince", ["Purple Rain", "When Doves Cry", "Kiss", "1999"])
        mj = await _artist(conn, "Michael Jackson", ["Thriller", "Billie Jean", "Beat It", "Bad"])
        for query, artist, title in (
            ("prince purple rain", prince, "Purple Rain"),
            ("purple rain prince", prince, "Purple Rain"),
            ("michael jackson thriller", mj, "Thriller"),
            ("thriller michael jackson", mj, "Thriller"),
        ):
            hits = await local_search.search(conn, query, limit=5)
            assert hits, query
            assert hits[0]["title"] == title, (query, hits[0])
            assert hits[0]["artist_id"] == artist, query
        # Just the name — the real one comes first, not a namesake with one song.
        for query, artist in (("prince", prince), ("michael jackson", mj)):
            hits = await local_search.search(conn, query, limit=5)
            assert hits and hits[0]["artist_id"] == artist, (query, hits[:2])
    finally:
        await conn.close()


async def test_known_artist_name_beats_song_with_that_title(postgres_url: str) -> None:
    conn = await asyncpg.connect(postgres_url)
    try:
        await _artist(conn, "Drake", ["Madonna", "Hotline Bling"])
        await _artist(conn, "Britney Spears", ["Blur", "Toxic"])
        await _artist(conn, "Madonna", ["Vogue", "Frozen"])
        await _artist(conn, "Blur", ["Song 2", "Parklife"])
        for key in ("drake", "britney spears", "madonna", "blur"):
            await _lastfm(conn, key)
        for query, artist in (("madonna", "Madonna"), ("Blur", "Blur")):
            hits = await local_search.search(conn, query, limit=5)
            assert hits and hits[0]["artist"] == artist, (query, hits[:2])
    finally:
        await conn.close()


async def test_unknown_namesake_artist_does_not_bury_famous_song(postgres_url: str) -> None:
    # The flip side: an obscure artist "One" should not eclipse Metallica's "One".
    conn = await asyncpg.connect(postgres_url)
    try:
        await _artist(conn, "One", ["Garage Tape"])
        await _artist(conn, "Metallica", ["One", "Fade to Black"])
        await _lastfm(conn, "metallica")
        hits = await local_search.search(conn, "one", limit=5)
        assert hits and (hits[0]["artist"], hits[0]["title"]) == ("Metallica", "One"), hits[:2]
    finally:
        await conn.close()
