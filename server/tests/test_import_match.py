"""Import rows -> songs of own catalog (P5, step 3; R-A47, R-A48).

Confident — by ISRC or exact "artist + title"; otherwise doubtful
(up to three variants) or "not found". Own database only: MusicBrainz replica and
own releases list, no external requests. 2000 rows — in a batch rather than
per-row query: number of database queries is almost independent of the row count.
"""

from __future__ import annotations

import asyncio
import logging
import time
from typing import Any
from uuid import UUID, uuid5

import asyncpg
import pytest

from app import search_indexes
from app.canonical import canonical_key
from app.import_formats import ImportRow
from app.import_match import match_rows
from app.main import TRACK_NAMESPACE
from app.migrate import apply

METALLICA, KINO, NIRVANA, NIRVANA_60S = (
    UUID(int=1),
    UUID(int=2),
    UUID(int=3),
    UUID(int=4),
)
SANDMAN, SANDMAN_LIVE, NOTHING_ELSE = UUID(int=101), UUID(int=102), UUID(int=103)
UNFORGIVEN = [UUID(int=104), UUID(int=105), UUID(int=106), UUID(int=107)]
BLOOD_TYPE, TEEN_SPIRIT, LITHIUM, LITHIUM_60S = (
    UUID(int=201),
    UUID(int=301),
    UUID(int=302),
    UUID(int=401),
)
SANDMAN_ISRC = "USEE19100001"

# (recording, artist, title, duration, kind, original_track)
RECORDINGS = [
    (SANDMAN, METALLICA, "Enter Sandman", 331_000, "original", SANDMAN),
    (SANDMAN_LIVE, METALLICA, "Enter Sandman", 345_000, "live", SANDMAN),
    (
        NOTHING_ELSE,
        METALLICA,
        "Nothing Else Matters",
        388_000,
        "original",
        NOTHING_ELSE,
    ),
    (UNFORGIVEN[0], METALLICA, "The Unforgiven", 387_000, "original", UNFORGIVEN[0]),
    (UNFORGIVEN[1], METALLICA, "The Unforgiven II", 396_000, "original", UNFORGIVEN[1]),
    (
        UNFORGIVEN[2],
        METALLICA,
        "The Unforgiven III",
        466_000,
        "original",
        UNFORGIVEN[2],
    ),
    (
        UNFORGIVEN[3],
        METALLICA,
        "The Unforgiven (Demo)",
        380_000,
        "original",
        UNFORGIVEN[3],
    ),
    (BLOOD_TYPE, KINO, "Группа крови", 286_000, "original", BLOOD_TYPE),
    (TEEN_SPIRIT, NIRVANA, "Smells Like Teen Spirit", 301_000, "original", TEEN_SPIRIT),
    (LITHIUM, NIRVANA, "Lithium", 257_000, "original", LITHIUM),
    (LITHIUM_60S, NIRVANA_60S, "Lithium", 190_000, "original", LITHIUM_60S),
]


async def _seed(url: str) -> None:
    await apply(url)
    conn = await asyncpg.connect(url)
    try:
        await conn.execute(
            "TRUNCATE song, song_version, mb_isrc, mb_recording, mb_artist, mb_artist_alias,"
            " catalog_tracks CASCADE"
        )
        await conn.executemany(
            "INSERT INTO mb_artist (mbid, name, sort_name, ended) VALUES ($1, $2, $2, false)",
            [
                (METALLICA, "Metallica"),
                (KINO, "Кино"),
                (NIRVANA, "Nirvana"),
                (NIRVANA_60S, "Nirvana"),
            ],
        )
        await conn.execute(
            "INSERT INTO mb_artist_alias (artist_mbid, name) VALUES ($1, 'Kino')", KINO
        )
        songs: dict[UUID, int] = {}
        for rec, artist, title, ms, kind, original in RECORDINGS:
            await conn.execute(
                "INSERT INTO mb_recording (mbid, artist_mbid, title, length_ms) VALUES ($1, $2, $3, $4)",
                rec,
                artist,
                title,
                ms,
            )
            if original not in songs:
                songs[original] = await conn.fetchval(
                    "INSERT INTO song (artist_mbid, title, original_recording_mbid)"
                    " VALUES ($1, $2, $3) RETURNING id",
                    artist,
                    title,
                    original,
                )
            await conn.execute(
                "INSERT INTO song_version (song_id, recording_mbid, kind) VALUES ($1, $2, $3)",
                songs[original],
                rec,
                kind,
            )
        # Live recording ISRC: song is the same, id is that of original, like search.
        await conn.execute(
            "INSERT INTO mb_isrc (recording_mbid, isrc) VALUES ($1, $2)",
            SANDMAN_LIVE,
            SANDMAN_ISRC,
        )
        # Song only from own releases list: not in MusicBrainz replica.
        await conn.execute(
            "INSERT INTO catalog_tracks (artist_key, title_key, artist, title, weight)"
            " VALUES ('ддт', 'осень', 'ДДТ', 'Осень', 10)"
        )
    finally:
        await conn.close()


@pytest.fixture
def catalog_db(postgres_url: str) -> str:
    asyncio.run(_seed(postgres_url))
    return postgres_url


class CountingConnection:
    """Counts database queries: in a batch rather than per-row."""

    def __init__(self, conn: asyncpg.Connection) -> None:
        self._conn, self.calls = conn, 0

    def __getattr__(self, name: str) -> Any:
        attr = getattr(self._conn, name)
        if name in {"fetch", "fetchrow", "fetchval", "execute", "executemany"}:

            async def counted(*args: Any, **kwargs: Any) -> Any:
                self.calls += 1
                return await attr(*args, **kwargs)

            return counted
        return attr


def _match(url: str, rows: list[ImportRow]) -> tuple[list[Any], int]:
    async def run() -> tuple[list[Any], int]:
        conn = await asyncpg.connect(url)
        try:
            counting = CountingConnection(conn)
            return await match_rows(counting, rows), counting.calls
        finally:
            await conn.close()

    return asyncio.run(run())


def _own_id(artist: str, title: str) -> str:
    return str(uuid5(TRACK_NAMESPACE, canonical_key(artist, title)))


ROWS = [
    ImportRow(
        "Metallica", "Enter Sandman (Live)", isrc=SANDMAN_ISRC.lower()
    ),  # 0: ISRC takes precedence over title
    ImportRow("metallica", "NOTHING ELSE MATTERS"),  # 1: case
    ImportRow(
        "Metallica", "Nothing Else Matters - Remastered 2021"
    ),  # 2: Spotify suffix
    ImportRow("Metallica", "Enter Sandman (feat. Someone)"),  # 3: featured artist in parentheses
    ImportRow("Kino", "Группа крови"),  # 4: artist name in Latin — alias
    ImportRow("Nirvana", "Smells Like Teen Spirit"),  # 5
    ImportRow("Nirvana", "Lithium"),  # 6: two Nirvanas — doubtful
    ImportRow("Metallica", "Unforgiven"),  # 7: similar — doubtful
    ImportRow("ДДТ", "Осень"),  # 8: own releases list only
    ImportRow("", "Осень"),  # 9: row without artist
    ImportRow("Nobody Band", "No Such Song"),  # 10
    ImportRow(
        "Metallica", "Enter Sandman", isrc="XX0000000000"
    ),  # 11: foreign ISRC — by title
    ImportRow(
        "Metallica", "Enter Sandman - Live at Wembley"
    ),  # 12: live is not studio
]


def test_each_row_is_found_doubtful_or_missing_in_order(catalog_db: str) -> None:
    result, _calls = _match(catalog_db, ROWS)
    assert len(result) == len(ROWS)
    statuses = [m.status for m in result]
    assert statuses[:6] == ["found"] * 6
    assert statuses[6:8] == ["doubtful", "doubtful"]
    assert statuses[8] == "found"
    assert statuses[9] == "doubtful"
    assert statuses[10] == "missing"
    assert statuses[11] == "found"
    assert statuses[12] != "found"

    ids = [m.track["id"] if m.track else None for m in result]
    assert ids[0] == str(SANDMAN)  # live recording by ISRC -> original song id
    assert ids[1] == ids[2] == str(NOTHING_ELSE)
    assert ids[3] == ids[11] == str(SANDMAN)
    assert ids[4] == str(BLOOD_TYPE)
    assert ids[5] == str(TEEN_SPIRIT)
    assert ids[8] == _own_id("ДДТ", "Осень")
    assert ids[10] is None and result[10].candidates == []


def test_found_track_is_a_song_card_from_the_catalog(catalog_db: str) -> None:
    result, _calls = _match(catalog_db, ROWS[:1] + ROWS[8:9])
    sandman, autumn = result[0].track, result[1].track
    assert sandman == {
        "id": str(SANDMAN),
        "title": "Enter Sandman",
        "artist": "Metallica",
        "duration_ms": 331_000,
        "artwork_url": "",
    }
    assert autumn == {
        "id": _own_id("ДДТ", "Осень"),
        "title": "Осень",
        "artist": "ДДТ",
        "duration_ms": 0,
        "artwork_url": "",
    }
    assert result[0].candidates == [] and result[1].candidates == []


def test_doubtful_rows_offer_at_most_three_and_the_first_is_the_pick(
    catalog_db: str,
) -> None:
    result, _calls = _match(catalog_db, ROWS)
    lithium, unforgiven, no_artist = result[6], result[7], result[9]

    assert {c["id"] for c in lithium.candidates} == {str(LITHIUM), str(LITHIUM_60S)}
    assert 1 <= len(unforgiven.candidates) <= 3
    assert all("Unforgiven" in c["title"] for c in unforgiven.candidates)
    assert [c["artist"] for c in no_artist.candidates] == ["ДДТ"]
    for doubtful in (lithium, unforgiven, no_artist):
        assert doubtful.track == doubtful.candidates[0]
        assert set(doubtful.track) == {
            "id",
            "title",
            "artist",
            "duration_ms",
            "artwork_url",
        }


def test_two_thousand_rows_are_a_batch_not_a_query_each(catalog_db: str) -> None:
    _small, small_calls = _match(catalog_db, ROWS)
    big = [ROWS[n % len(ROWS)] for n in range(2000)]
    started = time.perf_counter()
    result, big_calls = _match(catalog_db, big)
    elapsed = time.perf_counter() - started

    assert [m.status for m in result[: len(ROWS)]] == [m.status for m in _small]
    assert small_calls <= 12, small_calls
    assert big_calls <= 4 * small_calls, (small_calls, big_calls)
    assert elapsed < 3.0, elapsed


def test_empty_list_and_no_titles_in_the_log(
    catalog_db: str, caplog: pytest.LogCaptureFixture
) -> None:
    caplog.set_level(logging.DEBUG)
    assert _match(catalog_db, [])[0] == []
    _match(catalog_db, ROWS)
    text = caplog.text.casefold()
    for secret in (
        "sandman",
        "lithium",
        "unforgiven",
        "осень",
        "группа крови",
        "nobody band",
    ):
        assert secret not in text, secret


def test_isrc_lookup_has_an_index_on_the_live_copy(catalog_db: str) -> None:
    # Without index on isrc, lookup across 6.4M rows of prod mb_isrc would be full scan on each batch.
    assert ("mb_isrc_new_isrc", "mb_isrc", "isrc") in search_indexes.MB_INDEXES

    async def run() -> list[str]:
        conn = await asyncpg.connect(catalog_db)
        try:
            await search_indexes.ensure(conn)
            rows = await conn.fetch(
                "SELECT indexname FROM pg_indexes WHERE tablename = 'mb_isrc'"
            )
            return [row["indexname"] for row in rows]
        finally:
            await conn.close()

    assert "mb_isrc_new_isrc" in asyncio.run(run())
