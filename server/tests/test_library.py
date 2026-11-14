""""My Music" (Phase H): favorites, custom playlists, history on real PostgreSQL.

Main pre-implementation discovery (19.09, live MusicBrainz): a single song has dozens
of recordings — Duality has 30, "Blood Type" has 23, Nothing Else Matters over a hundred —
and the ID from the album page does not match the first search result ID. The recording
ID itself is immutable (rows in `tracks` are append-only), but "the same song" is identified
by `canonical_key`. Tests below preserve both properties.
"""

from __future__ import annotations

import asyncio
import json
import logging
import secrets
import uuid
from contextvars import ContextVar
from pathlib import Path
from typing import Any, Iterator

import asyncpg
import httpx
import pytest
from fakes import SeededExtension
from fastapi.testclient import TestClient

import app.catalog_api as catalog_api
import app.library as library
from app import catalog
from app.main import create_app
from app.migrate import apply
from app.store import persist_tracks
from app.users import create_user

ROOT = Path(__file__).resolve().parents[2]
CONTRACTS = ROOT / "contracts"
CATALOG = json.loads((ROOT / "contracts" / "fixtures" / "catalog.json").read_text())["tracks"]
FIXTURE_ID = "33333333-3333-3333-3333-333333333333"  # Duality, fixture
TONE_ID = "f1070000-0000-4000-8000-000000000090"  # Test Tone Long
PHOTO_MBID = "5b5b5b5b-5b5b-4b5b-8b5b-5b5b5b5b5b5b"
FORBIDDEN = (
    "torrent", "magnet", "tracker", "seed", "info_hash", "infohash", "btih",
    "topic", "forum", "rqbit", "source",
)

# Two recordings of the same song, matching MusicBrainz structure: album and single.
ALBUM_ID = str(uuid.uuid4())
SINGLE_ID = str(uuid.uuid4())
OTHER_ID = str(uuid.uuid4())
DEAD_ID = str(uuid.uuid4())
IMAGE_ID = str(uuid.uuid4())


def _song(track_id: str, title: str, artist: str = "Glass Harbor", ms: int = 240_000) -> dict[str, Any]:
    return {"id": track_id, "title": title, "artist": artist, "duration_ms": ms, "artwork_url": ""}


SONGS = [
    _song(ALBUM_ID, "Paper Lanterns"),
    _song(SINGLE_ID, "Paper Lanterns (2019 Remaster)"),
    _song(OTHER_ID, "Northern Wire"),
    _song(DEAD_ID, "Velvet Hours"),
    _song(IMAGE_ID, "Salt Bridge"),
]
_AUTH_HEADER: ContextVar[dict[str, str] | None] = ContextVar("library_auth", default=None)


async def _reset(url: str, principal_id: str) -> None:
    await apply(url)
    conn = await asyncpg.connect(url)
    try:
        await conn.execute(
            "TRUNCATE favorites, playlist_items, playlists, listens"
        )
        await conn.execute("DELETE FROM tracks WHERE id = ANY($1::uuid[])", [s["id"] for s in SONGS])
        await conn.execute(
            "INSERT INTO users (id, username) VALUES ($1, $2) ON CONFLICT (id) DO NOTHING",
            uuid.UUID(principal_id), f"fixture_{principal_id}",
        )
        # Live seeds exist for "Paper Lanterns" and "Northern Wire"; "Velvet
        # Hours" has no seeds, "Salt Bridge" exists only as a disc image.
        catalog.use_extensions(
            SeededExtension(
                [
                    (1, 1, "glass harbor lanterns 2019 flac", ["paper lanterns", "northern wire"], 7),
                    (2, 1, "glass harbor velvet hours mp3", ["velvet hours"], 0),
                    (3, 1, "glass harbor salt bridge image ape", ["salt bridge"], 12),
                ]
            ).playable()
        )
    finally:
        await conn.close()


@pytest.fixture
def prepared_db(postgres_url: str, test_principal: dict[str, str | bool]) -> str:
    asyncio.run(_reset(postgres_url, str(test_principal["id"])))
    # Songs are "displayed": both search and album page in Phase F write
    # them to `tracks` this way (both call persist_tracks).
    asyncio.run(persist_tracks(postgres_url, SONGS))
    return postgres_url


@pytest.fixture
def db(prepared_db: str) -> Iterator[str]:
    postgres_url = prepared_db
    username = f"library_{uuid.uuid4().hex}"
    password = secrets.token_urlsafe(32)

    async def add_user() -> None:
        conn = await asyncpg.connect(postgres_url)
        try:
            await create_user(conn, username, password)
        finally:
            await conn.close()

    asyncio.run(add_user())
    response = TestClient(_app(postgres_url)).post(
        "/v1/auth/login", json={"username": username, "password": password, "device_name": "library-test"}
    )
    assert response.status_code == 200
    reset = _AUTH_HEADER.set({"Authorization": f"Bearer {response.json()['token']}"})
    try:
        yield postgres_url
    finally:
        _AUTH_HEADER.reset(reset)


def _app(url: str | None) -> Any:
    # Resolver without sources: Play responds 409 "unresolved", not 404 "unknown song".
    return create_app(
        database_url=url, catalog=CATALOG
    )


def _client(url: str | None) -> TestClient:
    # No-database cases still send a correctly shaped bearer; the guard must return 503.
    headers = _AUTH_HEADER.get() or {"Authorization": f"Bearer {secrets.token_urlsafe(32)}"}
    return TestClient(_app(url), headers=headers)


def _ids(answer: dict[str, Any]) -> list[str]:
    return [track["id"] for track in answer["tracks"]]


def test_every_migration_ends_with_semicolon() -> None:
    """Migrations are concatenated sequentially and split on `;` (app/migrate.py).

    010 without a trailing `;` worked while it was the last one; after merging 011,
    its last CREATE merged with the next migration's first CREATE — causing a syntax
    error on every startup.
    """
    for path in sorted((ROOT / "server" / "migrations").glob("*.sql")):
        text = "\n".join(
            line for line in path.read_text().splitlines() if not line.lstrip().startswith("--")
        ).strip()
        assert text.endswith(";"), path.name


# --- song stability -------------------------------------------------------


@pytest.mark.real_auth
def test_same_song_other_recording_is_one_favorite(db: str) -> None:
    client = _client(db)
    assert client.post("/v1/favorites", json={"track_id": ALBUM_ID}).status_code == 200
    assert client.post("/v1/favorites", json={"track_id": SINGLE_ID}).status_code == 200
    assert _ids(client.get("/v1/favorites").json()) == [ALBUM_ID]

    # Favorite status is active on any recording of the same song, but not on another song.
    contains = client.post(
        "/v1/favorites/contains", json={"track_ids": [SINGLE_ID, OTHER_ID, ALBUM_ID]}
    ).json()
    assert contains == {"track_ids": [SINGLE_ID, ALBUM_ID]}

    # Can be removed from any of its recordings.
    client.post("/v1/favorites/remove", json={"track_id": SINGLE_ID})
    assert client.get("/v1/favorites").json() == {"tracks": []}


@pytest.mark.real_auth
def test_favorite_and_playlist_survive_restart_and_still_play(db: str) -> None:
    first = _client(db)
    first.post("/v1/favorites", json={"track_id": ALBUM_ID})
    playlist = first.post("/v1/playlists", json={"name": "Утро"}).json()["id"]
    first.post(f"/v1/playlists/{playlist}/tracks", json={"track_id": OTHER_ID})
    # Redisplaying the same recording (new search) does not change its ID.
    asyncio.run(persist_tracks(db, [SONGS[0]]))

    second = _client(db)  # new process: no in-memory cache of previously shown items
    assert _ids(second.get("/v1/favorites").json()) == [ALBUM_ID]
    assert _ids(second.get(f"/v1/playlists/{playlist}").json()) == [OTHER_ID]
    for track_id in (ALBUM_ID, OTHER_ID):
        # 409: server knows the song and searches audio for it; 404 would mean dead link.
        assert second.post("/v1/playback", json={"track_id": track_id}).status_code == 409


@pytest.mark.real_auth
def test_song_known_only_in_memory_is_written_when_added(db: str) -> None:
    """When rendered, database might not have stored the song; adding persists it directly."""
    fresh = _song(str(uuid.uuid4()), "Harbor Lights")
    client = _client(db)
    app = client.app
    app.state.tracks[fresh["id"]] = fresh
    client.post("/v1/favorites", json={"track_id": fresh["id"]})

    restarted = _client(db)
    assert restarted.post("/v1/playback", json={"track_id": fresh["id"]}).status_code == 409


@pytest.mark.real_auth
def test_unknown_song_is_refused(db: str) -> None:
    client = _client(db)
    stranger = str(uuid.uuid4())
    assert client.post("/v1/favorites", json={"track_id": stranger}).status_code == 404
    playlist = client.post("/v1/playlists", json={"name": "X"}).json()["id"]
    assert client.post(f"/v1/playlists/{playlist}/tracks", json={"track_id": stranger}).status_code == 404
    assert client.post("/v1/history", json={"track_id": stranger, "listened_ms": 60_000}).status_code == 404
    assert client.get("/v1/favorites").json() == {"tracks": []}


# --- playability ----------------------------------------------------------


@pytest.mark.real_auth
def test_song_that_does_not_play_stays_with_playable_false(db: str) -> None:
    client = _client(db)
    for track_id in (FIXTURE_ID, ALBUM_ID, DEAD_ID, IMAGE_ID):
        client.post("/v1/favorites", json={"track_id": track_id})
    playable = {t["id"]: t["playable"] for t in client.get("/v1/favorites").json()["tracks"]}
    assert playable == {
        FIXTURE_ID: True,  # fixture always plays
        ALBUM_ID: True,  # live release, song is in tracklist
        DEAD_ID: False,  # no seeds available
        IMAGE_ID: False,  # disc image only
    }


# --- playlists ------------------------------------------------------------


@pytest.mark.real_auth
def test_playlist_lifecycle(db: str) -> None:
    client = _client(db)
    created = client.post("/v1/playlists", json={"name": "  В   дорогу "})
    assert created.status_code == 201
    playlist = created.json()["id"]
    assert created.json() == {"id": playlist, "name": "В дорогу", "tracks": 0}

    for track_id in (ALBUM_ID, OTHER_ID, DEAD_ID, SINGLE_ID):  # SINGLE is the same song as ALBUM
        assert client.post(f"/v1/playlists/{playlist}/tracks", json={"track_id": track_id}).status_code == 200
    content = client.get(f"/v1/playlists/{playlist}").json()
    assert _ids(content) == [ALBUM_ID, OTHER_ID, DEAD_ID]
    assert [t["playable"] for t in content["tracks"]] == [True, True, False]

    assert client.post(
        f"/v1/playlists/{playlist}/order", json={"track_ids": [DEAD_ID, ALBUM_ID, OTHER_ID]}
    ).status_code == 200
    assert _ids(client.get(f"/v1/playlists/{playlist}").json()) == [DEAD_ID, ALBUM_ID, OTHER_ID]

    # Stale screen: mismatched track set returns 409, order left untouched.
    for stale in ([ALBUM_ID, OTHER_ID], [DEAD_ID, ALBUM_ID, OTHER_ID, IMAGE_ID], [DEAD_ID, DEAD_ID, ALBUM_ID]):
        assert client.post(f"/v1/playlists/{playlist}/order", json={"track_ids": stale}).status_code == 409
    assert _ids(client.get(f"/v1/playlists/{playlist}").json()) == [DEAD_ID, ALBUM_ID, OTHER_ID]

    client.post(f"/v1/playlists/{playlist}/tracks/remove", json={"track_id": SINGLE_ID})
    client.post(f"/v1/playlists/{playlist}/tracks", json={"track_id": IMAGE_ID})
    assert _ids(client.get(f"/v1/playlists/{playlist}").json()) == [DEAD_ID, OTHER_ID, IMAGE_ID]

    assert client.post(f"/v1/playlists/{playlist}/rename", json={"name": "Домой"}).status_code == 200
    second = client.post("/v1/playlists", json={"name": "Пустой"}).json()["id"]
    assert client.get("/v1/playlists").json() == {
        "playlists": [
            {"id": playlist, "name": "Домой", "tracks": 3},
            {"id": second, "name": "Пустой", "tracks": 0},
        ]
    }

    assert client.post(f"/v1/playlists/{playlist}/delete").status_code == 200
    assert client.get(f"/v1/playlists/{playlist}").status_code == 404
    assert [p["id"] for p in client.get("/v1/playlists").json()["playlists"]] == [second]
    count = asyncio.run(_count(db, "SELECT count(*) FROM playlist_items"))
    assert count == 0


async def _count(url: str, sql: str) -> int:
    conn = await asyncpg.connect(url)
    try:
        return int(await conn.fetchval(sql))
    finally:
        await conn.close()


@pytest.mark.real_auth
def test_playlist_names_and_missing_playlists(db: str) -> None:
    client = _client(db)
    for bad in ("", "   ", "я" * 101):
        assert client.post("/v1/playlists", json={"name": bad}).status_code == 422
    playlist = client.post("/v1/playlists", json={"name": "я" * 100}).json()["id"]
    assert client.post(f"/v1/playlists/{playlist}/rename", json={"name": " "}).status_code == 422

    missing = str(uuid.uuid4())
    body = {"track_id": ALBUM_ID}
    assert client.get(f"/v1/playlists/{missing}").status_code == 404
    assert client.post(f"/v1/playlists/{missing}/rename", json={"name": "A"}).status_code == 404
    assert client.post(f"/v1/playlists/{missing}/delete").status_code == 404
    assert client.post(f"/v1/playlists/{missing}/tracks", json=body).status_code == 404
    assert client.post(f"/v1/playlists/{missing}/tracks/remove", json=body).status_code == 404
    assert client.post(f"/v1/playlists/{missing}/order", json={"track_ids": []}).status_code == 404


# --- history --------------------------------------------------------------


@pytest.mark.parametrize(
    ("listened_ms", "duration_ms", "counts"),
    [
        (29_999, 240_000, False),
        (30_000, 240_000, True),
        (9_999, 20_000, False),  # short song — starts counting at half
        (10_000, 20_000, True),
        (29_999, 0, False),  # unknown duration — 30s threshold
        (30_000, 0, True),
    ],
)
def test_listen_threshold(listened_ms: int, duration_ms: int, counts: bool) -> None:
    assert library.listen_counts(listened_ms, duration_ms) is counts


@pytest.mark.real_auth
def test_history_records_only_real_listens_and_repeats_once(db: str) -> None:
    client = _client(db)

    def listen(track_id: str, ms: int = 60_000) -> bool:
        return client.post("/v1/history", json={"track_id": track_id, "listened_ms": ms}).json()["recorded"]

    assert listen(ALBUM_ID, 29_999) is False  # skipped
    assert client.get("/v1/history").json() == {"tracks": [], "total": 0}

    assert listen(ALBUM_ID) is True
    assert listen(ALBUM_ID) is True  # repeat of the same song
    assert listen(SINGLE_ID) is True  # same song under a different recording
    assert listen(OTHER_ID) is True
    assert listen(ALBUM_ID) is True  # returned to it — counts as a new listen entry
    answer = client.get("/v1/history").json()
    assert _ids(answer) == [ALBUM_ID, OTHER_ID, ALBUM_ID]
    assert answer["total"] == 3
    assert all(track["played_at"] for track in answer["tracks"])
    assert _ids(client.get("/v1/history", params={"offset": 1, "limit": 1}).json()) == [OTHER_ID]


@pytest.mark.real_auth
def test_history_keeps_only_the_latest(db: str, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(library, "HISTORY_MAX", 3)
    client = _client(db)
    for track_id in (ALBUM_ID, OTHER_ID, DEAD_ID, IMAGE_ID, FIXTURE_ID):
        client.post("/v1/history", json={"track_id": track_id, "listened_ms": 60_000})
    answer = client.get("/v1/history").json()
    assert _ids(answer) == [FIXTURE_ID, IMAGE_ID, DEAD_ID]
    assert answer["total"] == 3
    assert asyncio.run(_count(db, "SELECT count(*) FROM listens")) == 3


@pytest.mark.real_auth
def test_history_keeps_cover_path_and_drops_foreign_url(db: str) -> None:
    client = _client(db)
    cover = f"/v1/covers/{IMAGE_ID}"
    client.post(
        "/v1/history",
        json={"track_id": ALBUM_ID, "listened_ms": 60_000, "artwork_url": cover},
    )
    client.post(
        "/v1/history",
        json={
            "track_id": OTHER_ID,
            "listened_ms": 60_000,
            "artwork_url": "https://example.com/x.jpg",
        },
    )
    by_id = {track["id"]: track for track in client.get("/v1/history").json()["tracks"]}
    assert by_id[ALBUM_ID]["artwork_url"] == cover
    assert by_id[OTHER_ID]["artwork_url"] == ""
    stored = asyncio.run(_covers(db))
    assert stored == {ALBUM_ID: cover, OTHER_ID: ""}


@pytest.mark.real_auth
def test_favorite_keeps_cover_path_and_drops_foreign_url(db: str) -> None:
    """Owner finding 2026-10-01: favorite song on Home without cover — server
    did not persist it. Local server path is stored, external URL is not."""
    client = _client(db)
    cover = f"/v1/covers/{IMAGE_ID}"
    client.post("/v1/favorites", json={"track_id": ALBUM_ID, "artwork_url": cover})
    client.post(
        "/v1/favorites",
        json={"track_id": OTHER_ID, "artwork_url": "https://example.com/x.jpg"},
    )
    by_id = {track["id"]: track for track in client.get("/v1/favorites").json()["tracks"]}
    assert by_id[ALBUM_ID]["artwork_url"] == cover
    assert by_id[OTHER_ID]["artwork_url"] == ""
    assert asyncio.run(_favorite_covers(db)) == {ALBUM_ID: cover, OTHER_ID: ""}


@pytest.mark.real_auth
def test_favorite_without_cover_gets_it_from_another_recording(db: str) -> None:
    """Legacy favorite without cover: same song arrives via another recording with
    a cover — favorite entry stays the same, cover is appended."""
    client = _client(db)
    cover = f"/v1/covers/{IMAGE_ID}"
    client.post("/v1/favorites", json={"track_id": ALBUM_ID})
    client.post("/v1/favorites", json={"track_id": SINGLE_ID, "artwork_url": cover})
    tracks = client.get("/v1/favorites").json()["tracks"]
    assert [(track["id"], track["artwork_url"]) for track in tracks] == [(ALBUM_ID, cover)]
    # Cover already exists — incoming one does not overwrite it.
    client.post("/v1/favorites", json={"track_id": SINGLE_ID, "artwork_url": "/v1/covers/other"})
    assert client.get("/v1/favorites").json()["tracks"][0]["artwork_url"] == cover


@pytest.mark.real_auth
def test_favorite_without_cover_shows_the_cover_from_history(db: str) -> None:
    """Favorite created before this fix (no cover), but the song was later played
    with a cover — favorite shows that cover. Nothing rewritten in favorites table:
    view-time enrichment."""
    client = _client(db)
    cover = f"/v1/covers/{IMAGE_ID}"
    client.post("/v1/favorites", json={"track_id": ALBUM_ID})
    client.post("/v1/favorites", json={"track_id": OTHER_ID})
    client.post(
        "/v1/history",
        json={"track_id": SINGLE_ID, "listened_ms": 60_000, "artwork_url": cover},
    )
    by_id = {track["id"]: track for track in client.get("/v1/favorites").json()["tracks"]}
    assert by_id[ALBUM_ID]["artwork_url"] == cover
    assert by_id[OTHER_ID]["artwork_url"] == ""
    assert asyncio.run(_favorite_covers(db)) == {ALBUM_ID: "", OTHER_ID: ""}


def _new_playlist(client: TestClient) -> str:
    return client.post("/v1/playlists", json={"name": "В дорогу"}).json()["id"]


@pytest.mark.real_auth
def test_playlist_song_keeps_cover_path_and_drops_foreign_url(db: str) -> None:
    """Owner question 2026-10-01: playlist tracks had no cover either — server
    did not persist it, like favorites prior to FT-482. Local path kept, external dropped."""
    client = _client(db)
    playlist = _new_playlist(client)
    cover = f"/v1/covers/{IMAGE_ID}"
    client.post(f"/v1/playlists/{playlist}/tracks", json={"track_id": ALBUM_ID, "artwork_url": cover})
    client.post(
        f"/v1/playlists/{playlist}/tracks",
        json={"track_id": OTHER_ID, "artwork_url": "https://example.com/x.jpg"},
    )
    tracks = client.get(f"/v1/playlists/{playlist}").json()["tracks"]
    assert [(track["id"], track["artwork_url"]) for track in tracks] == [(ALBUM_ID, cover), (OTHER_ID, "")]
    assert asyncio.run(_playlist_covers(db)) == {ALBUM_ID: cover, OTHER_ID: ""}


@pytest.mark.real_auth
def test_playlist_song_without_cover_gets_it_from_another_recording(db: str) -> None:
    """Song added without cover, then same song via another recording with
    cover: row unchanged, position in playlist unchanged, cover updated."""
    client = _client(db)
    playlist = _new_playlist(client)
    cover = f"/v1/covers/{IMAGE_ID}"
    client.post(f"/v1/playlists/{playlist}/tracks", json={"track_id": ALBUM_ID})
    client.post(f"/v1/playlists/{playlist}/tracks", json={"track_id": OTHER_ID})
    client.post(f"/v1/playlists/{playlist}/tracks", json={"track_id": SINGLE_ID, "artwork_url": cover})
    tracks = client.get(f"/v1/playlists/{playlist}").json()["tracks"]
    assert [(track["id"], track["artwork_url"]) for track in tracks] == [(ALBUM_ID, cover), (OTHER_ID, "")]
    # Cover already exists — incoming one does not overwrite it.
    client.post(
        f"/v1/playlists/{playlist}/tracks", json={"track_id": SINGLE_ID, "artwork_url": "/v1/covers/other"}
    )
    assert client.get(f"/v1/playlists/{playlist}").json()["tracks"][0]["artwork_url"] == cover


@pytest.mark.real_auth
def test_playlist_song_without_cover_shows_the_cover_from_history(db: str) -> None:
    """Song in playlist from earlier versions (no cover), but listened to with
    a cover — playlist shows that cover. Playlist row not overwritten:
    view-time enrichment."""
    client = _client(db)
    playlist = _new_playlist(client)
    cover = f"/v1/covers/{IMAGE_ID}"
    client.post(f"/v1/playlists/{playlist}/tracks", json={"track_id": ALBUM_ID})
    client.post(f"/v1/playlists/{playlist}/tracks", json={"track_id": OTHER_ID})
    client.post(
        "/v1/history",
        json={"track_id": SINGLE_ID, "listened_ms": 60_000, "artwork_url": cover},
    )
    tracks = client.get(f"/v1/playlists/{playlist}").json()["tracks"]
    assert [(track["id"], track["artwork_url"]) for track in tracks] == [(ALBUM_ID, cover), (OTHER_ID, "")]
    assert asyncio.run(_playlist_covers(db)) == {ALBUM_ID: "", OTHER_ID: ""}


@pytest.mark.real_auth
def test_history_artist_photo_is_one_listed_call(
    db: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    asyncio.run(_put_photo(db, "glass harbor", PHOTO_MBID))
    calls = {"n": 0}
    original = catalog_api.Catalog.listed

    async def counted(self: Any, conn: Any, names: list[str]) -> Any:
        calls["n"] += 1
        return await original(self, conn, names)

    monkeypatch.setattr(catalog_api.Catalog, "listed", counted)
    client = _client(db)
    client.post("/v1/history", json={"track_id": ALBUM_ID, "listened_ms": 60_000})
    client.post("/v1/history", json={"track_id": OTHER_ID, "listened_ms": 60_000})
    client.post("/v1/history", json={"track_id": FIXTURE_ID, "listened_ms": 60_000})
    answer = client.get("/v1/history").json()
    by_id = {track["id"]: track for track in answer["tracks"]}
    assert by_id[ALBUM_ID]["artist_photo"] == f"/v1/photos/{PHOTO_MBID}"
    assert by_id[OTHER_ID]["artist_photo"] == f"/v1/photos/{PHOTO_MBID}"
    assert by_id[FIXTURE_ID]["artist_photo"] is None
    assert calls["n"] == 1


@pytest.mark.real_auth
def test_history_marks_test_tone_and_keeps_the_row(db: str) -> None:
    client = _client(db)
    client.post("/v1/history", json={"track_id": TONE_ID, "listened_ms": 60_000})
    client.post("/v1/history", json={"track_id": ALBUM_ID, "listened_ms": 60_000})
    answer = client.get("/v1/history").json()
    assert _ids(answer) == [ALBUM_ID, TONE_ID]
    by_id = {track["id"]: track for track in answer["tracks"]}
    assert by_id[TONE_ID]["test_tone"] is True
    assert by_id[ALBUM_ID].get("test_tone") in (None, False)


async def _covers(url: str) -> dict[str, str]:
    conn = await asyncpg.connect(url)
    try:
        rows = await conn.fetch("SELECT track_id, artwork_url FROM listens")
        return {str(row["track_id"]): row["artwork_url"] for row in rows}
    finally:
        await conn.close()


async def _favorite_covers(url: str) -> dict[str, str]:
    conn = await asyncpg.connect(url)
    try:
        rows = await conn.fetch("SELECT track_id, artwork_url FROM favorites")
        return {str(row["track_id"]): row["artwork_url"] for row in rows}
    finally:
        await conn.close()


async def _playlist_covers(url: str) -> dict[str, str]:
    conn = await asyncpg.connect(url)
    try:
        rows = await conn.fetch("SELECT track_id, artwork_url FROM playlist_items")
        return {str(row["track_id"]): row["artwork_url"] for row in rows}
    finally:
        await conn.close()


async def _put_photo(url: str, artist_key: str, mbid: str) -> None:
    conn = await asyncpg.connect(url)
    try:
        await conn.execute(
            "INSERT INTO artist_photos (artist_key, mbid, path, author, license) "
            "VALUES ($1, $2::uuid, 'photos/5b/5b.jpg', 'Ann', 'CC BY') "
            "ON CONFLICT (artist_key) DO UPDATE "
            "SET mbid = EXCLUDED.mbid, path = EXCLUDED.path, "
            "author = EXCLUDED.author, license = EXCLUDED.license",
            artist_key,
            mbid,
        )
    finally:
        await conn.close()


@pytest.mark.real_auth
def test_history_goes_nowhere(db: str, monkeypatch: pytest.MonkeyPatch) -> None:
    """History never leaks externally: zero outbound requests across the run."""

    def refuse(*args: Any, **kwargs: Any) -> Any:
        raise AssertionError("outgoing request from My Music")

    # Real httpx network transports; TestClient bypasses them directly into app.
    monkeypatch.setattr(httpx.HTTPTransport, "handle_request", refuse)
    monkeypatch.setattr(httpx.AsyncHTTPTransport, "handle_async_request", refuse)
    client = _client(db)
    client.post("/v1/history", json={"track_id": ALBUM_ID, "listened_ms": 60_000})
    client.post("/v1/favorites", json={"track_id": OTHER_ID})
    assert client.get("/v1/history").json()["total"] == 1
    assert client.get("/v1/favorites").status_code == 200


# --- no database, boundaries, logs ----------------------------------------

ROUTES = [
    ("GET", "/v1/favorites", None),
    ("POST", "/v1/favorites", {"track_id": ALBUM_ID}),
    ("POST", "/v1/favorites/remove", {"track_id": ALBUM_ID}),
    ("POST", "/v1/favorites/contains", {"track_ids": [ALBUM_ID]}),
    ("GET", "/v1/playlists", None),
    ("POST", "/v1/playlists", {"name": "A"}),
    ("GET", "/v1/playlists/{p}", None),
    ("POST", "/v1/playlists/{p}/rename", {"name": "A"}),
    ("POST", "/v1/playlists/{p}/delete", None),
    ("POST", "/v1/playlists/{p}/tracks", {"track_id": ALBUM_ID}),
    ("POST", "/v1/playlists/{p}/tracks/remove", {"track_id": ALBUM_ID}),
    ("POST", "/v1/playlists/{p}/order", {"track_ids": [ALBUM_ID]}),
    ("POST", "/v1/history", {"track_id": ALBUM_ID, "listened_ms": 60_000}),
    ("GET", "/v1/history", None),
]


def test_without_database_every_route_says_unavailable() -> None:
    client = _client(None)
    for method, path, body in ROUTES:
        response = client.request(method, path.format(p=uuid.uuid4()), json=body)
        assert response.status_code == 503, (method, path)
        assert response.json() == {"status": "library_unavailable"}


@pytest.mark.real_auth
def test_missing_credentials_do_not_open_user_database(monkeypatch: pytest.MonkeyPatch) -> None:
    # A bearer alone must reach the database since FT-049 (the new app has no
    # shared key); a request with neither a bearer nor the key must not.
    calls = 0

    async def counted_connect(*args: Any, **kwargs: Any) -> None:
        nonlocal calls
        calls += 1
        raise AssertionError("user guard reached the database without credentials")

    monkeypatch.setattr("app.guard.asyncpg.connect", counted_connect)
    client = TestClient(create_app(database_url="postgresql://unused", api_key=secrets.token_urlsafe(32)))
    for headers in ({}, {"x-apertonodo-key": secrets.token_urlsafe(32)}):
        response = client.get("/v1/favorites", headers=headers)
        assert response.status_code == 401
    assert calls == 0


def test_song_ids_never_go_into_the_url() -> None:
    """Path is written to access log: it may only contain the playlist ID."""
    paths = {
        path for path in _app(None).openapi()["paths"]
        if path.startswith(("/v1/favorites", "/v1/playlists", "/v1/history"))
    }
    # History control (FT-630) attached to same app: song ID is in body,
    # not in URL path.
    history_control = {"/v1/history/remove", "/v1/history/clear", "/v1/history/pause"}
    assert paths == {
        path.replace("{p}", "{playlist_id}") for _m, path, _b in ROUTES
    } | history_control
    for path in paths:
        params = [part for part in path.split("/") if part.startswith("{")]
        assert params in ([], ["{playlist_id}"]), path


def test_every_route_uses_only_get_and_post() -> None:
    """NPM in front of production server returns 405 on PUT, PATCH, and DELETE itself.

    Tests don't see this: TestClient talks directly to the application. On 2026-09-20,
    the My Music release passed green, but renaming, deleting, or reordering
    playlists failed on production.
    """
    for path, spec in _app(None).openapi()["paths"].items():
        assert set(spec) <= {"get", "head", "post"}, (path, sorted(spec))


def _everything(client: TestClient) -> list[str]:
    playlist = client.post("/v1/playlists", json={"name": "Секретный вечер"}).json()["id"]
    client.post(f"/v1/playlists/{playlist}/rename", json={"name": "Тайная ночь"})
    for track_id in (ALBUM_ID, DEAD_ID, FIXTURE_ID):
        client.post("/v1/favorites", json={"track_id": track_id})
        client.post(f"/v1/playlists/{playlist}/tracks", json={"track_id": track_id})
        client.post(
            "/v1/history",
            json={
                "track_id": track_id,
                "listened_ms": 60_000,
                "artwork_url": f"/v1/covers/{track_id}",
            },
        )
    client.post(f"/v1/playlists/{playlist}/order", json={"track_ids": [DEAD_ID, ALBUM_ID, FIXTURE_ID]})
    bodies = [
        client.get("/v1/favorites").text,
        client.post("/v1/favorites/contains", json={"track_ids": [SINGLE_ID]}).text,
        client.get("/v1/playlists").text,
        client.get(f"/v1/playlists/{playlist}").text,
        client.get("/v1/history").text,
    ]
    client.post(f"/v1/playlists/{playlist}/tracks/remove", json={"track_id": DEAD_ID})
    client.post("/v1/favorites/remove", json={"track_id": DEAD_ID})
    client.post(f"/v1/playlists/{playlist}/delete")
    return [*bodies, playlist]


def test_library_log_has_no_names_titles_or_ids(prepared_db: str, caplog: pytest.LogCaptureFixture) -> None:
    db = prepared_db
    caplog.set_level(logging.DEBUG, logger="apertonodo")
    *_bodies, playlist = _everything(_client(db))
    # Positive control: My Music log line appears in logs on database failure.
    down = _client("postgresql://music@127.0.0.1:1/nowhere")
    assert down.get("/v1/favorites").status_code == 503
    text = caplog.text.casefold()
    assert "library: database failed" in text
    for secret in (
        "glass", "harbor", "lanterns", "velvet", "slipknot", "duality",
        "секретный", "тайная", playlist, ALBUM_ID, DEAD_ID, FIXTURE_ID,
    ):
        assert secret.casefold() not in text, secret


@pytest.mark.real_auth
def test_library_answers_have_no_words_about_releases(db: str) -> None:
    client = _client(db)
    *bodies, _playlist = _everything(client)
    schema = client.get("/openapi.json").json()
    library_paths = {
        path: spec for path, spec in schema["paths"].items()
        if path.startswith(("/v1/favorites", "/v1/playlists", "/v1/history"))
    }
    assert len(library_paths) == 14  # 11 internal routes and 3 history control routes
    for text in [*bodies, json.dumps(library_paths, ensure_ascii=False)]:
        for word in FORBIDDEN:
            assert word not in text.casefold(), (word, text[:200])


def _shape(value: Any) -> Any:
    if isinstance(value, dict):
        return {key: _shape(item) for key, item in value.items()}
    if isinstance(value, list):
        return [_shape(value[0])] if value else []
    return "number" if isinstance(value, int) and not isinstance(value, bool) else type(value).__name__


@pytest.mark.real_auth
def test_library_answers_match_contracts(db: str) -> None:
    client = _client(db)
    playlist = client.post("/v1/playlists", json={"name": "В дорогу"}).json()["id"]
    client.post(f"/v1/playlists/{playlist}/tracks", json={"track_id": FIXTURE_ID})
    client.post("/v1/favorites", json={"track_id": FIXTURE_ID})
    answers = {
        "favorites": client.get("/v1/favorites").json(),
        "favorites-contains": client.post("/v1/favorites/contains", json={"track_ids": [FIXTURE_ID]}).json(),
        "history-add": client.post("/v1/history", json={"track_id": FIXTURE_ID, "listened_ms": 60_000}).json(),
        "playlists": client.get("/v1/playlists").json(),
        "playlist": client.get(f"/v1/playlists/{playlist}").json(),
        "history": client.get("/v1/history").json(),
    }
    for name, answer in answers.items():
        contract = json.loads((CONTRACTS / f"library-{name}.response.json").read_text())
        assert _shape(answer) == _shape(contract), name
