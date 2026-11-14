"""Tracks in the artist's "Popular" section — with the cover of their own album (p4-fixes, B: 1).

Owner 02.10: in "Popular" each song has a letter instead of a cover, even though album covers are on the same page.
`lastfm.blocks` returns a top track with `artwork_url: ""`; the server knows the song's album from the MusicBrainz dump.
"""

from __future__ import annotations

import asyncio

import asyncpg
from fastapi.testclient import TestClient

from tests.test_catalog_browse import LOW_TIDE, SONGS, built, db  # noqa: F401
from tests.test_lastfm import _app_with, _robot, FakeLastFm, crawled  # noqa: F401


async def _cover(url: str, path: str | None) -> None:
    conn = await asyncpg.connect(url)
    try:
        await conn.execute(
            "INSERT INTO album_images (album_id, path) VALUES ($1::uuid, $2) "
            "ON CONFLICT (album_id) DO UPDATE SET path = EXCLUDED.path",
            LOW_TIDE, path,
        )
    finally:
        await conn.close()


def _top(url: str) -> dict[str, str]:
    with TestClient(_app_with(url, _robot(url, FakeLastFm()))) as client:
        body = client.get("/v1/artist", params={"name": "Glass Harbor"}).json()
    return {row["title"]: row.get("artwork_url", "") for row in body["top_tracks"] if row.get("id")}


def test_top_song_carries_its_album_cover(crawled: str) -> None:  # noqa: F811
    asyncio.run(_cover(crawled, "/data/covers/low-tide.jpg"))
    assert _top(crawled)["Paper Crown"] == f"/v1/covers/{LOW_TIDE}"


def test_album_without_a_cover_leaves_the_song_without_one(crawled: str) -> None:  # noqa: F811
    """The cover was searched for and not found — empty string, not an address of a missing image (otherwise phone expects 404)."""
    asyncio.run(_cover(crawled, None))
    assert _top(crawled)["Paper Crown"] == ""
