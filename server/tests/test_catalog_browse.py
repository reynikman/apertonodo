"""Catalog (Phase F, G43) — on real PostgreSQL.

What is guarded here and why.

1. Genres — from sections of its torrent list; inside, artists ordered by seeder
   count. Dead releases, "VA" compilations, radio shows, and disc images do not
   enter catalog: everything visible in a genre is playable.
2. Artists A–Z: one artist across three genres — single row.
3. Artist and album pages — from MusicBrainz, but each response is stored
   locally: MusicBrainz goes through a tunnel, and half the requests receive 503.
   Failure is not cached — otherwise page would stay empty forever.
4. Album and song without live release come with `playable: false`, and album
   songs can be directly played via /v1/playback.
5. Cover is taken from release itself and cached locally; no external requests.
6. No release-related words in responses, no names or titles in logs.

Release list and MusicBrainz responses here are fictional, format is authentic.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
import uuid
from pathlib import Path
from typing import Any

import asyncpg
import httpx
import pytest
from fake_extension import running_extension
from fakes import FakeWeb, SeededExtension, photo_routes, pictures
from fastapi import Request
from fastapi.responses import Response
from fastapi.testclient import TestClient
from test_extension_cover import _ext

from app import catalog, images
from app.catalog import artist_of, letter_of
from app.main import create_app
from app.migrate import apply
from app.names import norm

ROCK, ROCK_LOSSY, POP_ROCK, RU_ROCK, RADIOSHOW = 1702, 1703, 1708, 737, 1824

ARTIST = "5b11f4ce-a62d-471e-81fc-a69a8278c7da"
LOW_TIDE = "0e0f1a9c-5f2c-4b4f-9d44-3a1d2f7a0001"
STORM = "0e0f1a9c-5f2c-4b4f-9d44-3a1d2f7a0002"
WINTER = "0e0f1a9c-5f2c-4b4f-9d44-3a1d2f7a0003"
LIVE = "0e0f1a9c-5f2c-4b4f-9d44-3a1d2f7a0004"
PAPER = "0e0f1a9c-5f2c-4b4f-9d44-3a1d2f7a0005"
RELEASE = "7a2b0c11-0000-4000-8000-000000000001"
DELUXE = "7a2b0c11-0000-4000-8000-000000000002"
SONGS = {
    "Northern Lights": "c0ffee00-0000-4000-8000-000000000001",
    "Paper Crown": "c0ffee00-0000-4000-8000-000000000002",
    "Low Tide": "c0ffee00-0000-4000-8000-000000000003",
    "Hidden Song": "c0ffee00-0000-4000-8000-000000000004",
}
JPEG = b"\xff\xd8\xff\xe0" + b"\x00" * 2000

# (topic, section, title, tracklist, seeders)
RELEASES = [
    (201, ROCK, "(Rock) [CD] Glass Harbor - Low Tide - 2004, FLAC (tracks), lossless",
     ["Northern Lights", "Paper Crown", "Low Tide"], 30),
    (202, ROCK_LOSSY, "(Rock) Glass Harbor - Paper Crown (Single) - 2005, MP3, 320 kbps",
     ["Paper Crown"], 5),
    (203, ROCK, "(Rock) Velvet Orchard - Evening Bell - 2010, FLAC (tracks), lossless",
     ["Evening Bell"], 50),
    (204, ROCK, "(Rock) Dead Lantern - Quiet Room - 1999, FLAC (tracks), lossless",
     ["Quiet Room"], 0),
    (205, ROCK, "(Rock) VA - Rock Hits - 2001, MP3, 320 kbps", ["Hit One"], 100),
    (206, RU_ROCK, "(Рок) Ржавый Ключ - Песни ветра - 2003, MP3, 320 kbps", ["Ветер"], 10),
    (207, RADIOSHOW, "(Trance) Mix Master - Radioshow 001 - 2020, MP3", ["Intro"], 40),
    (208, ROCK, "(Rock) Glass Harbor - Storm Season - 2008, APE (image+.cue), lossless",
     ["Storm"], 90),
    (209, POP_ROCK, "(Pop-Rock) Édith Glow - Soft - 2011, MP3, 320 kbps", ["Soft"], 3),
    (210, ROCK, "(Rock) Glass Harbor - Low Tide - 2004, APE (image+.cue), lossless",
     ["Northern Lights"], 200),
    (211, POP_ROCK, "(Pop-Rock) Velvet Orchard - Daylight - 2012, MP3, 320 kbps", ["Day"], 2),
    # A live discography does not mark all consecutive albums playable: trial on
    # full list had marked an album that does not exist at all.
    (212, ROCK_LOSSY, "(Rock) Glass Harbor - Discography - 2004-2008, MP3, 320 kbps",
     ["Low Tide", "Northern Lights"], 7),
]


def _extension() -> SeededExtension:
    return SeededExtension(RELEASES)


async def _seed(url: str) -> None:
    await apply(url)
    # Extension answers "playable" from RELEASES; `catalog_artists` gathers `_extension().build_catalog`.
    catalog.use_extensions(_extension().playable())
    conn = await asyncpg.connect(url)
    try:
        for table in ("catalog_artists", "catalog_built", "album_images", "artist_photos",
                      "metadata_cache", "tracks", "listens", "favorites", "mb_loads", "lastfm_artists", "artist_genre", "artist_country",
                      "our_genre", "catalog_genre_artists", "catalog_genre_artists_state", "mb_artist_alias", "mb_track", "mb_recording", "mb_medium", "mb_release", "mb_release_group", "mb_artist"):
            await conn.execute(f"DELETE FROM {table}")
        await conn.execute("INSERT INTO mb_loads (dump_date, row_counts, duration_ms) VALUES ('2026-01-01', '{}'::jsonb, 1)")
        from app.catalog_genres import OUR_GENRES
        await conn.executemany("INSERT INTO our_genre (slug, name_en, name_ru, sort) VALUES ($1, $2, $3, $4) ON CONFLICT DO NOTHING", list(OUR_GENRES))
        artists = [(ARTIST, "Glass Harbor"), ("5b11f4ce-a62d-471e-81fc-a69a8278c7db", "Velvet Orchard"),
                   ("5b11f4ce-a62d-471e-81fc-a69a8278c7dc", "Ржавый Ключ"), ("5b11f4ce-a62d-471e-81fc-a69a8278c7dd", "Dead Lantern"),
                   ("5b11f4ce-a62d-471e-81fc-a69a8278c7de", "Édith Glow")]
        await conn.executemany("INSERT INTO mb_artist (mbid, name, sort_name, ended) VALUES ($1, $2, $2, false)", artists)
        await conn.executemany("INSERT INTO artist_genre (artist_mbid, slug, source, score, is_primary) VALUES ($1, 'rock', 'seed', 1, true)", [(a[0],) for a in artists])
        await conn.execute("INSERT INTO artist_country (artist_mbid, iso, source) VALUES ($1, 'NO', 'area')", ARTIST)
        await conn.execute("INSERT INTO mb_artist_alias (artist_mbid, name, locale) VALUES ($1, 'Glass Harbors', 'en')", ARTIST)

        groups = [(LOW_TIDE, "Low Tide", "Album", "2004-05-01"), (PAPER, "Paper Crown", "EP", "2005"),
                  (STORM, "Storm Season", "Album", "2008"), (WINTER, "Winter Keys", "Album", "2012-03-01")]
        await conn.executemany("INSERT INTO mb_release_group (mbid, artist_mbid, title, primary_type, first_date) VALUES ($1, $2, $3, $4, $5)",
                               [(g[0], ARTIST, *g[1:]) for g in groups])
        storm_rel, storm_song = "7a2b0c11-0000-4000-8000-000000000003", "c0ffee00-0000-4000-8000-000000000005"
        await conn.executemany("INSERT INTO mb_release (mbid, group_mbid, title, status, country, date) VALUES ($1, $2, $3, 'Official', 'XW', $4)",
                               [(RELEASE, LOW_TIDE, "Low Tide", "2004-05-01"), (storm_rel, STORM, "Storm Season", "2008"),
                                # Every release group in MusicBrainz copy has a release; one song is enough for these two —
                                # an album without songs does not appear on page (FT-538), below.
                                ("7a2b0c11-0000-4000-8000-000000000004", PAPER, "Paper Crown", "2005"),
                                ("7a2b0c11-0000-4000-8000-000000000005", WINTER, "Winter Keys", "2012-03-01")])
        # Remaining artists have one official album each: lists show only those
        # whose page opens with albums (FT-455).
        others = [("5b11f4ce-a62d-471e-81fc-a69a8278c7db", "Evening Bell"), ("5b11f4ce-a62d-471e-81fc-a69a8278c7dc", "Песни ветра"),
                  ("5b11f4ce-a62d-471e-81fc-a69a8278c7dd", "Quiet Room"), ("5b11f4ce-a62d-471e-81fc-a69a8278c7de", "Soft")]
        for n, (artist, title) in enumerate(others, start=11):
            group, release = f"0e0f1a9c-5f2c-4b4f-9d44-3a1d2f7a00{n}", f"7a2b0c11-0000-4000-8000-0000000000{n}"
            await conn.execute("INSERT INTO mb_release_group (mbid, artist_mbid, title, primary_type, first_date) VALUES ($1, $2, $3, 'Album', '2010')",
                               group, artist, title)
            await conn.execute("INSERT INTO mb_release (mbid, group_mbid, title, status, country, date) VALUES ($1, $2, $3, 'Official', 'XW', '2010')",
                               release, group, title)
        await conn.executemany("INSERT INTO mb_medium (id, release_mbid, position, format) VALUES ($1, $2, $3, 'CD')",
                               [(1, RELEASE, 1), (2, RELEASE, 2), (3, storm_rel, 1)])
        # One song for Paper Crown, Winter Keys and remaining artists' albums — recording outside
        # mb_recording so song catalog remains unchanged.
        filler = [("7a2b0c11-0000-4000-8000-000000000004", "Paper Crown"), ("7a2b0c11-0000-4000-8000-000000000005", "Winter Keys")]
        filler += [(f"7a2b0c11-0000-4000-8000-0000000000{n}", title) for n, (_artist, title) in enumerate(others, start=11)]
        for medium, (release, title) in enumerate(filler, start=100):
            await conn.execute("INSERT INTO mb_medium (id, release_mbid, position, format) VALUES ($1, $2, 1, 'CD')", medium, release)
            await conn.execute("INSERT INTO mb_track (mbid, medium_id, recording_mbid, position, title, length_ms) "
                               "VALUES ($1, $2, $3, 1, $4, 200000)", uuid.uuid4(), medium, uuid.uuid4(), title)
        tracks = [(1, 1, "Northern Lights", SONGS["Northern Lights"], 240000), (1, 2, "Paper Crown", SONGS["Paper Crown"], 240000),
                  (2, 3, "Low Tide", SONGS["Low Tide"], 240000), (2, 4, "Hidden Song", SONGS["Hidden Song"], 240000), (3, 1, "Storm", storm_song, 200000)]
        await conn.executemany("INSERT INTO mb_recording (mbid, artist_mbid, title, length_ms) VALUES ($1, $2, $3, $4)",
                               [(sid, ARTIST, sname, ms) for _, _, sname, sid, ms in tracks])
        await conn.executemany("INSERT INTO mb_track (mbid, medium_id, recording_mbid, position, title, length_ms) VALUES ($1, $2, $3, $4, $5, $6)",
                               [(uuid.uuid4(), mid, sid, pos, sname, ms) for mid, pos, sname, sid, ms in tracks])
    finally:
        await conn.close()


async def _fetch(url: str, sql: str, *args: Any) -> list[Any]:
    conn = await asyncpg.connect(url)
    try:
        return await conn.fetch(sql, *args)
    finally:
        await conn.close()


@pytest.fixture
def db(postgres_url: str) -> str:
    asyncio.run(_seed(postgres_url))
    return postgres_url


@pytest.fixture
def built(db: str) -> str:
    asyncio.run(_extension().build_catalog(db))
    return db


def _credit(name: str) -> list[dict[str, Any]]:
    return [{"name": name, "joinphrase": "", "artist": {"id": ARTIST, "name": name}}]


def _track(title: str, length: int | None = 240000) -> dict[str, Any]:
    return {
        "id": "t-" + title,
        "title": title,
        "length": length,
        "recording": {"id": SONGS[title], "title": title, "length": length, "artist-credit": _credit("Glass Harbor")},
    }


MB: dict[str, dict[str, Any]] = {
    "artist": {
        "artists": [
            {"id": "11111111-1111-4111-8111-111111111111", "name": "Glass Harbors", "score": 100},
            {"id": ARTIST, "name": "Glass Harbor", "sort-name": "Glass Harbor", "score": 98},
        ]
    },
    "release-group": {
        "release-group-count": 5,
        "release-groups": [
            {"id": WINTER, "title": "Winter Keys", "first-release-date": "2012-03-01",
             "primary-type": "Album", "secondary-types": []},
            {"id": PAPER, "title": "Paper Crown", "first-release-date": "2005",
             "primary-type": "EP", "secondary-types": []},
            {"id": LIVE, "title": "Live at the Dock", "first-release-date": "2006",
             "primary-type": "Album", "secondary-types": ["Live"]},
            {"id": STORM, "title": "Storm Season", "first-release-date": "2008",
             "primary-type": "Album", "secondary-types": []},
            {"id": LOW_TIDE, "title": "Low Tide", "first-release-date": "2004-05-01",
             "primary-type": "Album", "secondary-types": []},
        ],
    },
    f"release-group/{LOW_TIDE}": {
        "id": LOW_TIDE,
        "title": "Low Tide",
        "first-release-date": "2004-05-01",
        "artist-credit": _credit("Glass Harbor"),
        "releases": [
            {"id": DELUXE, "title": "Low Tide (Deluxe)", "status": "Official", "date": "2003"},
            {"id": RELEASE, "title": "Low Tide", "status": "Official", "date": "2004-05-01"},
        ],
    },
    f"release/{RELEASE}": {
        "id": RELEASE,
        "media": [
            {"position": 1, "tracks": [_track("Northern Lights"), _track("Paper Crown")]},
            {"position": 2, "tracks": [_track("Low Tide"), _track("Hidden Song")]},
        ],
    },
}


class FakeMusicBrainz:
    """MusicBrainz responding from `MB` and recording requested queries."""

    def __init__(self, fail: int = 0) -> None:
        self.calls: list[tuple[str, dict[str, str]]] = []
        self.fail = fail

    async def get_json(self, url: str, params: dict[str, str]) -> dict[str, Any]:
        self.calls.append((url, params))
        if self.fail:
            self.fail -= 1
            request = httpx.Request("GET", url)
            raise httpx.HTTPStatusError("503", request=request, response=httpx.Response(503, request=request))
        return MB[url.removeprefix("https://musicbrainz.org/ws/2/")]


def _app(url: str, mb: Any = None, extensions: dict[str, str] | None = None, pictures: Any = None) -> Any:
    app = create_app(database_url=url, extensions=extensions, pictures=pictures)
    app.state.catalog_pages.http = mb
    return app


def _wait(check: Any, seconds: float = 10.0) -> Any:
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        result = check()
        if result:
            return result
        time.sleep(0.05)
    raise AssertionError("timed out")


# --- 1. genres ---------------------------------------------------------


@pytest.mark.parametrize(
    ("title", "artist"),
    [
        ("(Rock) [CD] Glass Harbor - Low Tide - 2004, FLAC", "Glass Harbor"),
        ("[TR24][OF] WizKid - Made In Lagos - 2020 (Afrobeats, R&B)", "WizKid"),
        ("(Stoner) In The Colonnades (ITC) - Scrap Metal Value - 1991, MP3", "In The Colonnades"),
        ("(Psy-Trance) [WEB] VA - Altered Gravity - 2014, FLAC", None),
        ("(Soundtrack) Jerry Maguire / Джерри Магуайер - 1996, APE (image + .cue)", None),
        ("(Rockabilly) - Go Cat Go! - 1996, MP3", None),
    ],
)
def test_artist_name_comes_from_release_title(title: str, artist: str | None) -> None:
    assert artist_of(title) == artist


def test_letter_folds_accents_and_yo() -> None:
    assert [letter_of(norm(name)) for name in ("Édith", "ёлка", "Кино", "50 Cent", "abba")] == [
        "E", "Е", "К", "#", "A",
    ]


def test_genres_come_from_sections_and_only_what_plays(built: str) -> None:
    with TestClient(_app(built)) as client:
        genres = client.get("/v1/genres").json()["genres"]
        rock = client.get("/v1/artists", params={"genre": "classic-rock"}).json()
    assert len(genres) == 23  # without "Christian" (P-A44)
    assert {item["id"]: item["artists"] for item in genres}["rock"] >= 1
    # Alphabetical, not by popularity (P-A54): Velvet Orchard has more seeders,
    # but G precedes V. Dead Dead Lantern, VA compilation, and radio show do not
    # enter genre.
    assert rock == {
        "artists": [
            {"name": "Glass Harbor", "photo": None},
            {"name": "Velvet Orchard", "photo": None},
        ],
        "total": 2,
    }


def test_genre_artists_page_through(built: str) -> None:
    with TestClient(_app(built)) as client:
        second = client.get("/v1/artists", params={"genre": "classic-rock", "offset": 1, "limit": 1})
        empty = client.get("/v1/artists", params={"genre": "no-such-genre"})
        both = client.get("/v1/artists", params={"genre": "classic-rock", "letter": "G"})
    assert second.json() == {"artists": [{"name": "Velvet Orchard", "photo": None}], "total": 2}
    assert empty.json() == {"artists": [], "total": 0}
    assert both.status_code == 422


def test_letters_cyrillic_first_and_artist_once(built: str) -> None:
    with TestClient(_app(built)) as client:
        letters = client.get("/v1/letters").json()["letters"]
        v = client.get("/v1/artists", params={"letter": "v"}).json()
        r = client.get("/v1/artists", params={"letter": "р"}).json()
    assert letters == [
        {"letter": "Р", "artists": 1},
        {"letter": "E", "artists": 1},
        {"letter": "G", "artists": 1},
        {"letter": "V", "artists": 1},
    ]
    # Velvet Orchard in two genres — appears once in index.
    assert v == {"artists": [{"name": "Velvet Orchard", "photo": None}], "total": 1}
    assert r == {"artists": [{"name": "Ржавый Ключ", "photo": None}], "total": 1}


def test_artists_without_genre_or_letter_start_alphabet(built: str) -> None:
    # Start screen calls /v1/artists without genre and without letter: beginning of
    # global alphabetical list, not an error. Velvet Orchard in two genres —
    # single row. offset/limit paginate the same list.
    with TestClient(_app(built)) as client:
        first = client.get("/v1/artists")
        page = client.get("/v1/artists", params={"offset": 1, "limit": 1})
    assert first.status_code == 200
    names = [item["name"] for item in first.json()["artists"]]
    assert set(names) == {"Édith Glow", "Glass Harbor", "Velvet Orchard", "Ржавый Ключ"}
    assert first.json()["total"] == 4
    # Where "Édith" and "Ржавый" land among them is decided by DB collation: on Mac
    # "é" is next to "e", in CI — after "z". We verify what is identical everywhere:
    # two Latin names are alphabetical, and paging returns the second row
    # of the same list, not another.
    assert names.index("Glass Harbor") < names.index("Velvet Orchard")
    assert page.json() == {"artists": [{"name": names[1], "photo": None}], "total": 4}


def test_artist_list_includes_kept_photo_and_null_when_missing(built: str) -> None:
    asyncio.run(
        _fetch(
            built,
            "INSERT INTO artist_photos (artist_key, mbid, path, author, license) "
            "VALUES ('glass harbor', $1::uuid, 'photos/5b/5b.jpg', 'Ann', 'CC BY')",
            ARTIST,
        )
    )
    with TestClient(_app(built)) as client:
        rock = client.get("/v1/artists", params={"genre": "classic-rock"}).json()
        letter = client.get("/v1/artists", params={"letter": "G"}).json()
    by_name = {row["name"]: row["photo"] for row in rock["artists"]}
    assert by_name["Glass Harbor"] == f"/v1/photos/{ARTIST}"
    assert by_name["Velvet Orchard"] is None
    assert letter == {"artists": [{"name": "Glass Harbor", "photo": f"/v1/photos/{ARTIST}"}], "total": 1}


def test_artist_list_photo_without_credit_is_null(built: str) -> None:
    asyncio.run(
        _fetch(
            built,
            "INSERT INTO artist_photos (artist_key, mbid, path, author, license) "
            "VALUES ('glass harbor', $1::uuid, 'photos/5b/5b.jpg', '', '')",
            ARTIST,
        )
    )
    with TestClient(_app(built)) as client:
        letter = client.get("/v1/artists", params={"letter": "G"}).json()
    assert letter["artists"][0]["photo"] is None


def test_artist_list_does_not_ask_photo_per_row(
    built: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    """List of 20–50 rows — single query for photos, not a query per row."""

    async def boom(*_args: Any, **_kwargs: Any) -> None:
        raise AssertionError("photo_of per row")

    monkeypatch.setattr(images, "photo_of", boom)
    with TestClient(_app(built)) as client:
        rock = client.get("/v1/artists", params={"genre": "classic-rock"}).json()
    assert [row["photo"] for row in rock["artists"]] == [None, None]


def test_artist_list_queues_shown_photos_without_waiting(built: str, tmp_path: Path) -> None:
    web = FakeWeb({})
    shelf = pictures(tmp_path, built, web)
    shelf.last_check = time.monotonic()
    with TestClient(_app(built, None, None, shelf)) as client:
        body = client.get("/v1/artists", params={"letter": "G"}).json()
        assert body["artists"][0]["photo"] is None
    shelf.queue.join()
    assert any("musicbrainz.org" in url for url in web.asked)


def test_genre_catalog_rebuilds_itself_when_empty(db: str) -> None:
    asyncio.run(_fetch(db, "DELETE FROM mb_loads"))
    with TestClient(_app(db)) as client:
        assert client.get("/v1/genres").status_code == 503
        assert client.get("/v1/genres").json() == {"status": "not_ready"}


def test_catalog_without_database_is_unavailable_not_empty() -> None:
    with TestClient(create_app(database_url=None)) as client:
        for path in ("/v1/genres", "/v1/letters", "/v1/artist?name=x", f"/v1/albums/{LOW_TIDE}"):
            assert client.get(path).json() == {"status": "catalog_unavailable"}, path


# --- 2–4. artist, album, "unplayable" ----------------------------------


def test_artist_page_albums_by_year_playable(built: str) -> None:
    with TestClient(_app(built, FakeMusicBrainz())) as client:
        page = client.get("/v1/artist", params={"name": "glass harbor"}).json()
    # Namesake "Glass Harbors" with higher score is ignored: name mismatch.
    assert page["artist"]["id"] == ARTIST and page["artist"]["name"] == "Glass Harbor"
    assert [(a["title"], a["year"], a["playable"], a["kind"]) for a in page["albums"]] == [
        ("Low Tide", 2004, True, "album"),
        ("Paper Crown", 2005, True, "ep"),
        # Release exists, but disc image only — phone cannot play it.
        ("Storm Season", 2008, False, "album"),
        # No release at all, although artist has live discography.
        ("Winter Keys", 2012, False, "album"),
    ]
    assert all(album["cover"] is None for album in page["albums"])
    # No image catalog — no photos either, but page is intact.
    assert page["artist"]["photo"] is None and page["artist"]["photo_credit"] is None


def test_ep_with_the_album_title_is_not_a_second_album(built: str) -> None:
    """Owner's finding 01.10: Metallica has two "2003 · St. Anger" — album and EP
    (CD single) with same title. EP or single sharing title with artist's album
    is hidden; two albums with same title (Weezer has five, by
    years) both remain."""

    async def more_groups() -> None:
        conn = await asyncpg.connect(built)
        try:
            extra = [
                ("0e0f1a9c-5f2c-4b4f-9d44-3a1d2f7a0101", "LOW TIDE", "EP", "2004-03-01"),
                ("0e0f1a9c-5f2c-4b4f-9d44-3a1d2f7a0102", "Storm Season", "Album", "2015"),
            ]
            await conn.executemany(
                "INSERT INTO mb_release_group (mbid, artist_mbid, title, primary_type, first_date) "
                "VALUES ($1, $2, $3, $4, $5)",
                [(g[0], ARTIST, *g[1:]) for g in extra],
            )
            await conn.executemany(
                "INSERT INTO mb_release (mbid, group_mbid, title, status, country, date) "
                "VALUES ($1, $2, $3, 'Official', 'XW', $4)",
                [
                    ("7a2b0c11-0000-4000-8000-000000000101", extra[0][0], "Low Tide", "2004-03-01"),
                    ("7a2b0c11-0000-4000-8000-000000000102", extra[1][0], "Storm Season", "2015"),
                ],
            )
            # Album without songs does not appear on page (FT-538).
            for medium, release in enumerate(("7a2b0c11-0000-4000-8000-000000000101", "7a2b0c11-0000-4000-8000-000000000102"), start=400):
                await conn.execute("INSERT INTO mb_medium (id, release_mbid, position, format) VALUES ($1, $2, 1, 'CD')", medium, release)
                await conn.execute("INSERT INTO mb_track (mbid, medium_id, recording_mbid, position, title, length_ms) "
                                   "VALUES (gen_random_uuid(), $1, gen_random_uuid(), 1, 'Intro', 200000)", medium)
        finally:
            await conn.close()

    asyncio.run(more_groups())
    with TestClient(_app(built, FakeMusicBrainz())) as client:
        page = client.get("/v1/artist", params={"name": "glass harbor"}).json()
    assert [(a["title"], a["year"], a["kind"]) for a in page["albums"]] == [
        ("Low Tide", 2004, "album"),
        ("Paper Crown", 2005, "ep"),
        ("Storm Season", 2008, "album"),
        ("Winter Keys", 2012, "album"),
        ("Storm Season", 2015, "album"),
    ]


def test_artist_by_name_prefers_the_namesake_with_releases(built: str) -> None:
    # Namesake with smaller mbid and no releases: first match would be it, leaving page empty.
    namesake = "00000000-0000-4000-8000-00000000000a"
    asyncio.run(_fetch(built, "INSERT INTO mb_artist (mbid, name, sort_name, ended) VALUES ($1, 'Glass Harbor', 'Glass Harbor', false)", namesake))
    with TestClient(_app(built, FakeMusicBrainz())) as client:
        page = client.get("/v1/artist", params={"name": "Glass Harbor"}).json()
    assert page["artist"]["id"] == ARTIST and len(page["albums"]) == 4


def test_genre_of_the_copy_lists_its_artists(built: str) -> None:
    with TestClient(_app(built)) as client:
        genres = {item["id"]: item["artists"] for item in client.get("/v1/genres").json()["genres"]}
        rock = client.get("/v1/artists", params={"genre": "rock"}).json()
        second = client.get("/v1/artists", params={"genre": "rock", "offset": 1, "limit": 1}).json()
    # Same four that /v1/genres counts; alphabetical, Latin before Cyrillic (P-A54),
    # legacy catalog popularity does not alter ordering. Dead Lantern exists in copy genre, but
    # its release is dead — not in lists (P-A66, FT-543).
    assert genres["rock"] == rock["total"] == 4
    assert [a["name"] for a in rock["artists"]] == ["Édith Glow", "Glass Harbor", "Velvet Orchard", "Ржавый Ключ"]
    assert second == {"artists": [{"name": "Glass Harbor", "photo": None}], "total": 4}


def test_unknown_artist_is_not_found(built: str) -> None:
    mb = FakeMusicBrainz()
    with TestClient(_app(built, mb)) as client:
        mb.get_json = _answer({"artists": []}, mb)  # type: ignore[method-assign]
        assert client.get("/v1/artist", params={"name": "Nobody Here"}).status_code == 404


def _answer(payload: dict[str, Any], mb: FakeMusicBrainz) -> Any:
    async def get_json(url: str, params: dict[str, str]) -> dict[str, Any]:
        mb.calls.append((url, params))
        return payload

    return get_json


def test_album_page_tracklist_playable_and_playable_via_playback(built: str) -> None:
    with TestClient(_app(built, FakeMusicBrainz())) as client:
        page = client.get(f"/v1/albums/{LOW_TIDE}").json()
        play = client.post("/v1/playback", json={"track_id": SONGS["Hidden Song"]})
    assert page["album"] == {
        "id": LOW_TIDE,
        "title": "Low Tide",
        "artist": "Glass Harbor",
        "year": 2004,
        "date": "2004-05-01",
        "playable": True,
        "disc": "CD",
        "cover": None,
    }
    assert [(t["position"], t["title"], t["playable"]) for t in page["tracks"]] == [
        (1, "Northern Lights", True),
        (2, "Paper Crown", True),
        (3, "Low Tide", True),
        # Song is absent from titles and tracklists of artist releases.
        (4, "Hidden Song", False),
    ]
    assert page["tracks"][0]["id"] == SONGS["Northern Lights"]
    assert page["tracks"][0]["duration_ms"] == 240000
    # Server recognizes displayed track: rejection is "source not found", not 404.
    assert play.status_code == 409, play.text
    rows = asyncio.run(_fetch(built, "SELECT count(*) AS n FROM tracks"))
    assert rows[0]["n"] == 4



def test_album_edition_is_official_same_title_earliest(built: str) -> None:
    with TestClient(_app(built)) as client:
        album = client.get(f"/v1/albums/{LOW_TIDE}").json()
    assert album["album"]["id"] == LOW_TIDE
    assert album["album"]["title"] == "Low Tide"


def test_musicbrainz_answers_are_kept_and_not_asked_again(built: str) -> None:
    first = FakeMusicBrainz()
    with TestClient(_app(built, first)) as client:
        artist = client.get("/v1/artist", params={"name": "Glass Harbor"}).json()
        album = client.get(f"/v1/albums/{LOW_TIDE}").json()
    assert len(first.calls) == 0
    assert artist["artist"]["name"] == "Glass Harbor"
    assert album["album"]["id"] == LOW_TIDE


def test_musicbrainz_refusal_is_not_kept(built: str) -> None:
    asyncio.run(_fetch(built, "DELETE FROM mb_loads"))
    with TestClient(_app(built)) as client:
        refused = client.get("/v1/artist", params={"name": "Glass Harbor"})
    assert refused.status_code == 503
    assert refused.json() == {"status": "not_ready"}


def test_catalog_without_musicbrainz_serves_only_what_is_kept(built: str) -> None:
    with TestClient(_app(built, None)) as client:
        assert client.get("/v1/artist", params={"name": "Glass Harbor"}).status_code == 200


# --- 5. covers -----------------------------------------------------------
#
# Phase K details — in tests/test_images.py: queue, artist photo,
# author attribution and nightly robot. Here — what is visible from page side.


def test_cover_comes_from_the_archive_first(built: str, tmp_path: Path) -> None:
    """Source priority: Cover Art Archive, only then release."""
    web = FakeWeb({"coverartarchive.org": JPEG})
    mb = FakeMusicBrainz()
    with TestClient(_app(built, mb, None, pictures(tmp_path, built, web))) as client:
        assert client.get(f"/v1/albums/{LOW_TIDE}").json()["album"]["cover"] is None
        image = _wait(lambda: (r := client.get(f"/v1/covers/{LOW_TIDE}")).status_code == 200 and r)
        album = client.get(f"/v1/albums/{LOW_TIDE}").json()["album"]
    assert image.content == JPEG
    assert image.headers["content-type"] == "image/jpeg"
    assert album["cover"] == f"/v1/covers/{LOW_TIDE}"
    # Front cover requested for release group — using same MBID as album.
    assert web.asked == [f"https://coverartarchive.org/release-group/{LOW_TIDE}/front-500"]
    # Did not check release at all: archive responded.
    assert all("musicbrainz.org/ws/2/" in url for url, _ in mb.calls)


def _cover_extension(asked: list[dict[str, Any]]) -> Any:
    """Extension with cover and "playable" response to everything: cover fallback routes to it."""
    ext_app = _ext(["cover", "has"], Response(JPEG, media_type="image/jpeg"), asked)

    @ext_app.post("/v1/has")
    async def has(request: Request) -> dict[str, Any]:
        return {"hits": [True for _ in (await request.json())["pairs"]]}

    return ext_app


def test_cover_falls_back_to_the_extension_when_the_archive_has_none(
    built: str, tmp_path: Path
) -> None:
    asked: list[dict[str, Any]] = []
    web = FakeWeb({"coverartarchive.org": 404})
    ext_app = _cover_extension(asked)

    with running_extension(ext_app) as url:
        shelf = pictures(tmp_path, built, web)
        with TestClient(_app(built, FakeMusicBrainz(), {"bt": url}, shelf)) as client:
            client.get(f"/v1/albums/{LOW_TIDE}")
            got = _wait(lambda: (r := client.get(f"/v1/covers/{LOW_TIDE}")).status_code == 200 and r)
    assert got.content == JPEG
    assert asked == [{"artist": "Glass Harbor", "title": "Low Tide"}]


def test_album_without_any_cover_is_not_asked_again(
    built: str, tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    caplog.set_level(logging.INFO, logger="apertonodo")
    web = FakeWeb({"coverartarchive.org": 404})
    shelf = pictures(tmp_path, built, web)
    with TestClient(_app(built, FakeMusicBrainz(), None, shelf)) as client:
        client.get(f"/v1/albums/{LOW_TIDE}")
        shelf.queue.join()
        again = client.get(f"/v1/albums/{LOW_TIDE}").json()["album"]
        shelf.queue.join()
        missing = client.get(f"/v1/covers/{LOW_TIDE}")
    assert len(web.asked) == 1
    assert again["cover"] is None
    assert missing.status_code == 404
    assert "cover: none in" in caplog.text
    assert "low tide" not in caplog.text.casefold()


def _storm_album(monkeypatch: pytest.MonkeyPatch) -> None:
    """Song "Storm" is only in disc image: album is unplayable."""
    storm_release = "7a2b0c11-0000-4000-8000-000000000003"
    storm_song = "c0ffee00-0000-4000-8000-000000000005"
    monkeypatch.setitem(MB, f"release-group/{STORM}", {
        "id": STORM, "title": "Storm Season", "first-release-date": "2008",
        "artist-credit": _credit("Glass Harbor"),
        "releases": [{"id": storm_release, "title": "Storm Season", "status": "Official"}],
    })
    monkeypatch.setitem(MB, f"release/{storm_release}", {"media": [{"tracks": [{
        "title": "Storm", "length": 200000,
        "recording": {"id": storm_song, "title": "Storm", "length": 200000},
    }]}]})


def test_pale_album_takes_its_cover_from_the_archive_only(
    built: str, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """P-A37 (01.10): dimmed album also has a cover — from Cover Art Archive by MBID.

    Previously unplayable album did not look for cover at all ("nowhere to fetch from"), and
    Pantera "Hostile Moments" stood as gray square (finding 30.09). Archive does not
    need release; dimmed album does not check release for cover.jpg — none exists.
    """
    _storm_album(monkeypatch)
    web = FakeWeb({"coverartarchive.org": JPEG})
    with TestClient(_app(built, FakeMusicBrainz(), None, pictures(tmp_path, built, web))) as client:
        page = client.get(f"/v1/albums/{STORM}").json()
        image = _wait(lambda: (r := client.get(f"/v1/covers/{STORM}")).status_code == 200 and r)
        again = client.get(f"/v1/albums/{STORM}").json()
    assert page["album"]["playable"] is False
    assert image.content == JPEG
    assert again["album"]["cover"] == f"/v1/covers/{STORM}"
    assert web.asked == [f"https://coverartarchive.org/release-group/{STORM}/front-500"]


def test_artist_page_orders_covers_for_pale_albums_too(
    built: str, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Album grid on artist page requests covers for all, not just playable."""
    _storm_album(monkeypatch)
    web = FakeWeb({"coverartarchive.org": JPEG})
    with TestClient(_app(built, FakeMusicBrainz(), None, pictures(tmp_path, built, web))) as client:
        albums = client.get("/v1/artist", params={"name": "Glass Harbor"}).json()["albums"]
        storm = next(a for a in albums if a["id"] == STORM)
        assert storm["playable"] is False
        _wait(lambda: client.get(f"/v1/covers/{STORM}").status_code == 200)
        albums = client.get("/v1/artist", params={"name": "Glass Harbor"}).json()["albums"]
    assert next(a for a in albums if a["id"] == STORM)["cover"] == f"/v1/covers/{STORM}"
    assert f"https://coverartarchive.org/release-group/{STORM}/front-500" in web.asked


def test_pale_album_without_archive_cover_stays_plain_and_is_not_asked_again(
    built: str, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _storm_album(monkeypatch)
    web = FakeWeb({"coverartarchive.org": 404})
    shelf = pictures(tmp_path, built, web)
    with TestClient(_app(built, FakeMusicBrainz(), None, shelf)) as client:
        client.get(f"/v1/albums/{STORM}")
        shelf.queue.join()
        client.get(f"/v1/albums/{STORM}")
        shelf.queue.join()
        missing = client.get(f"/v1/covers/{STORM}")
    assert missing.status_code == 404
    assert len(web.asked) == 1


# --- 6. words and logs ---------------------------------------------------

FORBIDDEN = ("torrent", "magnet", "tracker", "seed", "info_hash", "infohash", "btih", "topic", "forum", "rqbit", "source")


def test_catalog_answers_have_no_words_about_releases(built: str, tmp_path: Path) -> None:
    web = FakeWeb({"coverartarchive.org": JPEG, **photo_routes(ARTIST, JPEG)})
    with TestClient(_app(built, FakeMusicBrainz(), None, pictures(tmp_path, built, web))) as client:
        bodies = [
            client.get("/v1/genres").text,
            client.get("/v1/letters").text,
            client.get("/v1/artists", params={"genre": "classic-rock"}).text,
            client.get("/v1/artists", params={"letter": "G"}).text,
            client.get("/v1/artist", params={"name": "Glass Harbor"}).text,
            client.get("/v1/artist/songs", params={"name": "Glass Harbor"}).text,
            client.get(f"/v1/albums/{LOW_TIDE}").text,
        ]
        schema = client.get("/openapi.json").json()
    catalog_paths = {
        path: spec for path, spec in schema["paths"].items()
        if path.startswith(
            ("/v1/genres", "/v1/letters", "/v1/artist", "/v1/albums", "/v1/covers", "/v1/photos")
        )
    }
    assert len(catalog_paths) == 9  # FT-859: /v1/covers/podcast/image
    for text in [*bodies, str(catalog_paths)]:
        for word in FORBIDDEN:
            assert word not in text.casefold(), (word, text[:200])


def test_catalog_log_has_no_names_or_titles(
    built: str, tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    caplog.set_level(logging.INFO, logger="apertonodo")
    web = FakeWeb({"coverartarchive.org": JPEG, **photo_routes(ARTIST, JPEG)})
    shelf = pictures(tmp_path, built, web)
    with TestClient(_app(built, FakeMusicBrainz(fail=1), None, shelf)) as client:
        client.get("/v1/artist", params={"name": "Glass Harbor"})
        client.get("/v1/artist", params={"name": "Glass Harbor"})
        client.get(f"/v1/albums/{LOW_TIDE}")
        shelf.queue.join()
        asyncio.run(_extension().build_catalog(built))
    text = caplog.text.casefold()
    # Positive control: catalog and image log lines are present in log.
    assert "cover: stored" in text
    assert "photo: stored with credit" in text
    assert "catalog_from_extensions: built" in text
    for secret in ("glass", "harbor", "low tide", "northern", "paper crown", "velvet", "folder.jpg", ARTIST):
        assert secret not in text, secret


# --- response shapes: samples for client live in contracts/ ---------------

CONTRACTS = Path(__file__).resolve().parents[2] / "contracts"


def _shape(value: Any) -> Any:
    if isinstance(value, dict):
        return {key: _shape(item) for key, item in value.items()}
    if isinstance(value, list):
        return [_shape(value[0])] if value else []
    return "number" if isinstance(value, int) and not isinstance(value, bool) else type(value).__name__


def test_catalog_answers_match_contracts(built: str, tmp_path: Path) -> None:
    web = FakeWeb({"coverartarchive.org": JPEG, **photo_routes(ARTIST, JPEG)})
    shelf = pictures(tmp_path, built, web)
    with TestClient(_app(built, FakeMusicBrainz(), None, shelf)) as client:
        client.get(f"/v1/albums/{LOW_TIDE}")
        client.get("/v1/artist", params={"name": "Glass Harbor"})
        shelf.queue.join()
        answers = {
            "genres": client.get("/v1/genres").json(),
            "letters": client.get("/v1/letters").json(),
            "artists": client.get("/v1/artists", params={"genre": "classic-rock"}).json(),
            "artist": client.get("/v1/artist", params={"name": "Glass Harbor"}).json(),
            "album": client.get(f"/v1/albums/{LOW_TIDE}").json(),
        }
    for name, answer in answers.items():
        contract = json.loads((CONTRACTS / f"catalog-{name}.response.json").read_text())
        if name == "genres":
            for g in answer["genres"]:
                g.pop("name_ru", None)
        if name == "artists":
            # Sample is row without photo; alphabetically (P-A54) Glass Harbor with photo came first.
            answer["artists"] = [a for a in answer["artists"] if a["photo"] is None]
        assert _shape(answer) == _shape(contract), name


def test_production_app_singleton(monkeypatch: pytest.MonkeyPatch) -> None:
    import app.main as m

    monkeypatch.setenv("MUSIC_API_KEY", "k" * 32)
    m.__dict__.pop("app", None)
    try:
        assert m.app is m.app
    finally:
        m.__dict__.pop("app", None)


def test_earliest_release_disc_format(built: str) -> None:
    group_id = "0e0f1a9c-5f2c-4b4f-9d44-3a1d2f7a0099"
    rel_early = "7a2b0c11-0000-4000-8000-000000000091"
    rel_late = "7a2b0c11-0000-4000-8000-000000000092"

    async def add_releases() -> None:
        conn = await asyncpg.connect(built)
        try:
            await conn.execute(
                "INSERT INTO mb_release_group (mbid, artist_mbid, title, primary_type, first_date) "
                "VALUES ($1::uuid, $2::uuid, 'Dual Release Album', 'Album', '2001-01-01')",
                group_id,
                ARTIST,
            )
            await conn.executemany(
                "INSERT INTO mb_release (mbid, group_mbid, title, status, country, date) "
                "VALUES ($1::uuid, $2::uuid, $3, 'Official', 'XW', $4)",
                [
                    (rel_early, group_id, "Dual Release (Early)", "2001-01-01"),
                    (rel_late, group_id, "Dual Release (Late)", "2010-01-01"),
                ],
            )
            await conn.executemany(
                "INSERT INTO mb_medium (id, release_mbid, position, format) VALUES ($1, $2::uuid, 1, $3)",
                [
                    (901, rel_early, "Vinyl"),
                    (902, rel_late, "Digital Media"),
                ],
            )
            # Album without songs does not appear on page (FT-538).
            await conn.executemany(
                "INSERT INTO mb_track (mbid, medium_id, recording_mbid, position, title, length_ms) "
                "VALUES (gen_random_uuid(), $1, gen_random_uuid(), 1, 'Dual', 200000)",
                [(901,), (902,)],
            )
        finally:
            await conn.close()

    asyncio.run(add_releases())
    with TestClient(_app(built)) as client:
        artist_res = client.get("/v1/artist", params={"name": "Glass Harbor"}).json()
        albums = {a["id"]: a for a in artist_res["albums"]}
        assert albums[group_id]["disc"] == "Vinyl"

        album_res = client.get(f"/v1/albums/{group_id}").json()
        assert album_res["album"]["disc"] == "Vinyl"


def test_same_year_cd_wins_over_vinyl_sides(built: str) -> None:
    """Adele "30" (30.09): same-day vinyl gave sides 1–6, 1–6. Same year — CD."""
    group_id = "0e0f1a9c-5f2c-4b4f-9d44-3a1d2f7a00b1"
    vinyl, cd = "7a2b0c11-0000-4000-8000-0000000000b1", "7a2b0c11-0000-4000-8000-0000000000b2"
    rec_a, rec_b = "7a2b0c11-0000-4000-8000-0000000000c1", "7a2b0c11-0000-4000-8000-0000000000c2"

    async def add_releases() -> None:
        conn = await asyncpg.connect(built)
        try:
            await conn.execute(
                "INSERT INTO mb_release_group (mbid, artist_mbid, title, primary_type, first_date) "
                "VALUES ($1::uuid, $2::uuid, 'Sides Album', 'Album', '2021-11-19')",
                group_id,
                ARTIST,
            )
            await conn.executemany(
                "INSERT INTO mb_release (mbid, group_mbid, title, status, country, date) "
                "VALUES ($1::uuid, $2::uuid, 'Sides Album', 'Official', 'XW', $3)",
                [(vinyl, group_id, "2021-11-19"), (cd, group_id, "2021-11-19")],
            )
            await conn.executemany(
                "INSERT INTO mb_medium (id, release_mbid, position, format) VALUES ($1, $2::uuid, $3, $4)",
                [(911, vinyl, 1, '12" Vinyl'), (912, vinyl, 2, '12" Vinyl'), (913, cd, 1, "CD")],
            )
            await conn.executemany(
                "INSERT INTO mb_track (mbid, medium_id, recording_mbid, position, title, length_ms) "
                "VALUES (gen_random_uuid(), $1, $2::uuid, $3, $4, 200000)",
                [
                    (911, rec_a, 1, "Side A Song"),
                    (912, rec_b, 1, "Side B Song"),
                    (913, rec_a, 1, "Side A Song"),
                    (913, rec_b, 2, "Side B Song"),
                ],
            )
        finally:
            await conn.close()

    asyncio.run(add_releases())
    with TestClient(_app(built)) as client:
        album = client.get(f"/v1/albums/{group_id}").json()
        artist = client.get("/v1/artist", params={"name": "Glass Harbor"}).json()
    assert album["album"]["disc"] == "CD"
    assert [(t["position"], t["title"]) for t in album["tracks"]] == [(1, "Side A Song"), (2, "Side B Song")]
    assert {a["id"]: a for a in artist["albums"]}[group_id]["disc"] == "CD"


def test_discography_hides_groups_without_an_official_release(built: str) -> None:
    """Bootlegs and promos are not discography: Metallica had "Plays the Ramones" and "Live in Concert"."""
    bootleg, promo = "0e0f1a9c-5f2c-4b4f-9d44-3a1d2f7a00a1", "0e0f1a9c-5f2c-4b4f-9d44-3a1d2f7a00a2"

    async def add() -> None:
        conn = await asyncpg.connect(built)
        try:
            await conn.executemany(
                "INSERT INTO mb_release_group (mbid, artist_mbid, title, primary_type, first_date) VALUES ($1::uuid, $2::uuid, $3, 'Album', '2003')",
                [(bootleg, ARTIST, "Basement Tapes"), (promo, ARTIST, "Radio Sampler")],
            )
            await conn.executemany(
                "INSERT INTO mb_release (mbid, group_mbid, title, status, date) VALUES ($1::uuid, $2::uuid, $3, $4, '2003')",
                [("7a2b0c11-0000-4000-8000-0000000000a1", bootleg, "Basement Tapes", "Bootleg"),
                 ("7a2b0c11-0000-4000-8000-0000000000a2", promo, "Radio Sampler", "Promotion")],
            )
        finally:
            await conn.close()

    asyncio.run(add())
    with TestClient(_app(built)) as client:
        titles = [a["title"] for a in client.get("/v1/artist", params={"name": "Glass Harbor"}).json()["albums"]]
    assert titles == ["Low Tide", "Paper Crown", "Storm Season", "Winter Keys"]


def test_album_tracklist_from_official_edition_with_recording_length(built: str) -> None:
    """Previously tracklist was taken from earliest release — bootleg or release without durations,
    and whole album was dimmed ("72 Seasons"). Duration is on recording if missing from release."""
    group = "0e0f1a9c-5f2c-4b4f-9d44-3a1d2f7a00b1"
    bootleg, official = "7a2b0c11-0000-4000-8000-0000000000b1", "7a2b0c11-0000-4000-8000-0000000000b2"
    taped, song = "c0ffee00-0000-4000-8000-0000000000b1", SONGS["Northern Lights"]

    async def add() -> None:
        conn = await asyncpg.connect(built)
        try:
            await conn.execute(
                "INSERT INTO mb_release_group (mbid, artist_mbid, title, primary_type, first_date) VALUES ($1::uuid, $2::uuid, 'Lights', 'Album', '1999')",
                group, ARTIST,
            )
            await conn.executemany(
                "INSERT INTO mb_release (mbid, group_mbid, title, status, date) VALUES ($1::uuid, $2::uuid, 'Lights', $3, $4)",
                [(bootleg, group, "Bootleg", "1999"), (official, group, "Official", "2000")],
            )
            await conn.executemany("INSERT INTO mb_medium (id, release_mbid, position, format) VALUES ($1, $2::uuid, 1, 'CD')",
                                   [(911, bootleg), (912, official)])
            await conn.execute("INSERT INTO mb_recording (mbid, artist_mbid, title, length_ms) VALUES ($1::uuid, $2::uuid, 'Taped Jam', 1000)", taped, ARTIST)
            await conn.executemany(
                "INSERT INTO mb_track (mbid, medium_id, recording_mbid, position, title, length_ms) VALUES ($1, $2, $3::uuid, 1, $4, NULL)",
                [(uuid.uuid4(), 911, taped, "Taped Jam"), (uuid.uuid4(), 912, song, "Northern Lights")],
            )
        finally:
            await conn.close()

    asyncio.run(add())
    with TestClient(_app(built, FakeMusicBrainz())) as client:
        page = client.get(f"/v1/albums/{group}").json()
    assert [(t["title"], t["duration_ms"], t["playable"]) for t in page["tracks"]] == [("Northern Lights", 240000, True)]
    assert page["album"]["playable"] is True


def test_genres_country_unknown(built: str) -> None:
    with TestClient(_app(built)) as client:
        res_no = client.get("/v1/genres", params={"country": "NO"}).json()
        assert {g["id"]: g["artists"] for g in res_no["genres"]}["rock"] == 1

        # Without country — three with release; Dead Lantern (dead release) not counted (P-A66, FT-543).
        res_unk = client.get("/v1/genres", params={"country": "unknown"}).json()
        assert {g["id"]: g["artists"] for g in res_unk["genres"]}["rock"] == 3
