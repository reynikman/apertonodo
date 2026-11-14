"""Whoever the list shows, the page opens (FT-455).

Nightly check of production on 30.09 opened an artist from each list: 45
opened with 404 or without a single album. Letter lists take names
from release titles ("Невеста! / The Bride!", "Щедрин"), but the page searches
the name in the MusicBrainz copy — which does not have it. In copy genres, a third
of artists have no official album (116k out of 348k), and the page is empty.

One rule for all lists — letters, common alphabet, genres: a name is in the list
only if /v1/artist responds 200 with at least one album. And the count matches
the list: /v1/letters and /v1/genres count the same artists they show.
The page finds an artist by alias too — do not remove such artists from the list.
"""

from __future__ import annotations

import asyncio
from typing import Any

import asyncpg
from fastapi.testclient import TestClient
from fakes import SeededExtension
from test_catalog_browse import RELEASES, ROCK, _app, _seed

from app import catalog

KINO = "6c0a2c1e-0000-4000-8000-000000000001"
PAVLOVA = "6c0a2c1e-0000-4000-8000-000000000002"
ALVIN = "6c0a2c1e-0000-4000-8000-000000000003"
GHOST = "6c0a2c1e-0000-4000-8000-000000000009"

# (topic, title, tracklist, seeders)
EXTRA = [
    # Soundtrack: no artist name in title, and parsing picked up the movie title.
    (301, "(Soundtrack) Невеста! / The Bride! - Soundtrack - 2026, MP3, 320 kbps", ["Theme"], 20),
    # Present in the copy, but no official albums — single only.
    (302, "(Rock) Яна Павлова - Тишина - 2019, MP3, 320 kbps", ["Тишина"], 15),
    # Called "Кино" in the copy; "Kino" is an alias, and the page opens with it.
    (303, "(Rock) Kino - Звезда по имени Солнце - 1989, FLAC (tracks), lossless", ["Звезда по имени Солнце"], 25),
]


async def _extra(url: str) -> None:
    conn = await asyncpg.connect(url)
    try:
        await conn.executemany("INSERT INTO mb_artist (mbid, name, sort_name, ended) VALUES ($1, $2, $3, false)",
                               [(KINO, "Кино", "Кино"), (PAVLOVA, "Яна Павлова", "Павлова, Яна"), (ALVIN, "Alvin Cash", "Cash, Alvin")])
        await conn.execute("INSERT INTO mb_artist_alias (artist_mbid, name, locale) VALUES ($1, 'Kino', 'en')", KINO)
        # Alvin Cash — in copy genre, but without albums: singles only.
        await conn.execute("INSERT INTO artist_genre (artist_mbid, slug, source, score, is_primary) VALUES ($1, 'rock', 'seed', 1, true)", ALVIN)
        groups = [
            ("0e0f1a9c-5f2c-4b4f-9d44-3a1d2f7a0101", KINO, "Звезда по имени Солнце", "Album"),
            ("0e0f1a9c-5f2c-4b4f-9d44-3a1d2f7a0102", PAVLOVA, "Тишина", "Single"),
            ("0e0f1a9c-5f2c-4b4f-9d44-3a1d2f7a0103", ALVIN, "Twine Time", "Single"),
        ]
        await conn.executemany(
            "INSERT INTO mb_release_group (mbid, artist_mbid, title, primary_type, first_date) VALUES ($1, $2, $3, $4, '1989')", groups
        )
        await conn.executemany(
            "INSERT INTO mb_release (mbid, group_mbid, title, status, country, date) VALUES ($1, $2, $3, 'Official', 'XW', '1989')",
            [(f"7a2b0c11-0000-4000-8000-00000000010{n}", group, title) for n, (group, _a, title, _k) in enumerate(groups, start=1)],
        )
        # One song per release: an album without songs does not reach the page (FT-538).
        for medium, release in enumerate([f"7a2b0c11-0000-4000-8000-00000000010{n}" for n in range(1, len(groups) + 1)], start=200):
            await conn.execute("INSERT INTO mb_medium (id, release_mbid, position, format) VALUES ($1, $2, 1, 'CD')", medium, release)
            await conn.execute("INSERT INTO mb_track (mbid, medium_id, recording_mbid, position, title, length_ms) "
                               "VALUES (gen_random_uuid(), $1, gen_random_uuid(), 1, 'Intro', 200000)", medium)
        # Ghost — in copy genre, with an album, but the album has no songs: absent from lists,
        # otherwise the page would open empty (FT-538).
        await conn.execute("INSERT INTO mb_artist (mbid, name, sort_name, ended) VALUES ($1, 'Ghost Empty', 'Ghost Empty', false)", GHOST)
        await conn.execute("INSERT INTO artist_genre (artist_mbid, slug, source, score, is_primary) VALUES ($1, 'rock', 'seed', 1, true)", GHOST)
        await conn.execute("INSERT INTO mb_release_group (mbid, artist_mbid, title, primary_type, first_date) "
                           "VALUES ('0e0f1a9c-5f2c-4b4f-9d44-3a1d2f7a0109', $1, 'Hollow', 'Album', '1989')", GHOST)
        await conn.execute("INSERT INTO mb_release (mbid, group_mbid, title, status, country, date) VALUES "
                           "('7a2b0c11-0000-4000-8000-000000000109', '0e0f1a9c-5f2c-4b4f-9d44-3a1d2f7a0109', 'Hollow', 'Official', 'XW', '1989')")
        await conn.execute("INSERT INTO mb_medium (id, release_mbid, position, format) VALUES (209, '7a2b0c11-0000-4000-8000-000000000109', 1, 'CD')")
    finally:
        await conn.close()


def _extension() -> SeededExtension:
    return SeededExtension(RELEASES + [(topic, ROCK, title, tracks, seeders) for topic, title, tracks, seeders in EXTRA])


def _built(postgres_url: str) -> str:
    asyncio.run(_seed(postgres_url))
    asyncio.run(_extra(postgres_url))
    asyncio.run(_extension().build_catalog(postgres_url))
    catalog.use_extensions(_extension().playable())
    return postgres_url


def _names(client: TestClient, **params: Any) -> tuple[list[str], int]:
    body = client.get("/v1/artists", params={**params, "limit": 500}).json()
    return [item["name"] for item in body["artists"]], body["total"]


def _opens(client: TestClient, name: str) -> str:
    """Empty string if the page opened with albums; otherwise what went wrong."""
    page = client.get("/v1/artist", params={"name": name})
    if page.status_code != 200:
        return f"{name}: HTTP {page.status_code}"
    return "" if page.json()["albums"] else f"{name}: no albums"


def test_every_listed_artist_opens_with_albums(postgres_url: str) -> None:
    url = _built(postgres_url)
    broken: list[str] = []
    with TestClient(_app(url)) as client:
        lists: dict[str, tuple[list[str], int]] = {"alphabet": _names(client)}
        for row in client.get("/v1/letters").json()["letters"]:
            names, total = lists[f"letter {row['letter']}"] = _names(client, letter=row["letter"])
            if row["artists"] != total:
                broken.append(f"letter {row['letter']}: /v1/letters says {row['artists']}, list total {total}")
        for row in client.get("/v1/genres").json()["genres"]:
            if row["artists"]:
                names, total = lists[f"genre {row['id']}"] = _names(client, genre=row["id"])
                if row["artists"] != total:
                    broken.append(f"genre {row['id']}: /v1/genres says {row['artists']}, list total {total}")
        for where, (names, total) in lists.items():
            if len(names) != total:
                broken.append(f"{where}: {len(names)} names, total {total}")
            broken.extend(f"{where}: {problem}" for name in names if (problem := _opens(client, name)))
    assert broken == [], "\n".join(broken)


def test_lists_drop_names_the_page_cannot_open(postgres_url: str) -> None:
    url = _built(postgres_url)
    with TestClient(_app(url)) as client:
        letters = {row["letter"] for row in client.get("/v1/letters").json()["letters"]}
        alphabet, _ = _names(client)
        rock, _ = _names(client, genre="rock")
    listed = set(alphabet) | set(rock)
    assert "Невеста! / The Bride!" not in listed
    assert "Яна Павлова" not in listed
    assert "Alvin Cash" not in listed
    # A letter that had only such names disappears entirely from the index.
    assert "Н" not in letters and "Я" not in letters


def test_alias_name_stays_listed(postgres_url: str) -> None:
    # Do not overdo it: "Kino" in the copy is an alias of "Кино", and the page opens
    # with an album. Do not remove such an artist from the list.
    url = _built(postgres_url)
    with TestClient(_app(url)) as client:
        k, total = _names(client, letter="K")
        assert k == ["Kino"] and total == 1
        assert _opens(client, "Kino") == ""
