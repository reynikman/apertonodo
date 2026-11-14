"""Search responds from own release list (Phase J, G53) — on real PostgreSQL.

What is guarded here and why.

1. Artist is the first row for a query with their name. Before Phase J `/v1/search`
   responded only via MusicBrainz, and there was no "artist" row in results at all.
2. Song is found by title ("enter sandman") and by "artist song"
   ("linkin park numb"), and this is the exact same row. Without the second, a user
   refining their query got a different result than without refinement.
3. Original outranks cover. Weight is seeders plus Last.fm listeners, so for "enter
   sandman" Metallica must outrank Apocalyptica, which also has this song
   in its top tracks.
4. Typos are handled by `pg_trgm`: "metalica" finds Metallica.
5. Search results exclude items not in the own list. A MusicBrainz recording
   without an active release is omitted while own results exist, and
   shown with `playable: false` when there are no own results at all.
6. A Last.fm top track without any active release does not enter the own track list.

Releases here are synthetic: real names, fictitious hashes and categories.
"""

from __future__ import annotations

from typing import Any

import pytest
from fakes import SeededExtension
from fastapi.testclient import TestClient

from app import catalog
from app.main import create_app
from app.migrate import apply
from app.names import norm

# Categories from app/genres.py: classic rock and alternative.
ROCK, ALT = 1702, 1736

RELEASES = [
    (ROCK, "(Rock) [FLAC] Metallica - Metallica - 1991", 500, ["Enter Sandman", "Sad But True"]),
    (ALT, "(Alt) [FLAC] Linkin Park - Meteora - 2003", 400, ["Numb", "Faint"]),
    (ROCK, "(Rock) [FLAC] Apocalyptica - Plays Metallica - 1996", 50, ["Enter Sandman"]),
    (ALT, "(Alt) [FLAC] Marina - The Family Jewels - 2010", 30, ["Numb", "Hollywood"]),
]

# A well-known band has millions of listeners, hundreds of seeders: weight is their sum,
# as decided by owner. "The Struggle Within" is in Metallica's top, but has no active
# release — it must be dropped from own track list.
LASTFM = [
    ("Metallica", 3_000_000, ["Enter Sandman", "Sad But True", "The Struggle Within"]),
    ("Linkin Park", 4_000_000, ["Numb", "Faint"]),
    ("Apocalyptica", 900_000, ["Enter Sandman"]),
    ("Marina", 800_000, ["Numb"]),
]


class StubCatalog:
    """MusicBrainz responding with a preconfigured list."""

    def __init__(self, tracks: list[dict[str, Any]] | None = None) -> None:
        self.tracks = tracks or []
        self.asked: list[str] = []

    async def search(self, query: str, limit: int) -> list[dict[str, Any]]:
        self.asked.append(query)
        return list(self.tracks)


def mb_track(uid: str, artist: str, title: str) -> dict[str, Any]:
    return {
        "id": uid,
        "title": title,
        "artist": artist,
        "duration_ms": 240_000,
        "artwork_url": "",
    }


@pytest.fixture
async def filled(postgres_url: str) -> str:
    """Database with own releases list, catalog, and Last.fm data."""
    import asyncpg

    await apply(postgres_url)
    conn = await asyncpg.connect(postgres_url)
    try:
        for table in ("catalog_artists", "lastfm_artists"):
            await conn.execute(f"DELETE FROM {table}")
        for name, listeners, top in LASTFM:
            await conn.execute(
                "INSERT INTO lastfm_artists (artist_key, found, bio, top_tracks, "
                "similar_artists, listeners) VALUES ($1, true, NULL, $2, '{}', $3)",
                norm(name),
                top,
                listeners,
            )
    finally:
        await conn.close()
    extension = SeededExtension(
        [(topic, forum, title, tracks, seeders) for topic, (forum, title, seeders, tracks) in enumerate(RELEASES, start=1)]
    )
    await extension.build_catalog(postgres_url)
    catalog.use_extensions(extension.playable())
    await catalog.build_tracks(postgres_url)
    return postgres_url


def client(url: str, port: Any) -> TestClient:
    return TestClient(create_app(database_url=url, catalog=[], catalog_port=port))


def found(payload: dict[str, Any]) -> list[tuple[str, str]]:
    return [(track["artist"], track["title"]) for track in payload["tracks"]]


async def test_own_list_answers_first_line_with_the_band(filled: str) -> None:
    with client(filled, StubCatalog()) as http:
        payload = http.get("/v1/search", params={"q": "metallica"}).json()
    assert payload["artists"][0]["name"] == "Metallica"
    assert payload["artists"][0]["photo"] is None
    # Songs by the same artist follow next and are all playable.
    assert ("Metallica", "Enter Sandman") in found(payload)
    assert all(track["playable"] for track in payload["tracks"])


async def test_original_outranks_the_cover(filled: str) -> None:
    with client(filled, StubCatalog()) as http:
        payload = http.get("/v1/search", params={"q": "enter sandman"}).json()
    assert found(payload)[0] == ("Metallica", "Enter Sandman")


async def test_song_alone_and_with_the_artist_give_the_same_row(filled: str) -> None:
    with client(filled, StubCatalog()) as http:
        short = http.get("/v1/search", params={"q": "numb"}).json()
        full = http.get("/v1/search", params={"q": "linkin park numb"}).json()
    assert found(short)[0] == ("Linkin Park", "Numb")
    assert found(full)[0] == ("Linkin Park", "Numb")
    assert short["tracks"][0]["id"] == full["tracks"][0]["id"]


async def test_typo_still_finds_the_band(filled: str) -> None:
    with client(filled, StubCatalog()) as http:
        payload = http.get("/v1/search", params={"q": "metalica"}).json()
    assert payload["artists"][0]["name"] == "Metallica"


async def test_musicbrainz_row_without_a_release_is_not_shown(filled: str) -> None:
    """While own tracks exist, unplayable items are not shown in results."""
    port = StubCatalog([mb_track("22222222-2222-2222-2222-222222222222", "Metallica", "Lux Æterna")])
    with client(filled, port) as http:
        payload = http.get("/v1/search", params={"q": "enter sandman"}).json()
    assert ("Metallica", "Lux Æterna") not in found(payload)
    assert found(payload)


async def test_musicbrainz_row_with_a_release_is_shown_and_plays(filled: str) -> None:
    """Deep cut: not in Last.fm top, but an active release exists for it."""
    port = StubCatalog([mb_track("33333333-3333-3333-3333-333333333333", "Marina", "Hollywood")])
    with client(filled, port) as http:
        payload = http.get("/v1/search", params={"q": "hollywood"}).json()
    assert found(payload) == [("Marina", "Hollywood")]
    assert payload["tracks"][0]["playable"] is True


async def test_nothing_of_our_own_shows_musicbrainz_marked(filled: str) -> None:
    port = StubCatalog([mb_track("44444444-4444-4444-4444-444444444444", "Sleep Token", "Chokehold")])
    with client(filled, port) as http:
        payload = http.get("/v1/search", params={"q": "chokehold"}).json()
    assert found(payload) == [("Sleep Token", "Chokehold")]
    assert payload["tracks"][0]["playable"] is False


async def test_top_track_without_a_release_never_enters_the_own_list(filled: str) -> None:
    with client(filled, StubCatalog()) as http:
        payload = http.get("/v1/search", params={"q": "the struggle within"}).json()
    assert found(payload) == []


async def test_own_row_can_be_played(filled: str) -> None:
    """Own song ID is persistent: Play must find it, not return 404."""
    with client(filled, StubCatalog()) as http:
        payload = http.get("/v1/search", params={"q": "numb"}).json()
        track_id = payload["tracks"][0]["id"]
        again = http.get("/v1/search", params={"q": "linkin park numb"}).json()
        assert again["tracks"][0]["id"] == track_id
        answer = http.post("/v1/playback", json={"track_id": track_id})
    # No sources in test harness, so honest refusal — but not 404
    # "server does not know track": it does know the track.
    assert answer.status_code != 404


async def test_own_artists_include_kept_photo(filled: str) -> None:
    import asyncpg

    conn = await asyncpg.connect(filled)
    try:
        await conn.execute(
            "INSERT INTO artist_photos (artist_key, mbid, path, author, license) "
            "VALUES ('metallica', $1::uuid, 'photos/65/65.jpg', 'Ann', 'CC BY')",
            "65f4f0c5-ef9e-490c-a730-88a284936fd8",
        )
    finally:
        await conn.close()
    with client(filled, StubCatalog()) as http:
        payload = http.get("/v1/search", params={"q": "metallica"}).json()
    assert payload["artists"][0]["name"] == "Metallica"
    assert payload["artists"][0]["photo"] == "/v1/photos/65f4f0c5-ef9e-490c-a730-88a284936fd8"
    assert all("photo" in row for row in payload["artists"])
