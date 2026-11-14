"""The first recording of a song stands above its covers in `/v1/search` (FT-876).

Nightly check red since 11.10: for "stumblin in" Smokie is first, but the song was first
recorded by Suzi Quatro and Chris Norman. The order of own tracks is set by
`search.TRACKS_SQL`: exact title, all words, then `weight` (artist popularity) — and a
cover by a more popular artist wins. The copy knows who recorded the song first: `song.work_mbid`
(one work — one song per artist), `song_version.kind` ('original' or 'cover') and
`song.original_recording_mbid` (empty when every recording of the artist is a cover).

What is guarded, row by row of the card table:

1. title query, original and covers -> the original's artist first
   (`test_original_first_though_covers_are_more_popular`, `test_early_live_recording_of_a_cover_does_not_make_it_first`,
   `test_nightly_shape_stumblin_in`);
2. original recorded as a duet "A & B", the result has "A" -> counts as the original
   (`test_duet_original_counts_for_its_member`);
3. query "artist + song" -> the named artist is first
   (`test_named_artist_stays_first`);
4. no data about the first recording -> order as before
   (`test_work_without_first_recording_keeps_the_order`);
5. song without a work in the copy -> order as before
   (`test_songs_without_a_work_keep_the_order`);
6. cover far more popular than the original -> the original is first, the cover is
   still in the first five (`test_popular_cover_stays_in_the_first_five`);
7. what is not a title query stays as before
   (`test_prefix_query_keeps_the_order`).

The data is small and made up: one work, one original, a few covers. No network.
"""

from __future__ import annotations

from typing import Any
from uuid import NAMESPACE_URL, UUID, uuid5

import asyncpg
import pytest
from fastapi.testclient import TestClient

from app.main import create_app
from app.migrate import apply
from app.names import norm

WORK = UUID("4277fd45-0000-4000-8000-000000000001")
OTHER_WORK = UUID("4277fd45-0000-4000-8000-000000000002")
TITLE = "Harbor Lights"

# (kind, year) of recordings that one song of the copy holds.
Versions = list[tuple[str, int | None]]


class StubCatalog:
    """MusicBrainz that answers nothing: only the own list is under test."""

    async def search(self, query: str, limit: int) -> list[dict[str, Any]]:
        return []


@pytest.fixture
async def url(postgres_url: str) -> str:
    await apply(postgres_url)
    conn = await asyncpg.connect(postgres_url)
    try:
        await conn.execute(
            "TRUNCATE catalog_tracks, catalog_artists, lastfm_artists, song_version, song, mb_artist CASCADE"
        )
    finally:
        await conn.close()
    return postgres_url


async def seed(
    url: str,
    tracks: list[tuple[str, str, int]],
    songs: list[tuple[str, str, UUID | None, Versions]] | None = None,
) -> None:
    """`tracks` — own list rows (artist, title, weight); `songs` — the copy's songs
    (artist, title, work, versions), the way `catalog_songs` writes them."""
    conn = await asyncpg.connect(url)
    try:
        for artist, title, weight in tracks:
            await conn.execute(
                "INSERT INTO catalog_tracks (artist_key, title_key, artist, title, weight) "
                "VALUES ($1, $2, $3, $4, $5)",
                norm(artist), norm(title), artist, title, weight,
            )
        for artist, title, work, versions in songs or []:
            artist_mbid = uuid5(NAMESPACE_URL, f"artist:{artist}")
            await conn.execute(
                "INSERT INTO mb_artist (mbid, name, sort_name, ended) VALUES ($1, $2, $2, false) "
                "ON CONFLICT DO NOTHING",
                artist_mbid, artist,
            )
            rows = [
                (uuid5(NAMESPACE_URL, f"rec:{artist}:{title}:{n}"), kind, year)
                for n, (kind, year) in enumerate(versions)
            ]
            first_original = next(((rec, year) for rec, kind, year in rows if kind == "original"), None)
            song_id = await conn.fetchval(
                "INSERT INTO song (artist_mbid, title, work_mbid, original_recording_mbid, original_year) "
                "VALUES ($1, $2, $3, $4, $5) RETURNING id",
                artist_mbid, title, work,
                first_original[0] if first_original else None,
                first_original[1] if first_original else None,
            )
            for rec, kind, year in rows:
                await conn.execute(
                    "INSERT INTO song_version (song_id, recording_mbid, kind, year) VALUES ($1, $2, $3, $4)",
                    song_id, rec, kind, year,
                )
    finally:
        await conn.close()


def order(url: str, query: str) -> list[str]:
    app = create_app(database_url=url, catalog=[], catalog_port=StubCatalog())
    with TestClient(app) as http:
        response = http.get("/v1/search", params={"q": query})
    assert response.status_code == 200
    return [track["artist"] for track in response.json()["tracks"]]


# --- Row 1: title query, original and covers -----------------------------------------


async def test_original_first_though_covers_are_more_popular(url: str) -> None:
    await seed(
        url,
        [(a, TITLE, w) for a, w in [("Orla Vance", 100), ("Brandon Pike", 900), ("Cleo Marsh", 500)]],
        [
            ("Orla Vance", TITLE, WORK, [("original", 1978), ("live", 1990)]),
            ("Brandon Pike", TITLE, WORK, [("cover", 1985)]),
            ("Cleo Marsh", TITLE, WORK, [("cover", 1990)]),
        ],
    )
    got = order(url, "harbor lights")
    assert got[0] == "Orla Vance"
    # The covers keep their order among themselves: by popularity, as before.
    assert got[1:] == ["Brandon Pike", "Cleo Marsh"]


async def test_early_live_recording_of_a_cover_does_not_make_it_first(url: str) -> None:
    """The first STUDIO recording decides, not the earliest date of any recording."""
    await seed(
        url,
        [("Orla Vance", TITLE, 100), ("Brandon Pike", TITLE, 900)],
        [
            ("Orla Vance", TITLE, WORK, [("original", 1978)]),
            ("Brandon Pike", TITLE, WORK, [("live", 1970), ("cover", 1985)]),
        ],
    )
    assert order(url, "harbor lights")[0] == "Orla Vance"


async def test_nightly_shape_stumblin_in(url: str) -> None:
    """Weights and data as on the live copy 26.10: Smokie holds covers only, Suzi and
    Chris hold the originals, Bernie Paul is outside the work."""
    title = "Stumblin' In"
    await seed(
        url,
        [
            ("Smokie", title, 477_235),
            ("Suzi Quatro", title, 362_023),
            ("Chris Norman", title, 287_232),
            ("Bernie Paul", title, 9_642),
            ("Smokie & Chris Norman", title, 2_163),
        ],
        [
            ("Smokie", "Stumblin’ In", WORK, [("cover", 1980), ("cover", 1993)]),
            ("Suzi Quatro", title, WORK, [("original", 1979), ("live", 2004)]),
            ("Chris Norman", "Stumblin’ In", WORK, [("original", 1975), ("live", 2005)]),
            ("Bernie Paul", title, None, [("original", 1996)]),
        ],
    )
    got = order(url, "stumblin in")
    assert got[0] == "Suzi Quatro"
    assert "Smokie" in got[:5]


# --- Row 2: the original is a duet ----------------------------------------------------


async def test_duet_original_counts_for_its_member(url: str) -> None:
    """The copy credits the first recording to "Orla Vance & Dex Holm"; the own list
    has "Orla Vance" alone — and she is the original performer."""
    await seed(
        url,
        [("Orla Vance", TITLE, 100), ("Brandon Pike", TITLE, 900)],
        [
            ("Orla Vance & Dex Holm", TITLE, WORK, [("original", 1978)]),
            ("Brandon Pike", TITLE, WORK, [("cover", 1985)]),
        ],
    )
    assert order(url, "harbor lights")[0] == "Orla Vance"


# --- Row 3: artist named in the query -------------------------------------------------


async def test_named_artist_stays_first(url: str) -> None:
    """"brandon pike harbor lights": the person named the artist — Brandon Pike is first,
    even though he only covers the song, while the list also holds the duet row
    "Brandon Pike & Orla Vance" with the original's singer (as "Smokie & Chris Norman")."""
    await seed(
        url,
        [("Brandon Pike", TITLE, 900), ("Brandon Pike & Orla Vance", TITLE, 50)],
        [
            ("Orla Vance", TITLE, WORK, [("original", 1978)]),
            ("Brandon Pike", TITLE, WORK, [("cover", 1985)]),
        ],
    )
    got = order(url, "brandon pike harbor lights")
    assert got[0] == "Brandon Pike"


# --- Row 4: no data about the first recording -----------------------------------------


async def test_work_without_first_recording_keeps_the_order(url: str) -> None:
    """No song of the work holds an 'original' recording: nobody is promoted, order by popularity."""
    await seed(
        url,
        [(a, TITLE, w) for a, w in [("Orla Vance", 100), ("Brandon Pike", 900), ("Cleo Marsh", 500)]],
        [
            ("Orla Vance", TITLE, WORK, [("live", None)]),
            ("Brandon Pike", TITLE, WORK, [("cover", 1985)]),
            ("Cleo Marsh", TITLE, WORK, [("cover", None)]),
        ],
    )
    assert order(url, "harbor lights") == ["Brandon Pike", "Cleo Marsh", "Orla Vance"]


# --- Row 5: song without a work in the copy -------------------------------------------


async def test_songs_without_a_work_keep_the_order(url: str) -> None:
    """Without a work nobody knows which song is the original: not even a song of kind 'original'
    is promoted. One of the artists is absent from the copy altogether."""
    await seed(
        url,
        [(a, TITLE, w) for a, w in [("Orla Vance", 100), ("Brandon Pike", 900), ("Cleo Marsh", 500)]],
        [
            ("Orla Vance", TITLE, None, [("original", 1978)]),
            ("Brandon Pike", TITLE, None, [("cover", 1985)]),
        ],
    )
    assert order(url, "harbor lights") == ["Brandon Pike", "Cleo Marsh", "Orla Vance"]


# --- Row 6: a far more popular cover --------------------------------------------------


async def test_popular_cover_stays_in_the_first_five(url: str) -> None:
    others = [(f"Nobody {n}", 800 - 100 * n) for n in range(5)]
    await seed(
        url,
        [(a, TITLE, w) for a, w in [("Orla Vance", 100), ("Brandon Pike", 90_000), *others]],
        [
            ("Orla Vance", TITLE, WORK, [("original", 1978)]),
            ("Brandon Pike", TITLE, WORK, [("cover", 1985)]),
        ],
    )
    got = order(url, "harbor lights")
    assert got[0] == "Orla Vance"
    assert got.index("Brandon Pike") < 5


# --- Row 7: what stays as it is -------------------------------------------------------


async def test_prefix_query_keeps_the_order(url: str) -> None:
    """The rule is for a query that IS the title; a part of it ("harbor lig") is not one,
    like the other nightly rows ("metallica 72 seasons", "slipknot duality")."""
    await seed(
        url,
        [(a, TITLE, w) for a, w in [("Orla Vance", 100), ("Brandon Pike", 900), ("Cleo Marsh", 500)]],
        [
            ("Orla Vance", TITLE, WORK, [("original", 1978)]),
            ("Brandon Pike", TITLE, WORK, [("cover", 1985)]),
            ("Cleo Marsh", TITLE, WORK, [("cover", 1990)]),
        ],
    )
    assert order(url, "harbor lig") == ["Brandon Pike", "Cleo Marsh", "Orla Vance"]


async def test_other_work_is_not_promoted_by_the_original_of_this_one(url: str) -> None:
    """Two songs with one title, different works: each is judged within its own work."""
    await seed(
        url,
        [("Orla Vance", TITLE, 100), ("Brandon Pike", TITLE, 900), ("Eli Frost", TITLE, 5_000)],
        [
            ("Orla Vance", TITLE, WORK, [("original", 1978)]),
            ("Brandon Pike", TITLE, WORK, [("cover", 1985)]),
            ("Eli Frost", TITLE, OTHER_WORK, [("original", 2001)]),
        ],
    )
    got = order(url, "harbor lights")
    assert got.index("Eli Frost") < got.index("Brandon Pike")
