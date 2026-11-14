"""Import finds a song that has no original recording in the replica (FT-513).

Production, 02.10.2026: importing owner's playlist failed to find some songs that
search does find. For such songs `song.original_recording_mbid` is null — song
builder didn't pick an original recording — and import queries (ISRC, exact and similar
title) joined duration via an inner join and lost the song
entirely. Rule: song is found; ID — own (like a song of own release
list), duration — 0, "unknown".
"""

from __future__ import annotations

import asyncio
from uuid import UUID

import asyncpg
from test_import_match import METALLICA, _match, _own_id, catalog_db  # noqa: F401 — fixture

from app.import_formats import ImportRow

ORION_LIVE = UUID(int=150)
ORION_ISRC = "USEE19900150"


async def _orphan(url: str) -> None:
    conn = await asyncpg.connect(url)
    try:
        await conn.execute(
            "INSERT INTO mb_recording (mbid, artist_mbid, title, length_ms) VALUES ($1, $2, 'Orion', 500000)",
            ORION_LIVE,
            METALLICA,
        )
        song = await conn.fetchval(
            "INSERT INTO song (artist_mbid, title, original_recording_mbid) VALUES ($1, 'Orion', NULL) RETURNING id",
            METALLICA,
        )
        await conn.execute(
            "INSERT INTO song_version (song_id, recording_mbid, kind) VALUES ($1, $2, 'live')", song, ORION_LIVE
        )
        await conn.execute("INSERT INTO mb_isrc (recording_mbid, isrc) VALUES ($1, $2)", ORION_LIVE, ORION_ISRC)
    finally:
        await conn.close()


ORION = {
    "id": _own_id("Metallica", "Orion"),
    "title": "Orion",
    "artist": "Metallica",
    "duration_ms": 0,
    "artwork_url": "",
}


def test_song_without_original_is_found_by_title_and_by_isrc(catalog_db: str) -> None:  # noqa: F811
    asyncio.run(_orphan(catalog_db))
    rows = [
        ImportRow("Metallica", "Orion"),  # exact title
        ImportRow("Metallica", "Orion - Remastered"),  # Spotify suffix
        ImportRow("Someone Else", "Wrong Title", isrc=ORION_ISRC),  # ISRC takes priority
    ]
    result, _calls = _match(catalog_db, rows)
    assert [m.status for m in result] == ["found"] * 3, [m.status for m in result]
    assert [m.track for m in result] == [ORION] * 3


def test_song_without_original_is_offered_among_similar(catalog_db: str) -> None:  # noqa: F811
    asyncio.run(_orphan(catalog_db))
    result, _calls = _match(catalog_db, [ImportRow("Metallica", "Orions")])
    assert result[0].status == "doubtful"
    assert ORION in result[0].candidates
