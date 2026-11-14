"""FT-552 (Р-A12, owner decision 06.10): identical albums — one tile, edition selection inside.

Night check for three consecutive days was red on `[album-duplicate]`: Bizet has five "Carmen" from the same year
(different recordings of the opera), Eliseo Parra has live and studio "Diez" 2009, Lolita has two "Судьба" singles 2018.
Owner chose: same title + year for one artist -> one tile, the rest are "other editions" inside.

Contract `GET /v1/artist`:
- each tile has `editions` — list (empty if no namesakes); item is `{"id", "title", "year", "kind"}`;
- tile is the primary namesake: studio (`album`) before live and compilation, then whichever has more official
  releases, then lower `id`; other namesakes are in its `editions` in the same order and do not appear as separate tiles;
- same year is required: five "Weezer" from different years remain five tiles (FT-484);
- edition opens via regular `GET /v1/albums/{id}`.
"""

from __future__ import annotations

import asyncio

import asyncpg
from fastapi.testclient import TestClient
from test_catalog_browse import ARTIST, FakeMusicBrainz, _app, built, db  # noqa: F401  (built, db — fixtures)

STORM_LIVE = "0e0f1a9c-5f2c-4b4f-9d44-3a1d2f7a0201"
ECHO_A = "0e0f1a9c-5f2c-4b4f-9d44-3a1d2f7a0202"
ECHO_B = "0e0f1a9c-5f2c-4b4f-9d44-3a1d2f7a0203"
STORM_2015 = "0e0f1a9c-5f2c-4b4f-9d44-3a1d2f7a0204"


async def _namesakes(url: str) -> None:
    conn = await asyncpg.connect(url)
    try:
        groups = [
            # Live concert with title and year of studio "Storm Season" 2008.
            (STORM_LIVE, "Storm Season", "Album", ["Live"], "2008-11-01", 1),
            # Two singles from the same year: B has two official releases, A has one.
            (ECHO_A, "Echo", "Single", [], "2009", 1),
            (ECHO_B, "ECHO", "Single", [], "2009-02-01", 2),
            # Same "Storm Season", but different year — separate album.
            (STORM_2015, "Storm Season", "Album", [], "2015", 1),
        ]
        await conn.executemany(
            "INSERT INTO mb_release_group (mbid, artist_mbid, title, primary_type, secondary_types, first_date) "
            "VALUES ($1, $2, $3, $4, $5, $6)",
            [(g[0], ARTIST, g[1], g[2], g[3], g[4]) for g in groups],
        )
        medium = 600
        for n, (group, title, _p, _s, date, releases) in enumerate(groups):
            for k in range(releases):
                release = f"7a2b0c11-0000-4000-8000-0000000{200 + n * 10 + k:05d}"
                await conn.execute(
                    "INSERT INTO mb_release (mbid, group_mbid, title, status, country, date) "
                    "VALUES ($1, $2, $3, 'Official', 'XW', $4)",
                    release, group, title, date,
                )
                # Album without songs does not reach the page (FT-538).
                await conn.execute(
                    "INSERT INTO mb_medium (id, release_mbid, position, format) VALUES ($1, $2, 1, 'CD')", medium, release
                )
                await conn.execute(
                    "INSERT INTO mb_track (mbid, medium_id, recording_mbid, position, title, length_ms) "
                    "VALUES (gen_random_uuid(), $1, gen_random_uuid(), 1, 'Intro', 200000)",
                    medium,
                )
                medium += 1
    finally:
        await conn.close()


def test_namesakes_of_one_year_are_one_tile_with_editions(built: str) -> None:  # noqa: F811
    asyncio.run(_namesakes(built))
    with TestClient(_app(built, FakeMusicBrainz())) as client:
        page = client.get("/v1/artist", params={"name": "glass harbor"}).json()
        tiles = [(a["id"], a["title"], a["year"], a["kind"]) for a in page["albums"]]
        storm_2008 = next(a for a in page["albums"] if a["title"] == "Storm Season" and a["year"] == 2008)
        echo = next(a for a in page["albums"] if a["title"].lower() == "echo")

        ids = [t[0] for t in tiles]
        assert STORM_LIVE not in ids, "live concert with same title and year became separate tile"
        assert len([t for t in tiles if t[1].lower() == "echo"]) == 1, "two singles 'Echo' 2009 became two tiles"
        assert STORM_2015 in ids, "'Storm Season' 2015 is a different year, must remain its own tile"

        assert storm_2008["kind"] == "album", "non-studio recording became primary"
        assert storm_2008["editions"] == [
            {"id": STORM_LIVE, "title": "Storm Season", "year": 2008, "kind": "live"}
        ]
        assert echo["id"] == ECHO_B, "single with more releases should be primary"
        assert echo["editions"] == [{"id": ECHO_A, "title": "Echo", "year": 2009, "kind": "single"}]

        others = [a for a in page["albums"] if a["id"] not in (storm_2008["id"], echo["id"])]
        assert others and all(a["editions"] == [] for a in others), "tiles without namesakes must have empty editions list"

        edition = client.get(f"/v1/albums/{STORM_LIVE}")
        assert edition.status_code == 200, "edition from the list does not open"
