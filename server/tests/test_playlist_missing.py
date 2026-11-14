"""Playlist row without a song (P5, step 2; Р-A48).

Import does not lose any row: anything missing from the catalog is added to
the playlist as a greyed-out row in its place — with the original "artist — title",
without a song behind it. Such a row can be removed or moved, but cannot be played;
if the song is found later, the row becomes real in the same position.

Fixtures and client are from `test_library.py`: same database and same login.
"""

# Fixtures `db`/`prepared_db` are taken from test_library.py: import and test
# parameter of the same name — this is how pytest finds the fixture, not an unused import.
# ruff: noqa: F401, F811

from __future__ import annotations

import asyncio
import time
import uuid
from typing import Any

import asyncpg
import pytest

import app.library as library
from test_library import (
    ALBUM_ID,
    DEAD_ID,
    OTHER_ID,
    SINGLE_ID,
    _client,
    _ids,
    db,
    prepared_db,
)


def _missing(artist: str, title: str, ms: int | None = None) -> dict[str, Any]:
    return {"track_id": None, "artist": artist, "title": title, "duration_ms": ms}


def _real(track_id: str, artist: str, title: str, ms: int = 240_000) -> dict[str, Any]:
    return {"track_id": track_id, "artist": artist, "title": title, "duration_ms": ms}


def _append(url: str, playlist: str, items: list[dict[str, Any]]) -> int:
    async def run() -> int:
        conn = await asyncpg.connect(url)
        try:
            return await library.append_items(conn, uuid.UUID(playlist), items)
        finally:
            await conn.close()

    return asyncio.run(run())


def _new_playlist(client: Any, name: str = "Импорт") -> str:
    created = client.post("/v1/playlists", json={"name": name})
    assert created.status_code == 201
    return created.json()["id"]


@pytest.mark.real_auth
def test_missing_rows_keep_their_place_and_never_play(db: str) -> None:
    client = _client(db)
    playlist = _new_playlist(client)
    assert (
        client.post(
            f"/v1/playlists/{playlist}/tracks", json={"track_id": ALBUM_ID}
        ).status_code
        == 200
    )

    added = _append(
        db,
        playlist,
        [
            # "Northern Wire" has an active release: if the greyed-out row is asked
            # from the catalog, it answers "playable" — but there is no song behind the row.
            _missing("Glass Harbor", "Northern Wire", 201_000),
            _missing("", "Песня без исполнителя"),
            _real(DEAD_ID, "Glass Harbor", "Velvet Hours"),
        ],
    )
    assert added == 3

    tracks = client.get(f"/v1/playlists/{playlist}").json()["tracks"]
    assert [(t["artist"], t["title"]) for t in tracks] == [
        ("Glass Harbor", "Paper Lanterns"),
        ("Glass Harbor", "Northern Wire"),
        ("", "Песня без исполнителя"),
        ("Glass Harbor", "Velvet Hours"),
    ]
    assert [t.get("missing") is True for t in tracks] == [False, True, True, False]
    assert [t["playable"] for t in tracks] == [True, False, False, False]
    assert [t["duration_ms"] for t in tracks[1:3]] == [201_000, 0]
    assert [t["artwork_url"] for t in tracks[1:3]] == ["", ""]

    # Greyed-out row has its own id: used to remove and move it. Never belongs to another entity.
    ids = _ids({"tracks": tracks})
    assert ids[0] == ALBUM_ID and ids[3] == DEAD_ID
    assert len(set(ids)) == 4
    for missing_id in ids[1:3]:
        assert str(uuid.UUID(missing_id)) == missing_id
        assert missing_id not in (ALBUM_ID, SINGLE_ID, OTHER_ID, DEAD_ID)
        # 404, not 409: no song behind the row, nothing to find audio for.
        assert (
            client.post("/v1/playback", json={"track_id": missing_id}).status_code
            == 404
        )

    assert client.get("/v1/playlists").json()["playlists"] == [
        {"id": playlist, "name": "Импорт", "tracks": 4}
    ]


@pytest.mark.real_auth
def test_missing_row_moves_and_goes_away_like_any_other(db: str) -> None:
    client = _client(db)
    playlist = _new_playlist(client)
    _append(
        db,
        playlist,
        [
            _real(ALBUM_ID, "Glass Harbor", "Paper Lanterns"),
            _missing("Nobody", "Ghost"),
        ],
    )
    album, ghost = _ids(client.get(f"/v1/playlists/{playlist}").json())
    assert album == ALBUM_ID

    assert (
        client.post(
            f"/v1/playlists/{playlist}/order", json={"track_ids": [ghost, album]}
        ).status_code
        == 200
    )
    assert _ids(client.get(f"/v1/playlists/{playlist}").json()) == [ghost, album]

    assert (
        client.post(
            f"/v1/playlists/{playlist}/tracks/remove", json={"track_id": ghost}
        ).status_code
        == 200
    )
    assert _ids(client.get(f"/v1/playlists/{playlist}").json()) == [album]


@pytest.mark.real_auth
def test_found_song_fills_the_missing_row_in_place(db: str) -> None:
    """User tapped a greyed-out row, found the song and added it to the same playlist."""
    client = _client(db)
    playlist = _new_playlist(client)
    _append(
        db,
        playlist,
        [
            _missing("GLASS HARBOR", "Northern Wire!"),
            _real(ALBUM_ID, "Glass Harbor", "Paper Lanterns"),
        ],
    )
    assert (
        client.post(
            f"/v1/playlists/{playlist}/tracks", json={"track_id": OTHER_ID}
        ).status_code
        == 200
    )

    tracks = client.get(f"/v1/playlists/{playlist}").json()["tracks"]
    assert _ids({"tracks": tracks}) == [OTHER_ID, ALBUM_ID]
    assert tracks[0]["title"] == "Northern Wire"
    assert tracks[0].get("missing") is not True
    assert tracks[0]["playable"] is True
    assert tracks[0]["duration_ms"] == 240_000


@pytest.mark.real_auth
def test_append_skips_songs_already_there_and_repeats(db: str) -> None:
    client = _client(db)
    playlist = _new_playlist(client)
    client.post(f"/v1/playlists/{playlist}/tracks", json={"track_id": ALBUM_ID})

    added = _append(
        db,
        playlist,
        [
            _real(
                SINGLE_ID, "Glass Harbor", "Paper Lanterns (2019 Remaster)"
            ),  # same song as ALBUM
            _missing("Nobody", "Ghost"),
            _missing("nobody", "GHOST"),  # duplicate within the file itself
            _missing("Nobody", "Echo"),
        ],
    )
    assert added == 2
    tracks = client.get(f"/v1/playlists/{playlist}").json()["tracks"]
    assert [t["title"] for t in tracks] == ["Paper Lanterns", "Ghost", "Echo"]


@pytest.mark.real_auth
def test_append_of_a_big_import_is_one_quick_write(db: str) -> None:
    client = _client(db)
    playlist = _new_playlist(client)
    items = [_missing(f"Artist {n}", f"Song {n}", 180_000) for n in range(2000)]
    started = time.perf_counter()
    assert _append(db, playlist, items) == 2000
    assert time.perf_counter() - started < 2.0

    tracks = client.get(f"/v1/playlists/{playlist}").json()["tracks"]
    assert len(tracks) == 2000
    assert [t["title"] for t in tracks[:3]] == ["Song 0", "Song 1", "Song 2"]
    assert tracks[-1]["title"] == "Song 1999"
