""" "Go to album" from the song menu (Р-A74 "now", FT-562).

`GET /v1/tracks/{id}/album` — the album of a displayed track from the own
MusicBrainz dump. For an album track, id is the MusicBrainz recording ID; for a search
track — uuid5 of "artist + title" (`app/main.py`). The server knows
both: displayed tracks reside in the `tracks` table (`app/store.py`).

Which album: release group of that recording (or a recording by the same artist with
the same title) that has an official release; studio album before EP
and single, without secondary types (live, compilation) before those with them; among
equals — the earliest. If not found — 404 `not_found`, phone says
"Album not found".
"""

from __future__ import annotations

import asyncio
import uuid

from fastapi.testclient import TestClient
from test_catalog_browse import _extension, LOW_TIDE, SONGS, _app, _seed

from app.main import TRACK_NAMESPACE
from app.canonical import canonical_key
from app.store import persist_tracks


def _search_id(artist: str, title: str) -> str:
    return str(uuid.uuid5(TRACK_NAMESPACE, canonical_key(artist, title)))


def _built(url: str) -> str:
    asyncio.run(_seed(url))
    asyncio.run(_extension().build_catalog(url))
    return url


def _album(client: TestClient, track_id: str) -> tuple[int, dict]:
    response = client.get(f"/v1/tracks/{track_id}/album")
    return response.status_code, response.json()


def test_album_track_opens_its_album(postgres_url: str) -> None:
    url = _built(postgres_url)
    with TestClient(_app(url)) as client:
        # Song of the opened album — already displayed.
        assert client.get(f"/v1/albums/{LOW_TIDE}").status_code == 200
        for title in ("Northern Lights", "Hidden Song"):
            status, body = _album(client, SONGS[title])
            assert status == 200, title
            assert body["album"]["id"] == LOW_TIDE
            assert body["album"]["title"] == "Low Tide"


def test_album_beats_ep_with_the_same_song(postgres_url: str) -> None:
    """"Paper Crown" is on both the Low Tide album and the eponymous EP — navigate to album."""
    url = _built(postgres_url)
    with TestClient(_app(url)) as client:
        assert client.get(f"/v1/albums/{LOW_TIDE}").status_code == 200
        status, body = _album(client, SONGS["Paper Crown"])
        assert status == 200
        assert body["album"]["id"] == LOW_TIDE


def test_search_track_finds_album_by_artist_and_title(postgres_url: str) -> None:
    url = _built(postgres_url)
    found = _search_id("Glass Harbor", "Northern Lights")
    asyncio.run(persist_tracks(url, [
        {"id": found, "title": "Northern Lights", "artist": "Glass Harbor", "duration_ms": 240000},
    ]))
    with TestClient(_app(url)) as client:
        status, body = _album(client, found)
        assert status == 200
        assert body["album"]["id"] == LOW_TIDE


def test_unknown_or_albumless_is_not_found(postgres_url: str) -> None:
    url = _built(postgres_url)
    nowhere = _search_id("Glass Harbor", "Never Recorded")
    asyncio.run(persist_tracks(url, [
        {"id": nowhere, "title": "Never Recorded", "artist": "Glass Harbor", "duration_ms": 1000},
    ]))
    with TestClient(_app(url)) as client:
        for track_id in (nowhere, str(uuid.uuid4())):
            status, body = _album(client, track_id)
            assert status == 404, track_id
            assert body == {"status": "not_found"}
        # Not a uuid — not our id.
        assert client.get("/v1/tracks/not-a-track/album").status_code == 422
