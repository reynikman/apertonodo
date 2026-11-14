from __future__ import annotations

import json
from pathlib import Path

from fastapi.testclient import TestClient

from app.main import create_app

ROOT = Path(__file__).resolve().parents[2]


def test_health_contract() -> None:
    expected = json.loads((ROOT / "contracts" / "health.response.json").read_text())
    client = TestClient(create_app(database_url=None))
    assert client.get("/v1/health").json() == expected


def test_playback_contract_hides_sources() -> None:
    payload = json.loads((ROOT / "contracts" / "playback.response.json").read_text())
    forbidden = {"info_hash", "magnet", "torrent", "file_index", "seeds"}
    dumped = json.dumps(payload)
    for word in forbidden:
        assert word not in dumped
    assert payload["state"] == "resolved"
    assert set(payload["track"]) == {"id", "title", "artist", "duration_ms", "artwork_url"}
