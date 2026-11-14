"""FT-022: edition preference and legacy aliases survive the catalog rebuild."""

from __future__ import annotations

import uuid

import asyncpg
import pytest

from app.catalog_songs import build
from app.editions import can_play_alias, get_preference, record_alias, resolve_alias, resolve_edition, set_preference
from app.migrate import apply

ARTIST = uuid.UUID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1")
ALBUM = uuid.UUID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2")
WORK_A = uuid.UUID("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1")
WORK_B = uuid.UUID("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2")
REC_STUDIO = uuid.UUID("cccccccc-cccc-4ccc-8ccc-cccccccccc01")
REC_LIVE = uuid.UUID("cccccccc-cccc-4ccc-8ccc-cccccccccc02")
REC_OTHER = uuid.UUID("cccccccc-cccc-4ccc-8ccc-cccccccccc03")
REL_ALBUM = uuid.UUID("dddddddd-dddd-4ddd-8ddd-dddddddddd01")
REL_REMASTER = uuid.UUID("dddddddd-dddd-4ddd-8ddd-dddddddddd02")
REL_LIVE = uuid.UUID("dddddddd-dddd-4ddd-8ddd-dddddddddd03")
REL_OTHER = uuid.UUID("dddddddd-dddd-4ddd-8ddd-dddddddddd04")
ID_A = uuid.UUID("eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01")
ID_B = uuid.UUID("eeeeeeee-eeee-4eee-8eee-eeeeeeeeee02")
OLD_TRACK = uuid.UUID("ffffffff-ffff-4fff-8fff-ffffffffff01")
OLD_KEY = "metallica|enter sandman"
TABLES = (
    "song_version", "song", "mb_isrc", "mb_recording_work", "mb_track",
    "mb_medium", "mb_release", "mb_release_group", "mb_recording", "mb_work", "mb_artist",
)


async def _reset(url: str) -> None:
    conn = await asyncpg.connect(url)
    try:
        await conn.execute("TRUNCATE song_identity CASCADE")
        for table in TABLES:
            await conn.execute(f"TRUNCATE {table} CASCADE")
    finally:
        await conn.close()


async def _seed(conn: asyncpg.Connection) -> None:
    await conn.execute("INSERT INTO mb_artist (mbid, name, sort_name, ended) VALUES ($1, 'Metallica', 'Metallica', false)", ARTIST)
    await conn.executemany("INSERT INTO mb_work (mbid, title) VALUES ($1, 'Work')", [(WORK_A,), (WORK_B,)])
    for rec, title, work in ((REC_STUDIO, "Enter Sandman", WORK_A), (REC_LIVE, "Enter Sandman (Live)", WORK_A), (REC_OTHER, "One", WORK_B)):
        await conn.execute(
            "INSERT INTO mb_recording (mbid, artist_mbid, title, length_ms, comment) VALUES ($1, $2, $3, 240000, '')", rec, ARTIST, title)
        await conn.execute("INSERT INTO mb_recording_work (recording_mbid, work_mbid, attributes) VALUES ($1, $2, '{}')", rec, work)
    await conn.execute(
        "INSERT INTO mb_release_group (mbid, artist_mbid, title, primary_type, secondary_types, first_date) VALUES ($1, $2, 'Metallica', 'Album', '{}', '1991-08-12')",
        ALBUM, ARTIST)
    editions = (
        (REL_ALBUM, "Metallica", "1991-08-12", REC_STUDIO),
        (REL_REMASTER, "Metallica (Remaster 2021)", "2021-09-10", REC_STUDIO),
        (REL_LIVE, "Live Shit", "1993-11-23", REC_LIVE),
        (REL_OTHER, "One", "1991-08-12", REC_OTHER),
    )
    for medium, (release, title, date, rec) in enumerate(editions, start=1):
        await conn.execute("INSERT INTO mb_release (mbid, group_mbid, title, status, date) VALUES ($1, $2, $3, 'Official', $4)", release, ALBUM, title, date)
        await conn.execute("INSERT INTO mb_medium (id, release_mbid, position, format) VALUES ($1, $2, 1, 'CD')", medium, release)
        await conn.execute(
            "INSERT INTO mb_track (mbid, medium_id, recording_mbid, position, title, length_ms) VALUES ($1, $2, $3, 1, $4, 240000)",
            uuid.uuid4(), medium, rec, title)
    await conn.execute(
        "INSERT INTO song (id, artist_mbid, title, work_mbid, original_recording_mbid, original_year) VALUES (10, $1, 'Enter Sandman', $2, $3, 1991), (20, $1, 'One', $4, $5, 1991)",
        ARTIST, WORK_A, REC_STUDIO, WORK_B, REC_OTHER)
    for song_id, rec, kind in ((10, REC_STUDIO, "original"), (10, REC_LIVE, "live"), (20, REC_OTHER, "original")):
        await conn.execute("INSERT INTO song_version (song_id, recording_mbid, kind, year) VALUES ($1, $2, $3, 1991)", song_id, rec, kind)
    await conn.execute(
        "INSERT INTO song_identity (song_id, identity_key, v3_song_id) VALUES ($1, $2, 10), ($3, $4, 20)",
        ID_A, f"w:{ARTIST}:{WORK_A}", ID_B, f"w:{ARTIST}:{WORK_B}")


@pytest.fixture
async def db(postgres_url: str):
    await apply(postgres_url)
    await _reset(postgres_url)
    yield postgres_url
    await _reset(postgres_url)


@pytest.fixture
async def conn(db: str):
    connection = await asyncpg.connect(db)
    await _seed(connection)
    try:
        yield connection
    finally:
        await connection.close()


async def test_rebuild_renumbers_v3_ids_but_alias_and_preference_survive(conn: asyncpg.Connection, db: str) -> None:
    await record_alias(conn, old_track_id=OLD_TRACK, old_canonical_key=OLD_KEY, song_id=10)
    await set_preference(conn, song_id=10, edition_id=REL_ALBUM, album_id=ALBUM)
    before = await get_preference(conn, song_id=10, album_id=ALBUM)
    await build(db)
    new_a = await conn.fetchval("SELECT song_id FROM song_version WHERE recording_mbid = $1", REC_STUDIO)
    new_b = await conn.fetchval("SELECT song_id FROM song_version WHERE recording_mbid = $1", REC_OTHER)
    assert new_a != 10 and new_b != 20, "rebuild did not renumber the V3 song ids"
    assert before["song_id"] == str(ID_A)
    assert await resolve_alias(conn, old_track_id=OLD_TRACK) == new_a
    assert await resolve_alias(conn, old_canonical_key=OLD_KEY) == new_a
    assert await can_play_alias(conn, old_track_id=OLD_TRACK) is True
    assert await get_preference(conn, song_id=new_a, album_id=ALBUM) == before


async def test_unavailable_preference_gets_explicit_fallback(conn: asyncpg.Connection) -> None:
    await set_preference(conn, song_id=10, edition_id=REL_REMASTER, album_id=ALBUM)
    resolved = await resolve_edition(
        conn, song_id=10, album_id=ALBUM, preferred_edition_id=REL_REMASTER, available_editions={REL_ALBUM})
    version = await conn.fetchval("SELECT kind FROM song_version WHERE song_id = 10 AND recording_mbid = $1", REC_STUDIO)
    quality = await conn.fetchval("SELECT lower(format) FROM mb_medium WHERE release_mbid = $1", REL_ALBUM)
    assert resolved == {"fallback": True, "edition_id": REL_ALBUM, "version": version, "quality": quality}
    await set_preference(conn, song_id=10, edition_id=REL_REMASTER)
    assert (await get_preference(conn, song_id=10))["edition_id"] == str(REL_REMASTER)


async def test_live_preference_reports_live_for_original_request(conn: asyncpg.Connection) -> None:
    await set_preference(conn, song_id=10, edition_id=REL_ALBUM, album_id=ALBUM)
    await set_preference(conn, song_id=10, edition_id=REL_LIVE, album_id=ALBUM)
    resolved = await resolve_edition(conn, song_id=10, album_id=ALBUM, requested_kind="original")
    version = await conn.fetchval("SELECT kind FROM song_version WHERE song_id = 10 AND recording_mbid = $1", REC_LIVE)
    assert resolved["fallback"] is False
    assert resolved["edition_id"] == REL_LIVE
    assert resolved["version"] == version == "live"


async def test_live_edition_is_not_substituted_for_missing_original(conn: asyncpg.Connection) -> None:
    with pytest.raises(LookupError):
        await resolve_edition(conn, song_id=10, requested_kind="original", available_editions={REL_LIVE})


async def test_preference_for_edition_without_the_song_is_rejected(conn: asyncpg.Connection) -> None:
    with pytest.raises(ValueError):
        await set_preference(conn, song_id=10, edition_id=REL_OTHER, album_id=ALBUM)


async def test_resolve_alias_with_both_identifiers(conn: asyncpg.Connection) -> None:
    await record_alias(conn, old_track_id=OLD_TRACK, old_canonical_key=OLD_KEY, song_id=10)
    target = await conn.fetchval("SELECT id FROM song WHERE id = 10")
    assert await resolve_alias(conn, old_track_id=OLD_TRACK, old_canonical_key=OLD_KEY) == target
    assert await resolve_alias(conn, old_track_id=uuid.uuid4(), old_canonical_key=OLD_KEY) == target


async def test_ensure_identity_only_touches_target_song(conn: asyncpg.Connection) -> None:
    await conn.execute(
        "INSERT INTO song (id, artist_mbid, title, original_year) "
        "SELECT i, $1, 'Song ' || i, 2000 FROM generate_series(1001, 2000) AS i", ARTIST)
    await conn.execute("INSERT INTO song (id, artist_mbid, title, original_year) VALUES (3000, $1, 'Target', 2000)", ARTIST)
    before = await conn.fetchval("SELECT count(*) FROM song_identity")
    await record_alias(conn, old_track_id=uuid.uuid4(), song_id=3000)
    assert await conn.fetchval("SELECT count(*) FROM song_identity") == before + 1
    unidentified = await conn.fetchval(
        "SELECT count(*) FROM song s WHERE s.id BETWEEN 1001 AND 2000 "
        "AND NOT EXISTS (SELECT 1 FROM song_identity i WHERE i.v3_song_id = s.id)")
    assert unidentified == 1000
    expected_v3 = await conn.fetchval("SELECT id FROM song WHERE id = 10")
    assert await conn.fetchval("SELECT v3_song_id FROM song_identity WHERE song_id = $1", ID_A) == expected_v3


async def test_ensure_identity_does_not_take_the_number_of_a_live_song(conn: asyncpg.Connection) -> None:
    # Before FT-679 song 4000 took the ID_B number from live song 20, leaving it without a number.
    rec_x = uuid.uuid4()
    await conn.execute("INSERT INTO mb_recording (mbid, artist_mbid, title, length_ms, comment) VALUES ($1, $2, 'Target Rec', 200, '')", rec_x, ARTIST)
    await conn.execute("INSERT INTO song_alias (old_track_id, song_id) VALUES ($1, $2)", rec_x, ID_B)
    await conn.execute("INSERT INTO song (id, artist_mbid, title, original_recording_mbid, original_year) VALUES (4000, $1, 'Target Title', $2, 2020)", ARTIST, rec_x)
    await conn.execute("INSERT INTO song_version (song_id, recording_mbid, kind, year) VALUES (4000, $1, 'original', 2020)", rec_x)
    await record_alias(conn, old_canonical_key="metallica|target title", song_id=4000)
    assigned = await conn.fetchval("SELECT song_id FROM song_identity WHERE v3_song_id = 4000")
    assert assigned is not None and assigned != ID_B
    assert await conn.fetchval("SELECT v3_song_id FROM song_identity WHERE song_id = $1", ID_B) == 20
    # The recording now belongs to song 4000 — the old reference to it leads there too.
    assert await conn.fetchval("SELECT song_id FROM song_alias WHERE old_track_id = $1", rec_x) == assigned


async def test_fallback_prefers_original_recording_over_earlier_edition(conn: asyncpg.Connection) -> None:
    rec_alt = uuid.uuid4()
    rel_early = uuid.uuid4()
    await conn.execute("INSERT INTO mb_recording (mbid, artist_mbid, title, length_ms, comment) VALUES ($1, $2, 'Enter Sandman (Alt)', 240000, '')", rec_alt, ARTIST)
    await conn.execute("INSERT INTO song_version (song_id, recording_mbid, kind, year) VALUES (10, $1, 'original', 1980)", rec_alt)
    await conn.execute("INSERT INTO mb_release (mbid, group_mbid, title, status, date) VALUES ($1, $2, 'Early Single', 'Official', '1980-01-01')", rel_early, ALBUM)
    await conn.execute("INSERT INTO mb_medium (id, release_mbid, position, format) VALUES (50, $1, 1, 'Vinyl')", rel_early)
    await conn.execute("INSERT INTO mb_track (mbid, medium_id, recording_mbid, position, title, length_ms) VALUES ($1, 50, $2, 1, 'Enter Sandman (Alt)', 240000)", uuid.uuid4(), rec_alt)
    resolved = await resolve_edition(conn, song_id=10, requested_kind="original")
    original_rel = await conn.fetchval(
        "SELECT m.release_mbid FROM mb_medium m JOIN mb_track t ON t.medium_id = m.id "
        "WHERE t.recording_mbid = (SELECT original_recording_mbid FROM song WHERE id = 10)")
    assert resolved["edition_id"] == original_rel == REL_ALBUM


async def test_set_preference_rejects_edition_of_different_album(conn: asyncpg.Connection) -> None:
    other_album = uuid.uuid4()
    await conn.execute("INSERT INTO mb_release_group (mbid, artist_mbid, title, primary_type, secondary_types, first_date) VALUES ($1, $2, 'Other', 'Album', '{}', '2000-01-01')", other_album, ARTIST)
    with pytest.raises(ValueError, match="edition does not belong to the given album"):
        await set_preference(conn, song_id=10, edition_id=REL_ALBUM, album_id=other_album)


async def test_can_play_alias_false_without_track_medium(conn: asyncpg.Connection) -> None:
    unreleased = uuid.uuid4()
    await conn.execute("INSERT INTO mb_recording (mbid, artist_mbid, title, length_ms, comment) VALUES ($1, $2, 'Unreleased', 180000, '')", unreleased, ARTIST)
    await conn.execute("INSERT INTO song (id, artist_mbid, title, original_recording_mbid, original_year) VALUES (50, $1, 'Unreleased', $2, 2025)", ARTIST, unreleased)
    await conn.execute("INSERT INTO song_version (song_id, recording_mbid, kind, year) VALUES (50, $1, 'original', 2025)", unreleased)
    alias_track = uuid.uuid4()
    await record_alias(conn, old_track_id=alias_track, song_id=50)
    assert await can_play_alias(conn, old_track_id=alias_track) is False
