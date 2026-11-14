"""FT-629 (Р-A94): ratings — stars and "dislike" — on own Apertonodo.

A user rates a song 1 to 5 stars or marks it as "dislike". The rating is attached to the song, not
to a recording: a single song in the catalog has dozens of recordings with different ids (like favorites — `canonical_key`).
Ratings are stored in own database and do not leave outside.

Guarded:
- stars — integer 1..5, zero clears; "dislike" and stars do not coexist — user has the final word;
- only a song shown by the server can be rated;
- rating is visible on any recording of the same song;
- each user has their own ratings;
- "rated" and "disliked" lists — for future smart playlists;
- logs contain no titles, artists, or ids.

What tests do not prove: mobile client (no stars on screen — separate card), effect of "dislike"
on queue and recommendations, server wiring — `install_ratings` in `main.py` is called by lead on merge.
"""

from __future__ import annotations

import asyncio
import json
import logging
import uuid
from pathlib import Path
from typing import Any

import asyncpg
import pytest
from fastapi.testclient import TestClient

from app.main import create_app
from app.migrate import apply
from app.ratings import install_ratings
from app.store import persist_tracks

ROOT = Path(__file__).resolve().parents[2]
CATALOG = json.loads((ROOT / "contracts" / "fixtures" / "catalog.json").read_text())[
    "tracks"
]
FIXTURE_ID = "33333333-3333-3333-3333-333333333333"

# Two recordings of one song — as in MusicBrainz: album and single.
ALBUM_ID = str(uuid.uuid4())
SINGLE_ID = str(uuid.uuid4())
OTHER_ID = str(uuid.uuid4())
THIRD_ID = str(uuid.uuid4())
UNKNOWN_ID = str(uuid.uuid4())


def _song(track_id: str, title: str, artist: str = "Glass Harbor") -> dict[str, Any]:
    return {
        "id": track_id,
        "title": title,
        "artist": artist,
        "duration_ms": 240_000,
        "artwork_url": "",
    }


SONGS = [
    _song(ALBUM_ID, "Paper Lanterns"),
    _song(SINGLE_ID, "Paper Lanterns (2019 Remaster)"),
    _song(OTHER_ID, "Northern Wire"),
    _song(THIRD_ID, "Velvet Hours"),
]


def _prepare(url: str) -> None:
    async def run() -> None:
        await apply(url)
        conn = await asyncpg.connect(url)
        try:
            await conn.execute("TRUNCATE ratings")
            await conn.execute(
                "DELETE FROM tracks WHERE id = ANY($1::uuid[])",
                [s["id"] for s in SONGS],
            )
        finally:
            await conn.close()
        await persist_tracks(url, SONGS)

    asyncio.run(run())


def _app(url: str | None) -> Any:
    app = create_app(
        database_url=url,
        catalog=CATALOG,
    )
    install_ratings(app, database_url=url)
    return app


@pytest.fixture
def client(postgres_url: str) -> TestClient:
    _prepare(postgres_url)
    return TestClient(_app(postgres_url))


def _rate(client: TestClient, track_id: str, **body: Any) -> Any:
    return client.post("/v1/ratings", json={"track_id": track_id, **body})


def _of(client: TestClient, *track_ids: str) -> dict[str, Any]:
    r = client.post("/v1/ratings/of", json={"track_ids": list(track_ids)})
    assert r.status_code == 200
    return r.json()["ratings"]


def test_stars_are_stored_and_read_back(client: TestClient) -> None:
    r = _rate(client, OTHER_ID, stars=4)
    assert r.status_code == 200
    assert r.json() == {"stars": 4, "disliked": False}
    assert _of(client, OTHER_ID, THIRD_ID) == {
        OTHER_ID: {"stars": 4, "disliked": False}
    }

    assert _rate(client, OTHER_ID, stars=2).json() == {"stars": 2, "disliked": False}
    assert _of(client, OTHER_ID) == {OTHER_ID: {"stars": 2, "disliked": False}}


def test_fixture_song_can_be_rated(client: TestClient) -> None:
    assert _rate(client, FIXTURE_ID, stars=5).status_code == 200
    assert _of(client, FIXTURE_ID) == {FIXTURE_ID: {"stars": 5, "disliked": False}}


def test_same_song_other_recording_shows_the_rating(client: TestClient) -> None:
    _rate(client, ALBUM_ID, stars=5)
    assert _of(client, SINGLE_ID, OTHER_ID) == {
        SINGLE_ID: {"stars": 5, "disliked": False}
    }

    _rate(client, SINGLE_ID, stars=3)
    assert _of(client, ALBUM_ID) == {ALBUM_ID: {"stars": 3, "disliked": False}}, (
        "one rating per song"
    )
    assert client.get("/v1/ratings").json()["total"] == 1


def test_dislike_and_stars_do_not_live_together(client: TestClient) -> None:
    _rate(client, OTHER_ID, stars=4)
    assert _rate(client, OTHER_ID, disliked=True).json() == {
        "stars": 0,
        "disliked": True,
    }
    assert _of(client, OTHER_ID) == {OTHER_ID: {"stars": 0, "disliked": True}}

    assert _rate(client, OTHER_ID, stars=1).json() == {"stars": 1, "disliked": False}
    assert _of(client, OTHER_ID) == {OTHER_ID: {"stars": 1, "disliked": False}}


def test_clearing_removes_the_rating(client: TestClient, postgres_url: str) -> None:
    _rate(client, OTHER_ID, stars=4)
    assert _rate(client, OTHER_ID, stars=0).json() == {"stars": 0, "disliked": False}
    assert _of(client, OTHER_ID) == {}

    _rate(client, THIRD_ID, disliked=True)
    assert _rate(client, THIRD_ID, disliked=False).json() == {
        "stars": 0,
        "disliked": False,
    }
    assert _of(client, THIRD_ID) == {}

    async def count() -> int:
        conn = await asyncpg.connect(postgres_url)
        try:
            return int(await conn.fetchval("SELECT count(*) FROM ratings"))
        finally:
            await conn.close()

    assert asyncio.run(count()) == 0, "cleared rating does not remain as an empty row"
    assert _rate(client, OTHER_ID, stars=0).status_code == 200, (
        "nothing to clear is not an error"
    )


@pytest.mark.parametrize(
    "body",
    [
        {},
        {"stars": 6},
        {"stars": -1},
        {"stars": 2.5},
        {"stars": "5"},
        {"stars": None},
        {"disliked": "yes"},
        {"stars": 5, "disliked": True},
        {"stars": 3, "magnet": "magnet:?xt=urn:btih:abc"},
    ],
)
def test_bad_rating_is_refused(client: TestClient, body: dict[str, Any]) -> None:
    assert _rate(client, OTHER_ID, **body).status_code == 422
    assert _of(client, OTHER_ID) == {}


def test_unknown_song_is_not_rated(client: TestClient) -> None:
    r = _rate(client, UNKNOWN_ID, stars=5)
    assert r.status_code == 404
    assert r.json() == {"status": "not_found"}
    assert (
        client.post(
            "/v1/ratings", json={"track_id": "not-a-uuid", "stars": 5}
        ).status_code
        == 422
    )
    assert _of(client, UNKNOWN_ID) == {}


def test_each_person_has_own_ratings(
    client: TestClient, test_principal: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    _rate(client, OTHER_ID, stars=5)
    _rate(client, THIRD_ID, disliked=True)

    monkeypatch.setitem(test_principal, "id", str(uuid.uuid4()))
    assert _of(client, OTHER_ID, THIRD_ID) == {}
    assert client.get("/v1/ratings").json() == {"tracks": [], "total": 0}
    _rate(client, OTHER_ID, stars=1)
    assert _of(client, OTHER_ID) == {OTHER_ID: {"stars": 1, "disliked": False}}


def test_lists_for_smart_playlists(client: TestClient) -> None:
    _rate(client, OTHER_ID, stars=3)
    _rate(client, ALBUM_ID, stars=5)
    _rate(client, FIXTURE_ID, stars=4)
    _rate(client, THIRD_ID, disliked=True)

    rated = client.get("/v1/ratings").json()
    assert rated["total"] == 3, "\"disliked\" is not in the rated list"
    assert [(t["id"], t["stars"]) for t in rated["tracks"]] == [
        (ALBUM_ID, 5),
        (FIXTURE_ID, 4),
        (OTHER_ID, 3),
    ], "higher rating comes higher in the list"
    track = rated["tracks"][0]
    assert track["title"] == "Paper Lanterns"
    assert track["artist"] == "Glass Harbor"
    assert track["duration_ms"] == 240_000
    assert track["disliked"] is False
    assert isinstance(track["playable"], bool)
    assert "canonical_key" not in track

    best = client.get("/v1/ratings", params={"min_stars": 4}).json()
    assert [t["id"] for t in best["tracks"]] == [ALBUM_ID, FIXTURE_ID]
    assert best["total"] == 2

    page = client.get("/v1/ratings", params={"limit": 1, "offset": 1}).json()
    assert [t["id"] for t in page["tracks"]] == [FIXTURE_ID]
    assert page["total"] == 3

    disliked = client.get("/v1/ratings", params={"disliked": "true"}).json()
    assert [(t["id"], t["stars"], t["disliked"]) for t in disliked["tracks"]] == [
        (THIRD_ID, 0, True)
    ]
    assert disliked["total"] == 1

    for params in (
        {"min_stars": 0},
        {"min_stars": 6},
        {"limit": 0},
        {"limit": 501},
        {"offset": -1},
    ):
        assert client.get("/v1/ratings", params=params).status_code == 422, params


def test_of_takes_many_but_not_endless(client: TestClient) -> None:
    _rate(client, OTHER_ID, stars=2)
    many = [str(uuid.uuid4()) for _ in range(499)] + [OTHER_ID]
    assert _of(client, *many) == {OTHER_ID: {"stars": 2, "disliked": False}}
    r = client.post("/v1/ratings/of", json={"track_ids": [*many, str(uuid.uuid4())]})
    assert r.status_code == 422
    assert _of(client) == {}


def test_log_has_no_names_or_ids(
    client: TestClient, caplog: pytest.LogCaptureFixture
) -> None:
    caplog.set_level(logging.DEBUG)
    _rate(client, OTHER_ID, stars=4)
    _rate(client, ALBUM_ID, disliked=True)
    _of(client, OTHER_ID, ALBUM_ID)
    client.get("/v1/ratings")
    text = "\n".join(r.getMessage() for r in caplog.records)
    for secret in (
        "Northern Wire",
        "Paper Lanterns",
        "Glass Harbor",
        OTHER_ID,
        ALBUM_ID,
    ):
        assert secret not in text, secret


def test_no_database_is_503() -> None:
    client = TestClient(_app(None))
    for r in (
        _rate(client, OTHER_ID, stars=3),
        client.post("/v1/ratings/of", json={"track_ids": [OTHER_ID]}),
        client.get("/v1/ratings"),
    ):
        assert r.status_code == 503
        assert r.json() == {"status": "library_unavailable"}


@pytest.mark.real_auth
def test_without_login_refused(postgres_url: str) -> None:
    client = TestClient(_app(postgres_url))
    assert _rate(client, OTHER_ID, stars=3).status_code == 401
    assert (
        client.post("/v1/ratings/of", json={"track_ids": [OTHER_ID]}).status_code == 401
    )
    assert client.get("/v1/ratings").status_code == 401
