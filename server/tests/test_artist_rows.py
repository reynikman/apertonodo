"""Artist page — albums in three rows (Р-A51, p4-fixes 9 and 10).

Owner 02.10: "Albums", "EPs & Singles", "Live & Compilations"; live and compilations are not hidden, but go to their
row at the bottom. Before this the server served only studio albums and EPs: singles, concerts, and compilations were
not on the page at all. The app groups rows by `kind`: `album` | `ep` | `single` | `live` | `compilation`.

Remixes, demos, soundtracks, DJ-mixes are not the band's discography and do not go into rows. In production Metallica has 530
official live albums, Leningrad has 78 singles: "EPs & Singles" row and "Live & Compilations" row — each
no longer than `ROW_LIMIT`, with release groups having the most official editions (reissued more often).
"""

from __future__ import annotations

import asyncio
from typing import Any

import asyncpg
from fastapi.testclient import TestClient

from tests.test_catalog_browse import ARTIST, FakeMusicBrainz, _app, built, db  # noqa: F401

ROW_LIMIT = 24


def _gid(n: int) -> str:
    return f"0e0f1a9c-5f2c-4b4f-9d44-3a1d2f7a{n:04d}"


async def _groups(url: str, rows: list[tuple[int, str, str | None, list[str], str, int]]) -> None:
    """(number, title, primary type, secondary types, date, count of official releases)."""
    conn = await asyncpg.connect(url)
    try:
        for n, title, primary, secondary, date, releases in rows:
            await conn.execute(
                "INSERT INTO mb_release_group (mbid, artist_mbid, title, primary_type, secondary_types, first_date) "
                "VALUES ($1::uuid, $2, $3, $4, $5, $6)",
                _gid(n), ARTIST, title, primary, secondary, date,
            )
            for r in range(releases):
                release = await conn.fetchval(
                    "INSERT INTO mb_release (mbid, group_mbid, title, status, country, date) "
                    "VALUES (gen_random_uuid(), $1::uuid, $2, 'Official', 'XW', $3) RETURNING mbid",
                    _gid(n), title, date if r == 0 else "2020",
                )
                # A song per release: album without songs does not reach the page (FT-538).
                medium = 50000 + n * 100 + r
                await conn.execute(
                    "INSERT INTO mb_medium (id, release_mbid, position, format) VALUES ($1, $2, 1, 'CD')", medium, release
                )
                await conn.execute(
                    "INSERT INTO mb_track (mbid, medium_id, recording_mbid, position, title, length_ms) "
                    "VALUES (gen_random_uuid(), $1, gen_random_uuid(), 1, $2, 200000)",
                    medium, title,
                )
    finally:
        await conn.close()


def _albums(url: str) -> list[dict[str, Any]]:
    with TestClient(_app(url, FakeMusicBrainz())) as client:
        page = client.get("/v1/artist", params={"name": "Glass Harbor"}).json()
    return page["albums"]


def test_singles_live_and_compilations_come_with_their_kind(built: str) -> None:  # noqa: F811
    asyncio.run(_groups(built, [
        (101, "Harbor Lights", "Single", [], "2006", 1),
        (102, "Live at the Pier", "Album", ["Live"], "2009", 1),
        (103, "Best of Glass Harbor", "Album", ["Compilation"], "2013", 1),
        (104, "Live Hits", "Album", ["Compilation", "Live"], "2014", 1),
        (105, "Low Tide Remixed", "Album", ["Remix"], "2007", 1),
        (106, "Early Demo", "Single", ["Demo"], "2001", 1),
        (107, "Harbor Film", "Album", ["Soundtrack"], "2010", 1),
        (108, "Radio Session", "Broadcast", [], "2011", 1),
    ]))
    assert [(a["title"], a["year"], a["kind"]) for a in _albums(built)] == [
        ("Low Tide", 2004, "album"),
        ("Paper Crown", 2005, "ep"),
        ("Harbor Lights", 2006, "single"),
        ("Storm Season", 2008, "album"),
        ("Live at the Pier", 2009, "live"),
        ("Winter Keys", 2012, "album"),
        ("Best of Glass Harbor", 2013, "compilation"),
        # Live compilation is a live concert: goes to "Live & Compilations" row either way, and "live" is more accurate.
        ("Live Hits", 2014, "live"),
    ]


def test_single_with_the_album_title_is_not_a_second_album(built: str) -> None:  # noqa: F811
    """Single with the album title is hidden like EP (01.10 finding, St. Anger). Live concert with the same title is not."""
    asyncio.run(_groups(built, [
        (111, "LOW TIDE", "Single", [], "2004-06-01", 1),
        (112, "Low Tide", "Album", ["Live"], "2010", 1),
    ]))
    assert [(a["title"], a["kind"]) for a in _albums(built) if a["title"].lower() == "low tide"] == [
        ("Low Tide", "album"),
        ("Low Tide", "live"),
    ]


def test_long_rows_keep_the_most_released(built: str) -> None:  # noqa: F811
    """30 live albums and 30 singles: each row has ROW_LIMIT with the most releases, sorted by year."""
    rows = []
    for i in range(30):
        # Even — two releases, odd — one; only some odd ones pass.
        rows.append((200 + i, f"Live {i:02d}", "Album", ["Live"], f"{1990 + i}", 2 if i % 2 == 0 else 1))
        rows.append((300 + i, f"Single {i:02d}", "Single", [], f"{1990 + i}", 3 if i % 2 == 0 else 1))
    asyncio.run(_groups(built, rows))
    albums = _albums(built)

    live = [a for a in albums if a["kind"] in ("live", "compilation")]
    small = [a for a in albums if a["kind"] in ("ep", "single")]
    assert len(live) == ROW_LIMIT and len(small) == ROW_LIMIT
    assert {f"Live {i:02d}" for i in range(0, 30, 2)} <= {a["title"] for a in live}
    assert {f"Single {i:02d}" for i in range(0, 30, 2)} <= {a["title"] for a in small}
    assert "Paper Crown" in {a["title"] for a in small}, "EP with one release was not pushed out of the row entirely"
    # Studio albums are never truncated.
    assert [a["title"] for a in albums if a["kind"] == "album"] == ["Low Tide", "Storm Season", "Winter Keys"]
    years = [a["year"] or 0 for a in albums]
    assert years == sorted(years), "inside the page — sorted by year"
