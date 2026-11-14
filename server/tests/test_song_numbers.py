"""FT-679: permanent song numbers survive merges and splits between two MusicBrainz dumps."""

from __future__ import annotations

import uuid

import asyncpg
import pytest

from app.migrate import apply
from app.song_numbers import IdentityConflict, assign

ARTIST = uuid.UUID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1")
U1 = uuid.UUID("11111111-1111-4111-8111-111111111111")
U2 = uuid.UUID("22222222-2222-4222-8222-222222222222")
TABLES = ("song_version", "song", "mb_recording", "mb_work", "mb_artist")


def _u(kind: str, n: int) -> uuid.UUID:
    return uuid.UUID(f"{kind * 8}-{kind * 4}-4{kind * 3}-8{kind * 3}-{n:012d}")


def work(n: int) -> uuid.UUID:
    return _u("b", n)


def rec(n: int) -> uuid.UUID:
    return _u("c", n)


def num(n: int) -> uuid.UUID:
    return _u("e", n)


def key(n: int) -> str:
    return f"w:{ARTIST}:{work(n)}"


async def _reset(url: str) -> None:
    conn = await asyncpg.connect(url)
    try:
        await conn.execute("TRUNCATE song_identity CASCADE")
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
        "INSERT INTO mb_artist (mbid, name, sort_name, ended) VALUES ($1, 'Band', 'Band', false)",
        ARTIST,
    )
    try:
        yield connection
    finally:
        await connection.close()
        await _reset(postgres_url)


async def old(
    conn: asyncpg.Connection,
    n: int,
    work_n: int | None,
    recs: tuple[int, ...] = (),
    v3: int | None = None,
) -> None:
    """An old number: its key and the recordings that carried it."""
    await conn.execute(
        "INSERT INTO song_identity (song_id, identity_key, v3_song_id) VALUES ($1, $2, $3)",
        num(n),
        key(work_n) if work_n is not None else f"gone:{n}",
        v3,
    )
    for r in recs:
        await conn.execute(
            "INSERT INTO song_alias (old_track_id, song_id) VALUES ($1, $2)",
            rec(r),
            num(n),
        )


async def new(
    conn: asyncpg.Connection,
    song_id: int,
    work_n: int,
    recs: tuple[int, ...],
    title: str = "Song",
) -> None:
    """A song of the new dump and its recordings."""
    await conn.execute(
        "INSERT INTO mb_work (mbid, title) VALUES ($1, 'Work') ON CONFLICT DO NOTHING",
        work(work_n),
    )
    await conn.execute(
        "INSERT INTO song (id, artist_mbid, title, work_mbid, original_recording_mbid, original_year) "
        "VALUES ($1, $2, $3, $4, $5, 1991)",
        song_id,
        ARTIST,
        title,
        work(work_n),
        rec(recs[0]),
    )
    for r in recs:
        await conn.execute(
            "INSERT INTO mb_recording (mbid, artist_mbid, title, length_ms, comment) VALUES ($1, $2, $3, 240000, '') "
            "ON CONFLICT DO NOTHING",
            rec(r),
            ARTIST,
            f"{title} {r}",
        )
        await conn.execute(
            "INSERT INTO song_version (song_id, recording_mbid, kind, year) VALUES ($1, $2, 'original', 1991)",
            song_id,
            rec(r),
        )


async def number_of(conn: asyncpg.Connection, song_id: int) -> uuid.UUID | None:
    return await conn.fetchval(
        "SELECT song_id FROM song_identity WHERE v3_song_id = $1", song_id
    )


async def run(conn: asyncpg.Connection, only: int | None = None) -> dict[str, int]:
    async with conn.transaction():
        return await assign(conn, only)


async def state(conn: asyncpg.Connection) -> list[tuple]:
    rows = await conn.fetch(
        "SELECT song_id, identity_key, v3_song_id FROM song_identity ORDER BY song_id"
    )
    aliases = await conn.fetch(
        "SELECT old_track_id, old_canonical_key, song_id FROM song_alias ORDER BY old_track_id, old_canonical_key"
    )
    return [tuple(r) for r in rows] + [tuple(r) for r in aliases]


# --- nothing changed ------------------------------------------------------


async def test_same_song_keeps_its_number(conn) -> None:
    await old(conn, 1, 1, (1, 2), v3=77)
    await new(conn, 10, 1, (1, 2))
    counts = await run(conn)
    assert await number_of(conn, 10) == num(1)
    assert counts == {"songs": 1, "kept": 1, "new": 0, "split": 0, "merged": 0}
    assert await conn.fetchval("SELECT count(*) FROM song_identity") == 1


async def test_brand_new_song_gets_a_new_number(conn) -> None:
    await old(conn, 1, 1, (1,))
    await new(conn, 10, 1, (1,))
    await new(conn, 20, 2, (5,))
    counts = await run(conn)
    fresh = await number_of(conn, 20)
    assert fresh is not None and fresh != num(1)
    assert counts == {"songs": 2, "kept": 1, "new": 1, "split": 0, "merged": 0}
    assert await conn.fetchval(
        "SELECT identity_key FROM song_identity WHERE song_id = $1", fresh
    ) == key(2)


async def test_number_found_by_key_alone(conn) -> None:
    await old(conn, 1, 1)
    await new(conn, 10, 1, (9,))
    await run(conn)
    assert await number_of(conn, 10) == num(1)


async def test_number_found_by_recordings_alone_takes_the_new_key(conn) -> None:
    await old(conn, 1, 1, (1,))
    await new(conn, 10, 2, (1,))
    await run(conn)
    assert await number_of(conn, 10) == num(1)
    assert await conn.fetchval(
        "SELECT identity_key FROM song_identity WHERE song_id = $1", num(1)
    ) == key(2)


async def test_second_run_changes_nothing(conn) -> None:
    await old(conn, 1, 1, (1, 2))
    await old(conn, 2, 2, (3,))
    await old(conn, 3, 3, (4, 5))
    await new(conn, 10, 1, (1, 2, 3))
    await new(conn, 20, 3, (4,))
    await new(conn, 30, 4, (5,))
    await run(conn)
    before = await state(conn)
    counts = await run(conn)
    assert await state(conn) == before
    assert counts["new"] == 0 and counts["split"] == 0


# --- merge ---------------------------------------------------------------


async def test_merge_keeps_the_number_most_recordings_carried(conn) -> None:
    await old(conn, 1, 1, (1,))
    await old(conn, 2, 2, (2, 3))
    await new(conn, 10, 1, (1, 2, 3))
    counts = await run(conn)
    assert await number_of(conn, 10) == num(2)
    assert counts == {"songs": 1, "kept": 1, "new": 0, "split": 0, "merged": 1}


async def test_merge_tie_goes_to_the_number_that_owns_the_key(conn) -> None:
    await old(conn, 1, 2, (1,))
    await old(conn, 2, 1, (2,))
    await new(conn, 10, 1, (1, 2))
    await run(conn)
    assert await number_of(conn, 10) == num(2)


async def test_merge_tie_without_key_goes_to_the_lower_number(conn) -> None:
    await old(conn, 2, 8, (2,))
    await old(conn, 1, 9, (1,))
    await new(conn, 10, 1, (1, 2))
    await run(conn)
    assert await number_of(conn, 10) == num(1)


async def test_recordings_outvote_the_key(conn) -> None:
    await old(conn, 1, 1)
    await old(conn, 2, 2, (1,))
    await new(conn, 10, 1, (1,))
    await run(conn)
    assert await number_of(conn, 10) == num(2)
    assert await conn.fetchval(
        "SELECT identity_key FROM song_identity WHERE song_id = $1", num(2)
    ) == key(1)


async def test_retired_number_stays_without_a_song_and_gives_up_its_key(conn) -> None:
    await old(conn, 1, 1, (1,), v3=5)
    await old(conn, 2, 2, (2, 3), v3=6)
    await new(conn, 10, 1, (1, 2, 3))
    await run(conn)
    row = await conn.fetchrow(
        "SELECT identity_key, v3_song_id FROM song_identity WHERE song_id = $1", num(1)
    )
    assert row["v3_song_id"] is None
    assert row["identity_key"] == f"retired:{num(1)}"


async def test_retired_number_keeps_a_key_nobody_took(conn) -> None:
    await old(conn, 1, 7, (1,))
    await old(conn, 2, 2, (2, 3))
    await new(conn, 10, 1, (1, 2, 3))
    await run(conn)
    assert await conn.fetchval(
        "SELECT identity_key FROM song_identity WHERE song_id = $1", num(1)
    ) == key(7)


async def test_merge_moves_every_alias_of_the_retired_number(conn) -> None:
    await old(conn, 1, 1, (1, 8))
    await old(conn, 2, 2, (2, 3))
    await conn.execute(
        "INSERT INTO song_alias (old_canonical_key, song_id) VALUES ('band|old name', $1)",
        num(1),
    )
    await new(conn, 10, 1, (1, 2, 3))
    await run(conn)
    assert await conn.fetchval(
        "SELECT song_id FROM song_alias WHERE old_canonical_key = 'band|old name'"
    ) == num(2)
    assert await conn.fetchval(
        "SELECT song_id FROM song_alias WHERE old_track_id = $1", rec(8)
    ) == num(2)
    assert (
        await conn.fetchval(
            "SELECT count(*) FROM song_alias WHERE song_id = $1", num(1)
        )
        == 0
    )


async def test_merge_moves_the_edition_choice(conn) -> None:
    await old(conn, 1, 1, (1,))
    await old(conn, 2, 2, (2, 3))
    edition = uuid.uuid4()
    await conn.execute(
        "INSERT INTO edition_preference (user_id, song_id, edition_id) VALUES ('11111111-1111-4111-8111-111111111111', $1, $2)",
        num(1),
        edition,
    )
    await new(conn, 10, 1, (1, 2, 3))
    await run(conn)
    rows = await conn.fetch(
        "SELECT user_id, song_id, edition_id FROM edition_preference"
    )
    assert [tuple(r) for r in rows] == [(U1, num(2), edition)]


async def test_merge_keeps_the_winners_own_edition_choice(conn) -> None:
    await old(conn, 1, 1, (1,))
    await old(conn, 2, 2, (2, 3))
    mine, other, album = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    await conn.execute(
        "INSERT INTO edition_preference (user_id, song_id, album_id, edition_id) VALUES "
        "('11111111-1111-4111-8111-111111111111', $1, NULL, $3), ('11111111-1111-4111-8111-111111111111', $2, NULL, $4), ('11111111-1111-4111-8111-111111111111', $1, $5, $3), ('22222222-2222-4222-8222-222222222222', $1, NULL, $3)",
        num(1),
        num(2),
        other,
        mine,
        album,
    )
    await new(conn, 10, 1, (1, 2, 3))
    await run(conn)
    rows = await conn.fetch(
        "SELECT user_id, song_id, album_id, edition_id FROM edition_preference ORDER BY user_id, album_id NULLS FIRST"
    )
    assert [tuple(r) for r in rows] == [
        (U1, num(2), None, mine),
        (U1, num(2), album, other),
        (U2, num(2), None, other),
    ]


async def test_two_retired_numbers_with_one_persons_choice_leave_the_lower_one(
    conn,
) -> None:
    await old(conn, 1, 1, (1,))
    await old(conn, 2, 2, (2,))
    await old(conn, 3, 3, (3, 4, 5))
    first, second = uuid.uuid4(), uuid.uuid4()
    await conn.execute(
        "INSERT INTO edition_preference (user_id, song_id, edition_id) VALUES ('11111111-1111-4111-8111-111111111111', $1, $3), ('11111111-1111-4111-8111-111111111111', $2, $4)",
        num(2),
        num(1),
        second,
        first,
    )
    await new(conn, 10, 1, (1, 2, 3, 4, 5))
    counts = await run(conn)
    rows = await conn.fetch(
        "SELECT user_id, song_id, edition_id FROM edition_preference"
    )
    assert [tuple(r) for r in rows] == [(U1, num(3), first)]
    assert counts["merged"] == 2


# --- split ---------------------------------------------------------------


async def test_split_number_stays_with_the_song_that_has_more_of_its_recordings(
    conn,
) -> None:
    await old(conn, 1, 1, (1, 2, 3))
    await new(conn, 10, 5, (1,))
    await new(conn, 20, 6, (2, 3))
    counts = await run(conn)
    assert await number_of(conn, 20) == num(1)
    other = await number_of(conn, 10)
    assert other is not None and other != num(1)
    assert counts == {"songs": 2, "kept": 1, "new": 0, "split": 1, "merged": 0}


async def test_split_tie_goes_to_the_song_with_the_numbers_key(conn) -> None:
    await old(conn, 1, 6, (1, 2))
    await new(conn, 10, 5, (1,))
    await new(conn, 20, 6, (2,))
    await run(conn)
    assert await number_of(conn, 20) == num(1)


async def test_split_tie_without_key_goes_to_the_lower_song_row(conn) -> None:
    await old(conn, 1, 9, (1, 2))
    await new(conn, 20, 6, (2,))
    await new(conn, 10, 5, (1,))
    await run(conn)
    assert await number_of(conn, 10) == num(1)


async def test_split_recordings_follow_their_new_songs(conn) -> None:
    await old(conn, 1, 1, (1, 2, 3))
    await new(conn, 10, 5, (1,))
    await new(conn, 20, 6, (2, 3))
    await run(conn)
    assert await conn.fetchval(
        "SELECT song_id FROM song_alias WHERE old_track_id = $1", rec(1)
    ) == await number_of(conn, 10)
    assert await conn.fetchval(
        "SELECT song_id FROM song_alias WHERE old_track_id = $1", rec(2)
    ) == num(1)


async def test_song_that_lost_one_number_keeps_another_it_won(conn) -> None:
    await old(conn, 1, 8, (1, 2, 3, 4))
    await old(conn, 2, 9, (5,))
    await new(conn, 10, 5, (1, 2, 3))
    await new(conn, 20, 6, (4, 5))
    counts = await run(conn)
    assert await number_of(conn, 10) == num(1)
    assert await number_of(conn, 20) == num(2)
    assert counts["split"] == 0 and counts["merged"] == 0


# --- keys change hands ------------------------------------------------------


async def test_two_numbers_swap_keys(conn) -> None:
    await old(conn, 1, 1, (1,), v3=10)
    await old(conn, 2, 2, (2,), v3=20)
    await new(conn, 10, 2, (1,))
    await new(conn, 20, 1, (2,))
    await run(conn)
    assert await number_of(conn, 10) == num(1)
    assert await number_of(conn, 20) == num(2)
    assert await conn.fetchval(
        "SELECT identity_key FROM song_identity WHERE song_id = $1", num(1)
    ) == key(2)


async def test_song_rows_swap_between_numbers(conn) -> None:
    await old(conn, 1, 1, (1,), v3=20)
    await old(conn, 2, 2, (2,), v3=10)
    await new(conn, 10, 1, (1,))
    await new(conn, 20, 2, (2,))
    await run(conn)
    assert await number_of(conn, 10) == num(1)
    assert await number_of(conn, 20) == num(2)


async def test_number_without_a_song_in_the_new_dump_is_left_alone(conn) -> None:
    await old(conn, 1, 1, (1,), v3=10)
    await old(conn, 2, 2, (2,), v3=20)
    await new(conn, 10, 1, (1,))
    await run(conn)
    row = await conn.fetchrow(
        "SELECT identity_key, v3_song_id FROM song_identity WHERE song_id = $1", num(2)
    )
    assert tuple(row) == (key(2), None)
    assert await conn.fetchval(
        "SELECT song_id FROM song_alias WHERE old_track_id = $1", rec(2)
    ) == num(2)


# --- canonical aliases, one song, broken build ------------------------------


async def test_canonical_alias_is_written_for_each_recording_title(conn) -> None:
    await new(conn, 10, 1, (1,), title="Enter Sandman")
    await run(conn)
    assert await conn.fetchval(
        "SELECT song_id FROM song_alias WHERE old_canonical_key = 'band|enter sandman 1'"
    ) == await number_of(conn, 10)


async def test_canonical_alias_shared_by_two_songs_is_not_written(conn) -> None:
    await new(conn, 10, 1, (1,), title="Same")
    await new(conn, 20, 2, (2,), title="Same")
    await conn.execute("UPDATE mb_recording SET title = 'Same'")
    await run(conn)
    assert (
        await conn.fetchval(
            "SELECT count(*) FROM song_alias WHERE old_canonical_key IS NOT NULL"
        )
        == 0
    )


async def test_one_song_mode_touches_only_that_song(conn) -> None:
    await old(conn, 1, 1, (1,), v3=10)
    await new(conn, 10, 1, (1,))
    await new(conn, 20, 2, (2,))
    counts = await run(conn, only=20)
    assert counts == {"songs": 1, "kept": 0, "new": 1, "split": 0, "merged": 0}
    assert await number_of(conn, 10) == num(1)
    assert await number_of(conn, 20) not in (None, num(1))


async def test_one_song_mode_finds_the_old_number(conn) -> None:
    await old(conn, 1, 1, (1,), v3=10)
    await old(conn, 2, 2, (2,))
    await new(conn, 10, 1, (1,))
    await new(conn, 20, 2, (2,))
    await run(conn, only=20)
    assert await number_of(conn, 20) == num(2)
    assert await number_of(conn, 10) == num(1)


async def test_one_song_mode_does_not_take_a_number_from_a_live_song(conn) -> None:
    await old(conn, 1, 1, (1, 2), v3=10)
    await new(conn, 10, 1, (1,))
    await new(conn, 20, 2, (2,))
    counts = await run(conn, only=20)
    assert await number_of(conn, 10) == num(1)
    assert await number_of(conn, 20) not in (None, num(1))
    assert counts == {"songs": 1, "kept": 0, "new": 1, "split": 0, "merged": 0}
    assert await conn.fetchval(
        "SELECT song_id FROM song_alias WHERE old_track_id = $1", rec(1)
    ) == num(1)


async def test_one_song_mode_takes_a_number_no_live_song_holds(conn) -> None:
    await old(conn, 1, 9, (1, 2))
    await new(conn, 20, 2, (2,))
    await run(conn, only=20)
    assert await number_of(conn, 20) == num(1)


async def test_one_song_mode_refuses_a_key_held_by_a_live_song(conn) -> None:
    await old(conn, 1, 2, (1,), v3=10)
    await new(conn, 20, 2, (2,))
    before = await state(conn)
    with pytest.raises(IdentityConflict):
        await run(conn, only=20)
    assert await state(conn) == before


async def test_one_song_mode_repeats_for_a_song_that_has_its_number(conn) -> None:
    await old(conn, 1, 2, (2,), v3=20)
    await new(conn, 20, 2, (2,))
    before = await state(conn)
    counts = await run(conn, only=20)
    assert counts == {"songs": 1, "kept": 1, "new": 0, "split": 0, "merged": 0}
    assert await number_of(conn, 20) == num(1)
    assert [row for row in await state(conn) if row[1] != "band|song 2"] == before


async def test_one_song_mode_retires_a_key_owner_that_has_no_song(conn) -> None:
    await old(conn, 1, 2)
    await old(conn, 2, 9, (2,))
    await new(conn, 20, 2, (2,))
    counts = await run(conn, only=20)
    assert await number_of(conn, 20) == num(2)
    assert counts["merged"] == 1
    assert (
        await conn.fetchval(
            "SELECT identity_key FROM song_identity WHERE song_id = $1", num(1)
        )
        == f"retired:{num(1)}"
    )


async def test_two_songs_with_one_key_are_refused(conn) -> None:
    await old(conn, 1, 1, (1,), v3=10)
    await new(conn, 10, 1, (1,))
    await conn.execute(
        "ALTER TABLE song DROP CONSTRAINT IF EXISTS song_artist_mbid_work_mbid_key"
    )
    try:
        await conn.execute(
            "INSERT INTO song (id, artist_mbid, title, work_mbid, original_recording_mbid, original_year) "
            "VALUES (20, $1, 'Song', $2, $3, 1991)",
            ARTIST,
            work(1),
            rec(1),
        )
    except asyncpg.UniqueViolationError:
        pytest.skip("the song table itself refuses two songs with one key")
    before = await state(conn)
    with pytest.raises(IdentityConflict):
        await run(conn)
    assert await state(conn) == before


async def test_work_runs_inside_the_callers_transaction(conn) -> None:
    await old(conn, 1, 1, (1,))
    await old(conn, 2, 2, (2, 3))
    await new(conn, 10, 1, (1, 2, 3))
    before = await state(conn)
    tx = conn.transaction()
    await tx.start()
    await assign(conn)
    await tx.rollback()
    assert await state(conn) == before
