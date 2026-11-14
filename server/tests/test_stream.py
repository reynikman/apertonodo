from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from fakes import folder_extension
from fastapi.testclient import TestClient

from app.main import create_app

ROOT = Path(__file__).resolve().parents[2]
CATALOG = json.loads((ROOT / "contracts" / "fixtures" / "catalog.json").read_text())["tracks"]
DUALITY_ID = "33333333-3333-3333-3333-333333333333"
FORBIDDEN = ("info_hash", "magnet", "torrent", "file_index", "seeds", "media_path")


@pytest.fixture(scope="module")
def ext():
    with folder_extension() as extensions:
        yield extensions


def _client(ext) -> TestClient:
    return TestClient(create_app(database_url=None, catalog=CATALOG, extensions=ext))


def test_stream_serves_mpeg_bytes(ext) -> None:
    client = _client(ext)
    token = client.post("/v1/playback", json={"track_id": DUALITY_ID}).json()["token"]
    response = client.get(f"/v1/stream/{token}")
    assert response.status_code == 200
    assert "audio/mpeg" in response.headers["content-type"]
    assert len(response.content) > 1000
    dumped = json.dumps(dict(response.headers))
    for word in FORBIDDEN:
        assert word not in dumped


def test_stream_supports_range(ext) -> None:
    client = _client(ext)
    token = client.post("/v1/playback", json={"track_id": DUALITY_ID}).json()["token"]
    response = client.get(f"/v1/stream/{token}", headers={"Range": "bytes=0-9"})
    assert response.status_code == 206
    assert response.content == client.get(f"/v1/stream/{token}").content[:10]


def test_stream_unknown_token_is_404(ext) -> None:
    client = _client(ext)
    response = client.get("/v1/stream/not-a-real-token")
    assert response.status_code == 404


def test_status_does_not_include_media_path(ext) -> None:
    client = _client(ext)
    token = client.post("/v1/playback", json={"track_id": DUALITY_ID}).json()["token"]
    payload = client.get(f"/v1/playback/{token}/status").json()
    dumped = json.dumps(payload)
    for word in FORBIDDEN:
        assert word not in dumped
    # FT-684: audio block is only the file format for the badge, not name or path.
    assert set(payload) <= {"state", "track", "buffered_ms", "audio"}


def test_expired_token_cannot_stream(ext) -> None:
    clock = {"now": datetime(2026, 9, 17, 12, 0, tzinfo=timezone.utc)}
    client = TestClient(
        create_app(
            database_url=None,
            catalog=CATALOG,
            extensions=ext,
            now=lambda: clock["now"],
            token_ttl=timedelta(seconds=30),
        )
    )
    token = client.post("/v1/playback", json={"track_id": DUALITY_ID}).json()["token"]
    assert client.get(f"/v1/stream/{token}").status_code == 200
    clock["now"] = clock["now"] + timedelta(seconds=31)
    assert client.get(f"/v1/stream/{token}").status_code == 404
    assert client.get(f"/v1/playback/{token}/status").status_code == 404
