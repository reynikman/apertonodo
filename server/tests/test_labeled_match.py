from __future__ import annotations

import json
from pathlib import Path

from fastapi.testclient import TestClient

from app.main import create_app

ROOT = Path(__file__).resolve().parents[2]
QUERIES = json.loads((ROOT / "contracts" / "fixtures" / "labeled_queries.json").read_text())


def test_labeled_top1_is_at_least_98_percent() -> None:
    assert len(QUERIES) >= 200
    client = TestClient(create_app(database_url=None))
    hits = 0
    for row in QUERIES:
        payload = client.get("/v1/search", params={"q": row["q"]}).json()
        if payload["tracks"] and payload["tracks"][0]["id"] == row["track_id"]:
            hits += 1
    rate = hits / len(QUERIES)
    assert rate >= 0.98, rate
