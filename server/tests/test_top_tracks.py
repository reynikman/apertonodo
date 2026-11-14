"""Popular tracks on artist page: top tracks get their studio recording IDs (p4-fixes, A).

Owner 02.10: Faint, "Attack of the Dead Men", Can't Help Falling in Love, Lose Yourself — no duration, Play
leads to search. Root causes found on production database:
- IDs were fetched by crawler on 21–22.09 and are not recalculated: today the same titles are found, but
  `lastfm_artists.top_track_ids` does not have them; page re-searches only titles with "Remaster" suffix;
- the longest recording was chosen among song recordings, but recording with unknown duration (NULL) comes first on DESC:
  Lose Yourself and Can't Help Falling in Love received recording with duration 0, "Ekspanat" — 7-minute one;
- apostrophe: Last.fm writes "Can't", MusicBrainz — "Can’t".
"""

from __future__ import annotations

import json
from typing import Any
from uuid import UUID

import asyncpg
import pytest

import app.local_search as local_search
from app import lastfm
from app.names import norm
from tests.test_local_search import cleanup_db  # noqa: F401 — cleans catalog tables before and after


async def _artist(conn: asyncpg.Connection, name: str) -> UUID:
    return await conn.fetchval(
        "INSERT INTO mb_artist (mbid, name, sort_name, ended) VALUES (gen_random_uuid(), $1, $1, false) RETURNING mbid",
        name,
    )


async def _rec(conn: asyncpg.Connection, artist: UUID, title: str, length_ms: int | None) -> UUID:
    return await conn.fetchval(
        "INSERT INTO mb_recording (mbid, artist_mbid, title, length_ms) VALUES (gen_random_uuid(), $1, $2, $3) RETURNING mbid",
        artist, title, length_ms,
    )


async def _song(conn: asyncpg.Connection, artist: UUID, title: str, original: UUID, versions: dict[UUID, str]) -> None:
    song = await conn.fetchval(
        "INSERT INTO song (artist_mbid, title, original_recording_mbid) VALUES ($1, $2, $3) RETURNING id",
        artist, title, original,
    )
    for rec, kind in versions.items():
        await conn.execute(
            "INSERT INTO song_version (song_id, recording_mbid, kind, year) VALUES ($1, $2, $3, 2000)", song, rec, kind
        )


async def _studio(conn: asyncpg.Connection, artist: UUID, title: str, length_ms: int) -> UUID:
    rec = await _rec(conn, artist, title, length_ms)
    await _song(conn, artist, title, rec, {rec: "original"})
    return rec


async def test_top_track_is_the_song_original_not_the_longest_nor_unknown_length(postgres_url: str) -> None:
    conn = await asyncpg.connect(postgres_url)
    try:
        art = await _artist(conn, "Ленинград")
        studio = await _rec(conn, art, "Экспонат", 230000)
        longer = await _rec(conn, art, "Экспонат", 418000)
        unknown = await _rec(conn, art, "Экспонат", None)
        await _song(conn, art, "Экспонат", studio, {studio: "original", longer: "original", unknown: "original"})
        assert await local_search.top_track_ids(conn, "Ленинград", ["Экспонат"]) == {
            "экспонат": {"id": str(studio), "duration_ms": 230000}
        }
    finally:
        await conn.close()


async def test_without_the_song_original_a_known_length_beats_an_unknown_one(postgres_url: str) -> None:
    """Song original is recorded under a different title — matched recording with known duration is picked."""
    conn = await asyncpg.connect(postgres_url)
    try:
        art = await _artist(conn, "Eminem")
        film = await _rec(conn, art, "Lose Yourself (soundtrack version)", 326000)
        unknown = await _rec(conn, art, "Lose Yourself", None)
        album = await _rec(conn, art, "Lose Yourself", 322000)
        await _song(conn, art, "Lose Yourself", film, {film: "original", unknown: "original", album: "original"})
        assert await local_search.top_track_ids(conn, "Eminem", ["Lose Yourself"]) == {
            "lose yourself": {"id": str(album), "duration_ms": 322000}
        }
    finally:
        await conn.close()


async def test_typographic_and_plain_apostrophes_are_one_title(postgres_url: str) -> None:
    conn = await asyncpg.connect(postgres_url)
    try:
        art = await _artist(conn, "Elvis Presley")
        curly = await _studio(conn, art, "Can’t Help Falling in Love", 182000)
        plain = await _studio(conn, art, "Don't Be Cruel", 124000)
        assert await local_search.top_track_ids(
            conn, "Elvis Presley", ["Can't Help Falling in Love", "Don’t Be Cruel"]
        ) == {
            norm("Can't Help Falling in Love"): {"id": str(curly), "duration_ms": 182000},
            norm("Don’t Be Cruel"): {"id": str(plain), "duration_ms": 124000},
        }
    finally:
        await conn.close()


def _rows(block: dict[str, Any]) -> list[tuple[str, Any, Any]]:
    return [(row["title"], row.get("id"), row.get("duration_ms")) for row in block["top_tracks"]]


async def test_row_saved_under_the_old_rule_heals_once_on_the_page(
    postgres_url: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Crawler row from 21.09: Faint without ID, Numb — with unknown duration recording. First page opening
    will search and fix; second does not query catalog, including for songs missing from catalog."""
    conn = await asyncpg.connect(postgres_url)
    try:
        await conn.execute(
            "INSERT INTO mb_loads (dump_date, replication_sequence, row_counts, duration_ms, tablespace, size_bytes) "
            "VALUES ('2026-09-19', 189107, '{}'::jsonb, 100, 'pg_default', 1000) ON CONFLICT DO NOTHING"
        )
        art = await _artist(conn, "Linkin Park")
        numb_unknown = await _rec(conn, art, "Numb", None)
        numb = await _rec(conn, art, "Numb", 187520)
        await _song(conn, art, "Numb", numb, {numb: "original", numb_unknown: "original"})
        faint = await _studio(conn, art, "Faint", 162106)
        await conn.execute(
            "INSERT INTO lastfm_artists (artist_key, found, bio, top_tracks, similar_artists, listeners, "
            "top_track_ids, tags, fetched_at) VALUES ('linkin park', true, 'Bio.', $1, '{}', 1000, $2::jsonb, '{}', "
            "now() - interval '11 days')",
            ["Numb", "Faint", "Somebody Else’s Hit"],
            json.dumps({"numb": {"id": str(numb_unknown), "duration_ms": 0}}),
        )

        first = await lastfm.blocks(conn, "Linkin Park")
        assert _rows(first) == [
            ("Numb", str(numb), 187520),
            ("Faint", str(faint), 162106),
            ("Somebody Else’s Hit", None, None),
        ]

        async def no_lookup(*_args: Any, **_kwargs: Any) -> dict[str, Any]:
            raise AssertionError("IDs already found under new rule — page does not search them a second time")

        monkeypatch.setattr(local_search, "top_track_ids", no_lookup)
        assert _rows(await lastfm.blocks(conn, "Linkin Park")) == _rows(first)
    finally:
        await conn.close()


async def test_row_written_by_the_robot_today_is_not_searched_again(
    postgres_url: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Fresh crawler row already under new rule: page does not search even tracks without ID (cover, someone else's)."""
    import httpx

    from app.lastfm import LastFm

    conn = await asyncpg.connect(postgres_url)
    try:
        await conn.execute(
            "INSERT INTO mb_loads (dump_date, replication_sequence, row_counts, duration_ms, tablespace, size_bytes) "
            "VALUES ('2026-09-19', 189107, '{}'::jsonb, 100, 'pg_default', 1000) ON CONFLICT DO NOTHING"
        )
        art = await _artist(conn, "Metallica")
        sandman = await _studio(conn, art, "Enter Sandman", 331000)
        await conn.execute(
            "INSERT INTO catalog_artists (genre, artist_key, name, letter, popularity) "
            "VALUES ('metal', 'metallica', 'Metallica', 'M', 500) ON CONFLICT DO NOTHING"
        )
    finally:
        await conn.close()

    def lastfm_client() -> httpx.Client:
        def answer(request: httpx.Request) -> httpx.Response:
            method = request.url.params.get("method")
            if method == "artist.getinfo":
                return httpx.Response(200, json={"artist": {"name": "Metallica", "stats": {"listeners": "5"},
                                                            "bio": {"summary": "Metal."}, "tags": {"tag": []}}})
            if method == "artist.gettoptracks":
                names = ["Enter Sandman", "Turn the Page"]
                return httpx.Response(200, json={"toptracks": {"track": [{"name": n} for n in names]}})
            return httpx.Response(200, json={})

        return httpx.Client(transport=httpx.MockTransport(answer))

    robot = LastFm(api_key="test-key", database_url=postgres_url, client=lastfm_client, pause_s=0, limit=5)
    assert (await robot.crawl())[0] >= 1

    async def no_lookup(*_args: Any, **_kwargs: Any) -> dict[str, Any]:
        raise AssertionError("row fetched by crawler under new rule — page does not search IDs")

    monkeypatch.setattr(local_search, "top_track_ids", no_lookup)
    conn = await asyncpg.connect(postgres_url)
    try:
        assert _rows(await lastfm.blocks(conn, "Metallica")) == [
            ("Enter Sandman", str(sandman), 331000),
            ("Turn the Page", None, None),
        ]
    finally:
        await conn.close()
