"""One slow artist does not crash the song list build (FT-511).

Production, 01.10 and 02.10.2026: `python -m app.catalog build` failed twice in a row
in `build_tracks` with TimeoutError — live release check (`playable`) for one
artist exceeded PLAYABLE_TIMEOUT_S, and the entire song build was aborted.
Search was answering from the old `catalog_tracks`, new songs did not get
in there. Rule: an artist whose check timed out keeps their songs
from the previous list; the rest are built as usual; the log contains the count
of such artists, without names.
"""

from __future__ import annotations

import asyncio
import logging

import asyncpg
import pytest
from test_search_own import filled  # noqa: F401 — fixture

from app import catalog

SLOW = "Linkin Park"


async def _songs(url: str) -> set[tuple[str, str]]:
    conn = await asyncpg.connect(url)
    try:
        rows = await conn.fetch("SELECT artist, title_key FROM catalog_tracks")
    finally:
        await conn.close()
    return {(row["artist"], row["title_key"]) for row in rows}


def _slow(monkeypatch: pytest.MonkeyPatch) -> None:
    real = catalog.playable

    async def playable(conn: asyncpg.Connection, artist: str, titles: list[str]) -> list[bool]:
        if artist == SLOW:
            raise asyncio.TimeoutError
        return await real(conn, artist, titles)

    monkeypatch.setattr(catalog, "playable", playable)


async def test_slow_artist_keeps_old_songs_and_build_finishes(
    filled: str, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture  # noqa: F811
) -> None:
    before = await _songs(filled)
    assert (SLOW, "numb") in before
    _slow(monkeypatch)
    with caplog.at_level(logging.INFO):
        count = await catalog.build_tracks(filled)
    after = await _songs(filled)
    assert after == before
    assert count == len(after)
    assert any("timed out" in record.getMessage() for record in caplog.records)
    assert not any(SLOW.lower() in record.getMessage().lower() for record in caplog.records)


async def test_slow_artist_without_old_songs_is_just_skipped(
    filled: str, monkeypatch: pytest.MonkeyPatch  # noqa: F811
) -> None:
    conn = await asyncpg.connect(filled)
    try:
        await conn.execute("DELETE FROM catalog_tracks WHERE artist = $1", SLOW)
    finally:
        await conn.close()
    _slow(monkeypatch)
    await catalog.build_tracks(filled)
    after = await _songs(filled)
    assert not any(artist == SLOW for artist, _title in after)
    assert ("Metallica", "enter sandman") in after
