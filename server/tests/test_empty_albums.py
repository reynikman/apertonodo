"""FT-538: no songless albums appear on artist page.

For 2N in MusicBrainz replica there are two albums — "Grasscatcher" and "Find Your Own Way
Home": release exists, medium exists, but nobody added the tracklist to MusicBrainz.
The page showed them, the album opened empty, and the nightly live sources
check failed (03.10). In the production replica there are 7,643 such groups.

Nearby second case — 913 groups: the first edition in order is empty, while
another edition of the same group has songs. The album opened empty even though
songs existed.
"""

from __future__ import annotations

import uuid

import asyncpg
import pytest

from app import catalog_browse as browse
from app.migrate import apply

ARTIST = uuid.UUID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaa538")
TABLES = ("mb_track", "mb_medium", "mb_release", "mb_release_group", "mb_recording", "mb_artist")


async def _reset(url: str) -> None:
    conn = await asyncpg.connect(url)
    try:
        for table in TABLES:
            await conn.execute(f"TRUNCATE {table} CASCADE")
    finally:
        await conn.close()


@pytest.fixture
async def conn(postgres_url: str):
    await apply(postgres_url)
    await _reset(postgres_url)
    connection = await asyncpg.connect(postgres_url)
    await connection.execute(
        "INSERT INTO mb_artist (mbid, name, sort_name, ended) VALUES ($1, '2N', '2N', false)", ARTIST
    )
    try:
        yield connection
    finally:
        await connection.close()
        await _reset(postgres_url)


_medium = 0


async def _album(conn: asyncpg.Connection, title: str, editions: list[tuple[str, int]]) -> uuid.UUID:
    """Group with editions: (date, song count in it). Each has a medium."""
    global _medium
    group = uuid.uuid4()
    await conn.execute(
        "INSERT INTO mb_release_group (mbid, artist_mbid, title, primary_type, secondary_types, first_date) "
        "VALUES ($1, $2, $3, 'Album', '{}', $4)",
        group, ARTIST, title, editions[0][0],
    )
    for date, songs in editions:
        release = uuid.uuid4()
        await conn.execute(
            "INSERT INTO mb_release (mbid, group_mbid, title, status, date) VALUES ($1, $2, $3, 'Official', $4)",
            release, group, title, date,
        )
        _medium += 1
        await conn.execute(
            "INSERT INTO mb_medium (id, release_mbid, position, format) VALUES ($1, $2, 1, 'CD')", _medium, release
        )
        for position in range(1, songs + 1):
            rec = uuid.uuid4()
            await conn.execute(
                "INSERT INTO mb_recording (mbid, artist_mbid, title, length_ms) VALUES ($1, $2, $3, 200000)",
                rec, ARTIST, f"{title} {position}",
            )
            await conn.execute(
                "INSERT INTO mb_track (mbid, medium_id, recording_mbid, position, title, length_ms) "
                "VALUES ($1, $2, $3, $4, $5, 200000)",
                uuid.uuid4(), _medium, rec, position, f"{title} {position}",
            )
    return group


async def test_album_without_songs_is_not_on_the_artist_page(conn: asyncpg.Connection) -> None:
    await _album(conn, "Grasscatcher", [("1995", 0)])
    await _album(conn, "Find Your Own Way Home", [("2001", 0)])
    real = await _album(conn, "Real One", [("1998", 3)])
    _found, _aliases, groups, _discs = await browse.get_artist(conn, artist_id=str(ARTIST))
    assert [g["title"] for g in groups] == ["Real One"], (
        "album without any songs on artist page — it will open empty"
    )
    assert groups[0]["id"] == str(real)


async def test_album_opens_the_edition_that_has_songs(conn: asyncpg.Connection) -> None:
    # First edition in order (earlier date) is empty, reissue has songs.
    group = await _album(conn, "Late Tracklist", [("1990", 0), ("2005", 4)])
    _found, _aliases, groups, _discs = await browse.get_artist(conn, artist_id=str(ARTIST))
    assert [g["title"] for g in groups] == ["Late Tracklist"], "album with songs in another edition disappeared"
    _group, _disc, tracks = await browse.get_album(conn, group)
    assert len(tracks) == 4, "album opened empty edition even though neighbor has songs"
