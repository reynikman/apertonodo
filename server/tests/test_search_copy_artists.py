"""Search finds an artist by exact name, even without own release (FT-457).

Nightly check 30.09: search failed to find 16 artists from genre lists by their exact
name ("Rick Scott", "KV 33", "特撮がるず"). Search artists are drawn
only from own release list, while genres come from MusicBrainz dump. A user sees
name in genre, types it in search — and gets strangers ("Rick Ross", "Scott
Walker"). "ZARD" is found, but as third result and as "ZARD (Izumi Sakai (坂井泉水))":
exact name is missing in own list, and "Zardonic" ranks higher by prefix.

For songs the owner already decided this: what is missing in own list is shown, not
hidden — empty results would lie just as much (docs/live-sources.md). Rule
for artists is the same: exact name from the dump — in results, above similar ones. But
only an artist whose page opens with albums (FT-455): otherwise search would lead
to an empty page.
"""

from __future__ import annotations

import asyncio

import asyncpg
from fastapi.testclient import TestClient
from fakes import SeededExtension
from test_catalog_browse import RELEASES, ROCK, _app, _seed
from test_listed_artists_open import EXTRA
from test_listed_artists_open import _extra as _listed_extra
from test_listed_artists_open import _opens

from app import catalog

RICK = "6c0a2c1e-0000-4000-8000-000000000011"
ZARD = "6c0a2c1e-0000-4000-8000-000000000012"

# (topic, title, seeders)
OWN = [
    (401, "(J-Pop) ZARD (Izumi Sakai (坂井泉水)) - Golden Best - 2002, FLAC (tracks), lossless", 5),
    (402, "(Rock) Zardonic - Antihero - 2015, FLAC (tracks), lossless", 80),
    (403, "(Rock) Rick Ross - Port of Miami - 2006, MP3, 320 kbps", 60),
]


async def _extra(url: str) -> None:
    conn = await asyncpg.connect(url)
    try:
        # Rick Scott — in the dump, with an album, but no releases of his own.
        await conn.executemany("INSERT INTO mb_artist (mbid, name, sort_name, ended) VALUES ($1, $2, $3, false)",
                               [(RICK, "Rick Scott", "Scott, Rick"), (ZARD, "ZARD", "ZARD")])
        groups = [("0e0f1a9c-5f2c-4b4f-9d44-3a1d2f7a0111", RICK, "Rick Scott"),
                  ("0e0f1a9c-5f2c-4b4f-9d44-3a1d2f7a0112", ZARD, "Golden Best")]
        await conn.executemany(
            "INSERT INTO mb_release_group (mbid, artist_mbid, title, primary_type, first_date) VALUES ($1, $2, $3, 'Album', '2002')", groups
        )
        await conn.executemany(
            "INSERT INTO mb_release (mbid, group_mbid, title, status, country, date) VALUES ($1, $2, $3, 'Official', 'XW', '2002')",
            [(f"7a2b0c11-0000-4000-8000-00000000011{n}", group, title) for n, (group, _a, title) in enumerate(groups, start=1)],
        )
        # One song per release: an album without songs does not reach the page (FT-538).
        for medium, release in enumerate([f"7a2b0c11-0000-4000-8000-00000000011{n}" for n in range(1, len(groups) + 1)], start=300):
            await conn.execute("INSERT INTO mb_medium (id, release_mbid, position, format) VALUES ($1, $2, 1, 'CD')", medium, release)
            await conn.execute("INSERT INTO mb_track (mbid, medium_id, recording_mbid, position, title, length_ms) "
                               "VALUES (gen_random_uuid(), $1, gen_random_uuid(), 1, 'Intro', 200000)", medium)
    finally:
        await conn.close()


def _extension() -> SeededExtension:
    listed = [(topic, ROCK, title, tracks, seeders) for topic, title, tracks, seeders in EXTRA]
    own = [(topic, ROCK, title, ["intro"], seeders) for topic, title, seeders in OWN]
    return SeededExtension(RELEASES + listed + own)


def _filled(postgres_url: str) -> str:
    # Order is like _built: first schema and shared set, then own rows, then build.
    asyncio.run(_seed(postgres_url))
    asyncio.run(_listed_extra(postgres_url))
    asyncio.run(_extra(postgres_url))
    asyncio.run(_extension().build_catalog(postgres_url))
    catalog.use_extensions(_extension().playable())
    return postgres_url


def _artists(client: TestClient, query: str) -> list[str]:
    response = client.get("/v1/search", params={"q": query})
    assert response.status_code == 200, query
    return [item["name"] for item in response.json()["artists"]]


def test_exact_name_from_the_copy_is_found_first(postgres_url: str) -> None:
    url = _filled(postgres_url)
    with TestClient(_app(url)) as client:
        assert _artists(client, "Rick Scott")[:1] == ["Rick Scott"]
        # Exact name ranks above own similar: "Zardonic" by prefix and with higher weight.
        assert _artists(client, "zard")[:1] == ["ZARD"]
        # Own exact — still first and only once.
        glass = _artists(client, "glass harbor")
        assert glass[:1] == ["Glass Harbor"]
        assert len({name.casefold() for name in glass}) == len(glass)


def test_copy_artist_without_albums_is_not_offered(postgres_url: str) -> None:
    url = _filled(postgres_url)
    with TestClient(_app(url)) as client:
        assert "Alvin Cash" not in _artists(client, "alvin cash")
        assert "Яна Павлова" not in _artists(client, "яна павлова")


def test_every_artist_search_offers_opens_with_albums(postgres_url: str) -> None:
    url = _filled(postgres_url)
    broken = []
    with TestClient(_app(url)) as client:
        for query in ("rick scott", "zard", "kino", "кино", "glass harbor", "alvin cash", "невеста"):
            broken.extend(f"{query}: {problem}" for name in _artists(client, query) if (problem := _opens(client, name)))
    assert broken == [], "\n".join(broken)
