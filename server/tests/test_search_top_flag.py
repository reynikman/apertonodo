"""FT-877: the "top track" flag in SEARCH_CANDIDATES_SQL.artist_songs.

The flag is read from lastfm_artists.top_track_ids (jsonb array of recording
uuids). It used to be computed as `top_track_ids::text LIKE '%mbid%'` for every
song, i.e. a 4 KB jsonb -> text conversion per song: 1.2 s for 12k songs.
These tests pin the behaviour (which songs are top, in which order, no errors on
odd jsonb) and, separately, that the cost no longer grows with the song count.
"""

from __future__ import annotations

import json
import time
from typing import Any
from uuid import UUID

import asyncpg
import pytest

import app.local_search as local_search
from app.migrate import apply

ARTIST = UUID(int=877)
NAME = "Ennio Morricone"


def rec(n: int) -> UUID:
    return UUID(int=0x877_0000 + n)


@pytest.fixture(autouse=True)
async def cleanup_db(postgres_url: str):
    await apply(postgres_url)
    for i in range(2):
        conn = await asyncpg.connect(postgres_url)
        try:
            await conn.execute("TRUNCATE mb_loads, artist_photos, song, mb_artist, lastfm_artists, catalog_artists CASCADE")
        finally:
            await conn.close()
        if i == 0:
            yield


@pytest.fixture
async def conn(postgres_url: str):
    c = await asyncpg.connect(postgres_url)
    try:
        yield c
    finally:
        await c.close()


def listing(entries: list[Any], shape: str) -> Any:
    """Build top_track_ids from uuid strings (or odd values) in the given shape.

    "object" is what app/lastfm.py really writes: {normalized title: {"id", "duration_ms"}, "$rule": n}.
    "array" is the shape the card describes (a plain list of uuids); the old LIKE accepted any shape,
    so the fixed query must too.
    """
    if shape == "array":
        return entries
    out: dict[str, Any] = {f"title {i}": ({"id": e, "duration_ms": 1000} if isinstance(e, str) else e) for i, e in enumerate(entries)}
    out["$rule"] = 3
    return out


SHAPES = pytest.mark.parametrize("shape", ["object", "array"])


async def seed(conn: asyncpg.Connection, songs: int, top: Any = ..., with_lastfm: bool = True) -> None:
    """One artist with `songs` songs; song n has recording rec(n), title 'Song n'.

    `top` is a python value stored as jsonb; `None` means SQL NULL, the default
    leaves the column unset (NULL as well).
    """
    await conn.execute("INSERT INTO mb_artist (mbid, name, sort_name, ended) VALUES ($1, $2, $2, false)", ARTIST, NAME)
    await conn.execute(
        "INSERT INTO song (artist_mbid, title, original_recording_mbid) "
        "SELECT $1, 'Song ' || g, ('00000000-0000-0000-0000-' || lpad((to_hex(x'8770000'::int + g)), 12, '0'))::uuid "
        "FROM generate_series(1, $2::int) g",
        ARTIST,
        songs,
    )
    if with_lastfm:
        value = None if top is ... or top is None else json.dumps(top)
        await conn.execute("INSERT INTO lastfm_artists (artist_key, found, top_track_ids) VALUES ($1, true, $2::jsonb)", NAME.lower(), value)


async def run_candidates(conn: asyncpg.Connection, query: str = "ennio morricone") -> list[asyncpg.Record]:
    low = query.lower()
    return await conn.fetch(local_search.SEARCH_CANDIDATES_SQL, low, f"{local_search._escape_like(low)}%", [], [])


async def top_titles(conn: asyncpg.Connection) -> set[str]:
    return {str(r["title"]) for r in await run_candidates(conn) if r["top"]}


@SHAPES
async def test_listed_songs_are_top_others_are_not(conn: asyncpg.Connection, shape: str) -> None:
    """Row 1 and 2: song from the Last.fm list -> top; song not in it -> not top."""
    await seed(conn, 6, listing([str(rec(2)), str(rec(5))], shape))
    rows = await run_candidates(conn)
    assert {r["title"]: r["top"] for r in rows} == {
        "Song 1": False, "Song 2": True, "Song 3": False, "Song 4": False, "Song 5": True, "Song 6": False,
    }


async def test_artist_without_lastfm_row_has_no_top(conn: asyncpg.Connection) -> None:
    """Row 3: no lastfm_artists row at all -> every flag is false, no error."""
    await seed(conn, 4, with_lastfm=False)
    rows = await run_candidates(conn)
    assert len(rows) == 4
    assert [r["top"] for r in rows] == [False] * 4


@pytest.mark.parametrize(
    "stored",
    [None, [], {}, "json-null", "text", 42, True, {"id": "x"}, [[]], [None], {"$rule": 3}, {"a": {}}, {"a": {"id": None}}, {"a": "text"}, {"a": {"id": 5}}],
    ids=["sql-null", "empty-array", "empty-object", "json-null", "string", "number", "bool", "object-id-key", "nested-empty", "array-of-null",
         "rule-only", "entry-empty", "entry-null-id", "entry-string", "entry-number-id"],
)
async def test_odd_top_track_ids_mean_no_top(conn: asyncpg.Connection, stored: Any) -> None:
    """Row 4: empty / null / not-an-array value -> false everywhere, no error."""
    await seed(conn, 3)
    value = "null" if stored == "json-null" else (None if stored is None else json.dumps(stored))
    await conn.execute("UPDATE lastfm_artists SET top_track_ids = $1::jsonb WHERE artist_key = $2", value, NAME.lower())
    rows = await run_candidates(conn)
    assert len(rows) == 3
    assert [r["top"] for r in rows] == [False] * 3


@SHAPES
async def test_non_uuid_entries_do_not_break_the_rest(conn: asyncpg.Connection, shape: str) -> None:
    """Row 5: garbage next to real uuids -> the real ones still match, query survives."""
    garbage = ["not-a-uuid", "", 123, None, {"a": 1}, ["x"], "0000000-0000-0000-0000-000000000001", "zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz"]
    await seed(conn, 5, listing([garbage[0], str(rec(2)), *garbage[1:], str(rec(4))], shape))
    assert await top_titles(conn) == {"Song 2", "Song 4"}


@SHAPES
async def test_uuid_embedded_in_longer_value_is_not_an_exact_match(conn: asyncpg.Connection, shape: str) -> None:
    """Row 6: a list value that merely contains a song's uuid as a substring.

    The old LIKE counted it as top. The card allows either answer here, so only
    what must hold either way is pinned: no error, and the song whose uuid is
    listed exactly is still top.
    """
    await seed(conn, 4, listing([f"x{rec(1)}y", str(rec(3))], shape))
    assert "Song 3" in await top_titles(conn)


@SHAPES
async def test_order_and_selection_of_search_results(conn: asyncpg.Connection, shape: str) -> None:
    """Row 8: 40 songs, top ones are the LAST ids. Candidates keep 20 songs per
    artist, top first then by id; search puts the top songs first."""
    await seed(conn, 40, listing([str(rec(38)), str(rec(40)), str(rec(39))], shape))
    rows = await run_candidates(conn)
    assert len(rows) == 20
    assert sorted(r["title"] for r in rows if r["top"]) == ["Song 38", "Song 39", "Song 40"]
    assert {r["title"] for r in rows} == {"Song 38", "Song 39", "Song 40", *(f"Song {n}" for n in range(1, 18))}

    found = await local_search.search(conn, "ennio morricone", limit=20)
    titles = [r["title"] for r in found]
    assert titles[:3] == ["Song 38", "Song 39", "Song 40"]
    assert titles[3:] == [f"Song {n}" for n in range(1, 18)]


async def test_cost_does_not_grow_with_song_count(conn: asyncpg.Connection) -> None:
    """Row 7: 5000 songs and 100 listed uuids in the real object shape (~6 KB of jsonb).

    Time is compared against the old formula run on the same database, same rows,
    in the same connection: it converts jsonb to text for each of the 5000 songs.
    The fixed query must take under a third of that (measured: well under a
    tenth), best of 3 runs each, so one slow run does not flip the result.
    Correctness is checked first, so a fast-but-wrong query cannot pass.
    """
    await seed(conn, 5000, listing([str(rec(n)) for n in range(4901, 5001)], "object"))
    rows = await run_candidates(conn)
    assert len(rows) == 20
    assert all(r["top"] for r in rows), "the 20 kept songs must be the listed ones, not the lowest ids"

    old_formula = (
        "SELECT count(*) FROM song s JOIN lastfm_artists la ON la.artist_key = $2 "
        "WHERE s.artist_mbid = $1 AND la.top_track_ids::text LIKE ('%' || s.original_recording_mbid::text || '%')"
    )

    async def best(run: Any) -> float:
        times = []
        for _ in range(3):
            started = time.perf_counter()
            await run()
            times.append(time.perf_counter() - started)
        return min(times)

    old = await best(lambda: conn.fetchval(old_formula, ARTIST, NAME.lower()))
    new = await best(lambda: run_candidates(conn))
    assert new < old / 3, f"search candidates took {new * 1000:.0f} ms, the per-row jsonb->text formula {old * 1000:.0f} ms"
