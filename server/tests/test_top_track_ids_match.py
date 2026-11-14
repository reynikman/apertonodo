"""FT-866: a popular song the server calls playable must carry a recording id.

Found on the library walk of 13.10 (97 490 songs, 16 783 artists): Last.fm spells a title one way and the
MusicBrainz copy another, so the id is not found and the app sends the tap to search. Causes seen on production:
- punctuation: comma, space before `?`, acute accent instead of an apostrophe, `N'` against `'n`;
- `Pt. 2` against `Part 2`;
- the edition written with a dash on one side and in brackets on the other, either way round;
- a movement number: Arabic `2.` on one side, Roman `II.` on the other (the same movement then shows twice);
- rows saved under the previous rule were never searched again.
"""

from __future__ import annotations

import json
from typing import Any

import asyncpg
import pytest

import app.local_search as local_search
from app import catalog, lastfm
from app.names import norm
from tests.test_local_search import cleanup_db  # noqa: F401 — cleans the catalog tables before and after
from tests.test_top_tracks import _artist, _rows, _studio


async def _ids(conn: asyncpg.Connection, artist: str, titles: list[str]) -> dict[str, str]:
    found = await local_search.top_track_ids(conn, artist, titles)
    return {key: value["id"] for key, value in found.items()}


@pytest.mark.parametrize(
    ("asked", "stored"),
    [
        ("Later Won´t Wait", "Later Won’t Wait"),
        ("Who Is She ?", "Who Is She?"),
        ("Hurrah Hurrah Apocalypse", "Hurrah, Hurrah Apocalypse"),
        ("Room of velvet splendour Pt. 2", "Room of Velvet Splendour, Part 2"),
        ("Living N' Tha Streetz", "Living 'n tha Streetz"),
        ("El Ninio (Alchemist Project Remix)", "El Ninio - Alchemist Project Remix"),
        ("Qidar Feat. Soul Clan", "Qidar (feat. Soul Clan)"),
    ],
)
async def test_title_spelled_with_other_punctuation_gets_the_recording(
    postgres_url: str, asked: str, stored: str
) -> None:
    conn = await asyncpg.connect(postgres_url)
    try:
        art = await _artist(conn, "Some Band")
        rec = await _studio(conn, art, stored, 200000)
        assert await _ids(conn, "Some Band", [asked]) == {norm(asked): str(rec)}
    finally:
        await conn.close()


async def test_movement_number_in_roman_and_arabic_is_one_movement(postgres_url: str) -> None:
    conn = await asyncpg.connect(postgres_url)
    try:
        art = await _artist(conn, "Sergei Rachmaninov")
        rec = await _studio(conn, art, "Piano Concerto No. 2 in C minor, Op. 18: II. Adagio sostenuto", 600000)
        arabic = "Piano Concerto No. 2 in C minor, Op. 18: 2. Adagio sostenuto"
        assert await _ids(conn, "Sergei Rachmaninov", [arabic]) == {norm(arabic): str(rec)}
        # and the other way round
        art2 = await _artist(conn, "Another Pianist")
        rec2 = await _studio(conn, art2, "Concerto: 3. Allegro", 300000)
        roman = "Concerto: III. Allegro"
        assert await _ids(conn, "Another Pianist", [roman]) == {norm(roman): str(rec2)}
    finally:
        await conn.close()


async def test_loose_match_never_turns_a_studio_title_into_a_version(postgres_url: str) -> None:
    """«Love Is Magic» must not take the radio edit or the remix; «Reverie» stays «Reverie»."""
    conn = await asyncpg.connect(postgres_url)
    try:
        art = await _artist(conn, "Loft")
        radio = await _studio(conn, art, "Love Is Magic (Radio Edit)", 200000)
        await _studio(conn, art, "Love Is Magic (Club Remix)", 300000)
        assert await _ids(conn, "Loft", ["Love Is Magic", "Love Is Magic - Radio Edit"]) == {
            norm("Love Is Magic - Radio Edit"): str(radio)
        }
    finally:
        await conn.close()


async def test_exact_spelling_beats_the_loose_one(postgres_url: str) -> None:
    conn = await asyncpg.connect(postgres_url)
    try:
        art = await _artist(conn, "Some Band")
        await _studio(conn, art, "Hello, World", 100000)
        exact = await _studio(conn, art, "Hello World", 120000)
        assert await _ids(conn, "Some Band", ["Hello World"]) == {norm("Hello World"): str(exact)}
    finally:
        await conn.close()


class _Everything:
    """Extensions that call every title playable, like a rich source index."""

    async def playable(self, artist: str, titles: list[str]) -> list[bool]:
        return [True] * len(titles)

    async def pairs(self, pairs: list[tuple[str, str]]) -> list[bool]:
        return [True] * len(pairs)


async def _saved_row(conn: asyncpg.Connection, titles: list[str], ids: dict[str, Any]) -> None:
    await conn.execute(
        "INSERT INTO mb_loads (dump_date, replication_sequence, row_counts, duration_ms, tablespace, size_bytes) "
        "VALUES ('2026-09-19', 189107, '{}'::jsonb, 100, 'pg_default', 1000) ON CONFLICT DO NOTHING"
    )
    await conn.execute(
        "INSERT INTO lastfm_artists (artist_key, found, bio, top_tracks, similar_artists, listeners, "
        "top_track_ids, tags, fetched_at) VALUES ('some band', true, 'Bio.', $1, '{}', 1000, $2::jsonb, '{}', now())",
        titles,
        json.dumps(ids),
    )


async def test_song_without_a_recording_id_is_not_called_playable(
    postgres_url: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(catalog, "_extensions", _Everything())
    conn = await asyncpg.connect(postgres_url)
    try:
        art = await _artist(conn, "Some Band")
        known = await _studio(conn, art, "Known Song", 200000)
        await _saved_row(
            conn,
            ["Known Song", "Not In The Catalog"],
            {"$rule": lastfm.TOP_IDS_RULE, "known song": {"id": str(known), "duration_ms": 200000}},
        )
        block = await lastfm.blocks(conn, "Some Band")
        assert [(row["title"], row.get("id"), row["playable"]) for row in block["top_tracks"]] == [
            ("Known Song", str(known), True),
            ("Not In The Catalog", None, False),
        ]
        assert not any(row["playable"] and not row.get("id") for row in (await lastfm.songs(conn, "Some Band")))
    finally:
        await conn.close()


async def test_two_spellings_of_one_song_show_once(postgres_url: str, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(catalog, "_extensions", _Everything())
    conn = await asyncpg.connect(postgres_url)
    try:
        art = await _artist(conn, "Some Band")
        rec = await _studio(conn, art, "Concerto: II. Adagio", 600000)
        await _studio(conn, art, "Other Song", 100000)
        await _saved_row(conn, ["Concerto: 2. Adagio", "Concerto: II. Adagio", "Other Song"], {"$rule": 0})
        rows = _rows(await lastfm.blocks(conn, "Some Band"))
        assert [(title, id_) for title, id_, _ in rows][0] == ("Concerto: 2. Adagio", str(rec))
        assert [title for title, _, _ in rows] == ["Concerto: 2. Adagio", "Other Song"]
        assert [title for title, _, _ in _rows({"top_tracks": await lastfm.songs(conn, "Some Band")})] == [
            "Concerto: 2. Adagio",
            "Other Song",
        ]
    finally:
        await conn.close()


async def test_row_saved_under_the_previous_rule_is_searched_again(postgres_url: str) -> None:
    assert lastfm.TOP_IDS_RULE >= 4
    conn = await asyncpg.connect(postgres_url)
    try:
        art = await _artist(conn, "Some Band")
        rec = await _studio(conn, art, "Hurrah, Hurrah Apocalypse", 200000)
        await _saved_row(conn, ["Hurrah Hurrah Apocalypse"], {"$rule": 3})
        assert _rows(await lastfm.blocks(conn, "Some Band")) == [("Hurrah Hurrah Apocalypse", str(rec), 200000)]
    finally:
        await conn.close()
