"""In artist lists — only those with a release (Р-A66, FT-543).

Production measurement on 03.10: 251k names in genre lists, and 177k with a release.
The rest came into lists from MusicBrainz copy genres: their page opens,
but there is nothing to listen to. Lists are a showcase of what plays; search
still finds any copy artist whose page opens.
"""

from __future__ import annotations

import asyncio

import asyncpg
from fastapi.testclient import TestClient
from test_catalog_browse import _app, _seed
from test_listed_artists_open import _extra as _listed_extra
from test_listed_artists_open import _extension, _names, _opens

from app import catalog


QUIET = "6c0a2c1e-0000-4000-8000-000000000043"


async def _extra(url: str) -> None:
    """Quiet Archive — in copy genre, with official album and song, but without a release."""
    conn = await asyncpg.connect(url)
    try:
        await conn.execute("INSERT INTO mb_artist (mbid, name, sort_name, ended) "
                           "VALUES ($1, 'Quiet Archive', 'Quiet Archive', false)", QUIET)
        await conn.execute("INSERT INTO artist_genre (artist_mbid, slug, source, score, is_primary) "
                           "VALUES ($1, 'rock', 'seed', 1, true)", QUIET)
        await conn.execute("INSERT INTO mb_release_group (mbid, artist_mbid, title, primary_type, first_date) "
                           "VALUES ('0e0f1a9c-5f2c-4b4f-9d44-3a1d2f7a0543', $1, 'Dust Shelves', 'Album', '2011')", QUIET)
        await conn.execute("INSERT INTO mb_release (mbid, group_mbid, title, status, country, date) VALUES "
                           "('7a2b0c11-0000-4000-8000-000000000543', '0e0f1a9c-5f2c-4b4f-9d44-3a1d2f7a0543', "
                           "'Dust Shelves', 'Official', 'XW', '2011')")
        await conn.execute("INSERT INTO mb_medium (id, release_mbid, position, format) "
                           "VALUES (543, '7a2b0c11-0000-4000-8000-000000000543', 1, 'CD')")
        await conn.execute("INSERT INTO mb_track (mbid, medium_id, recording_mbid, position, title, length_ms) "
                           "VALUES (gen_random_uuid(), 543, gen_random_uuid(), 1, 'Intro', 200000)")
    finally:
        await conn.close()


def _built(postgres_url: str) -> str:
    asyncio.run(_seed(postgres_url))
    asyncio.run(_listed_extra(postgres_url))
    asyncio.run(_extra(postgres_url))
    asyncio.run(_extension().build_catalog(postgres_url))
    catalog.use_extensions(_extension().playable())
    return postgres_url


async def _playable(url: str) -> set[str]:
    conn = await asyncpg.connect(url)
    try:
        return {row["name"] for row in await conn.fetch("SELECT DISTINCT name FROM catalog_artists")}
    finally:
        await conn.close()


def test_genre_list_skips_artist_without_release(postgres_url: str) -> None:
    url = _built(postgres_url)
    with TestClient(_app(url)) as client:
        rock, total = _names(client, genre="rock")
        counted = {row["id"]: row["artists"] for row in client.get("/v1/genres").json()["genres"]}
        rock_letters = {row["letter"] for row in client.get("/v1/letters", params={"genre": "rock"}).json()["letters"]}
        # Positive control: an artist with a release exists in the genre.
        assert "Glass Harbor" in rock
        assert "Quiet Archive" not in rock
        assert counted["rock"] == total == len(rock)
        assert "Q" not in rock_letters
        # The page and search still find them.
        assert _opens(client, "Quiet Archive") == ""
        found = [item["name"] for item in client.get("/v1/search", params={"q": "quiet archive"}).json()["artists"]]
        assert found[:1] == ["Quiet Archive"]


def test_every_listed_name_has_a_release(postgres_url: str) -> None:
    url = _built(postgres_url)
    playable = asyncio.run(_playable(url))
    stray: list[str] = []
    with TestClient(_app(url)) as client:
        lists = {"alphabet": _names(client)[0]}
        for row in client.get("/v1/letters").json()["letters"]:
            lists[f"letter {row['letter']}"] = _names(client, letter=row["letter"])[0]
        for row in client.get("/v1/genres").json()["genres"]:
            if row["artists"]:
                lists[f"genre {row['id']}"] = _names(client, genre=row["id"])[0]
    assert len(lists) > 2
    for where, names in lists.items():
        stray.extend(f"{where}: {name}" for name in names if name not in playable)
    assert stray == [], "\n".join(stray)
