from __future__ import annotations

import json
from pathlib import Path

import pytest
from fakes import folder_extension
from fastapi.testclient import TestClient

from app.main import create_app

ROOT = Path(__file__).resolve().parents[2]
CATALOG = json.loads((ROOT / "contracts" / "fixtures" / "catalog.json").read_text())["tracks"]
FORBIDDEN = {"info_hash", "magnet", "torrent", "file_index", "seeds", "infohash"}
DUALITY_ID = "33333333-3333-3333-3333-333333333333"


@pytest.fixture(scope="module")
def ext():
    with folder_extension() as extensions:
        yield extensions


def test_playback_resolves_without_source_leak(ext) -> None:
    client = TestClient(create_app(database_url=None, catalog=CATALOG, extensions=ext))
    response = client.post("/v1/playback", json={"track_id": DUALITY_ID})
    assert response.status_code == 200
    payload = response.json()
    assert payload["state"] == "ready"
    assert payload["token"]
    dumped = json.dumps(payload)
    assert FORBIDDEN.isdisjoint(payload)
    for word in FORBIDDEN:
        assert word not in dumped
    assert set(payload["track"]) == {"id", "title", "artist", "duration_ms", "artwork_url"}


def test_playback_rejects_low_confidence_without_token() -> None:
    catalog = [
        {
            "id": "99999999-0000-0000-0000-000000000001",
            "title": "Unknown Song",
            "artist": "Nobody",
            "duration_ms": 180000,
            "artwork_url": "https://coverartarchive.org/release/x/front",
        }
    ]
    client = TestClient(create_app(database_url=None, catalog=catalog))
    response = client.post(
        "/v1/playback", json={"track_id": "99999999-0000-0000-0000-000000000001"}
    )
    assert response.status_code == 409
    payload = response.json()
    assert payload["state"] == "unresolved"
    assert "token" not in payload


def test_playback_status_hides_source_ids(ext) -> None:
    client = TestClient(create_app(database_url=None, catalog=CATALOG, extensions=ext))
    token = client.post("/v1/playback", json={"track_id": DUALITY_ID}).json()["token"]
    status = client.get(f"/v1/playback/{token}/status")
    assert status.status_code == 200
    payload = status.json()
    assert payload["state"] == "ready"
    dumped = json.dumps(payload)
    for word in FORBIDDEN:
        assert word not in dumped
