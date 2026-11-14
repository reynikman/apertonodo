"""Genre artists are sorted alphabetically: Latin, then Cyrillic, then others (FT-509, Р-A54).

Owner feedback 02.10 (J 14): genre artists were ordered by popularity, whereas
alphabetical order was expected. Decision: in genre — alphabetical, Latin first; by
popularity — only search. Case and accented characters do not break the alphabet:
"a-ha" near "A", "Édith" near "E"; "Ё" near "Е".
"""

from __future__ import annotations

import asyncio

import asyncpg
from fastapi.testclient import TestClient
from test_catalog_browse import _extension, _app, _seed


# The replica genre is "rock" (as in production): the base set already has four with releases (Dead Lantern —
# with a dead one, not present in lists: Р-A66, FT-543), and the most
# popular of them is Velvet Orchard, who comes first when sorting by popularity.
EXTRA = ["Кино", "50 Cent", "Zebra Lane", "Ёлка", "a-ha", "Ария", "Édith Piaf"]

EXPECTED = [
    "a-ha", "Édith Glow", "Édith Piaf", "Glass Harbor", "Velvet Orchard", "Zebra Lane",
    "Ария", "Ёлка", "Кино", "Ржавый Ключ",
    "50 Cent",
]


async def _extra(url: str) -> None:
    conn = await asyncpg.connect(url)
    try:
        for i, name in enumerate(EXTRA):
            mbid = f"5b11f4ce-0000-4000-8000-0000000001{i:02d}"
            await conn.execute(
                "INSERT INTO mb_artist (mbid, name, sort_name, ended) VALUES ($1, $2, $2, false)", mbid, name
            )
            await conn.execute(
                "INSERT INTO artist_genre (artist_mbid, slug, source, score, is_primary)"
                " VALUES ($1, 'rock', 'mb', 5, true)",
                mbid,
            )
            await conn.execute("INSERT INTO catalog_open_names (name, mbid) VALUES ($1, $2)", name, mbid)
        # Names were opened bypassing publication — rebuild genre order like publication does (FT-766).
        await conn.execute("SELECT public.build_catalog_genre_artists()")
    finally:
        await conn.close()


def _built(postgres_url: str) -> str:
    asyncio.run(_seed(postgres_url))
    asyncio.run(_extension().build_catalog(postgres_url))
    asyncio.run(_extra(postgres_url))
    return postgres_url


def _page(client: TestClient, offset: int, limit: int) -> dict:
    return client.get("/v1/artists", params={"genre": "rock", "offset": offset, "limit": limit}).json()


def test_genre_is_alphabetical_latin_first(postgres_url: str) -> None:
    url = _built(postgres_url)
    with TestClient(_app(url)) as client:
        body = _page(client, 0, 50)
    assert [item["name"] for item in body["artists"]] == EXPECTED
    assert body["total"] == len(EXPECTED)


def test_pages_walk_the_same_alphabet(postgres_url: str) -> None:
    url = _built(postgres_url)
    with TestClient(_app(url)) as client:
        names = [item["name"] for offset in range(0, 12, 5) for item in _page(client, offset, 5)["artists"]]
    assert names == EXPECTED
