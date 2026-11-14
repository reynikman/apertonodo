from __future__ import annotations

import json
import time
from pathlib import Path

from fakes import folder_extension
from fastapi.testclient import TestClient

from app.main import create_app

ROOT = Path(__file__).resolve().parents[2]
CATALOG = json.loads((ROOT / "contracts" / "fixtures" / "catalog.json").read_text())["tracks"]
DUALITY_ID = "33333333-3333-3333-3333-333333333333"


def test_twenty_cold_legal_fixture_streams_p95_under_5s() -> None:
    with folder_extension() as extensions:
        times = _measure(TestClient(create_app(database_url=None, catalog=CATALOG, extensions=extensions)))
    times.sort()
    p95 = times[int(round(0.95 * (len(times) - 1)))]
    assert p95 <= 5.0, {"p95": p95, "times": times}


def _measure(client: TestClient) -> list[float]:
    times: list[float] = []
    for _ in range(20):
        started = time.perf_counter()
        token = client.post("/v1/playback", json={"track_id": DUALITY_ID}).json()["token"]
        response = client.get(f"/v1/stream/{token}", headers={"Range": "bytes=0-31"})
        elapsed = time.perf_counter() - started
        assert response.status_code in {200, 206}
        assert len(response.content) >= 4
        times.append(elapsed)
    return times
