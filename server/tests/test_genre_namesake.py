"""The genre of a name is the genre of the namesake opened by the page (FT-507).

Owner feedback 02.10 (J 13): Prince — in hip-hop. In the MusicBrainz replica
there are five artists named "Prince"; one has zero releases and a single vote for
hip hop, and he ended up in the genre. The genre list displays the name, takes
popularity by name — from the real Prince — and the obscure namesake topped
hip-hop, while tapping opened the real Prince's page (who has funk/R&B).

Rule: name in genre list and in /v1/genres count — only if this genre belongs to
the namesake opened for this name by /v1/artist (most release groups,
FT-455).
"""

from __future__ import annotations

import asyncio
from typing import Any

import asyncpg
from fastapi.testclient import TestClient
from test_catalog_browse import _extension, ARTIST, _app, _seed


# Second "Glass Harbor": no releases, primary genre is hip-hop.
NAMESAKE = "5b11f4ce-0000-4000-8000-0000000000aa"


async def _namesake(url: str) -> None:
    conn = await asyncpg.connect(url)
    try:
        await conn.execute(
            "INSERT INTO mb_artist (mbid, name, sort_name, ended) VALUES ($1, 'Glass Harbor', 'Glass Harbor', false)",
            NAMESAKE,
        )
        await conn.execute(
            "INSERT INTO artist_genre (artist_mbid, slug, source, score, is_primary) VALUES ($1, 'hip-hop', 'mb', 1, true)",
            NAMESAKE,
        )
    finally:
        await conn.close()


def _built(postgres_url: str) -> str:
    asyncio.run(_seed(postgres_url))
    asyncio.run(_namesake(postgres_url))
    asyncio.run(_extension().build_catalog(postgres_url))
    return postgres_url


def _names(client: TestClient, genre: str) -> tuple[list[str], int]:
    body = client.get("/v1/artists", params={"genre": genre, "limit": 500}).json()
    return [item["name"] for item in body["artists"]], body["total"]


def _counts(client: TestClient) -> dict[str, Any]:
    return {row["id"]: row["artists"] for row in client.get("/v1/genres").json()["genres"]}


def test_namesake_genre_does_not_list_the_name(postgres_url: str) -> None:
    url = _built(postgres_url)
    with TestClient(_app(url)) as client:
        # Page by name opens the one who has releases — not the namesake.
        assert client.get("/v1/artist", params={"name": "Glass Harbor"}).json()["artist"]["id"] == ARTIST
        hiphop, total = _names(client, "hip-hop")
        assert "Glass Harbor" not in hiphop
        assert total == len(hiphop)
        assert _counts(client).get("hip-hop", 0) == len(hiphop)


def test_page_artist_genre_still_lists_the_name(postgres_url: str) -> None:
    url = _built(postgres_url)
    with TestClient(_app(url)) as client:
        rock, total = _names(client, "rock")
        assert "Glass Harbor" in rock
        assert rock.count("Glass Harbor") == 1
        assert total == len(rock)
        assert _counts(client)["rock"] == len(rock)


def test_rows_from_before_the_rebuild_keep_the_genre(postgres_url: str) -> None:
    """Immediately after deploy, before `python -m app.catalog build`, rows in
    catalog_open_names have no namesake recorded yet — genres must not become empty."""
    url = _built(postgres_url)

    async def forget() -> None:
        conn = await asyncpg.connect(url)
        try:
            await conn.execute("UPDATE catalog_open_names SET mbid = NULL")
        finally:
            await conn.close()

    asyncio.run(forget())
    with TestClient(_app(url)) as client:
        rock, _total = _names(client, "rock")
        assert "Glass Harbor" in rock
