"""Wiring 2 (11.10): history control (FT-630) and ratings (FT-629) in
the real application — `create_app` without manual `install_*`. Recording pause
reaches `POST /v1/history`: while it is active, listening is not recorded.
"""

from __future__ import annotations

from collections.abc import Iterator
from typing import Any

import pytest
from fastapi.testclient import TestClient
from test_history_control import CATALOG, FIRST_ID, SECOND_ID, _prepare, _sql

from app.main import create_app


@pytest.fixture
def client(postgres_url: str) -> Iterator[TestClient]:
    _prepare(postgres_url)
    app = create_app(
        database_url=postgres_url,
        catalog=CATALOG,
    )
    yield TestClient(app)
    _sql(postgres_url, "TRUNCATE history_pause")


def _listen(client: TestClient, track_id: str) -> Any:
    return client.post(
        "/v1/history", json={"track_id": track_id, "listened_ms": 60_000}
    ).json()


def test_pause_stops_recording_and_resume_records_again(client: TestClient) -> None:
    assert _listen(client, FIRST_ID) == {"recorded": True}
    paused = client.post("/v1/history/pause", json={"paused": True})
    assert paused.status_code == 200, paused.text
    assert client.get("/v1/history/pause").json()["paused"] is True

    assert _listen(client, SECOND_ID) == {"recorded": False}
    titles = [row["id"] for row in client.get("/v1/history").json()["tracks"]]
    assert titles == [FIRST_ID]

    client.post("/v1/history/pause", json={"paused": False})
    assert _listen(client, SECOND_ID) == {"recorded": True}


def test_remove_and_clear_are_reachable(client: TestClient) -> None:
    _listen(client, FIRST_ID)
    _listen(client, SECOND_ID)
    row = client.get("/v1/history").json()["tracks"][0]
    removed = client.post(
        "/v1/history/remove",
        json={"track_id": row["id"], "played_at": row["played_at"]},
    )
    assert removed.status_code == 200, removed.text
    assert [r["id"] for r in client.get("/v1/history").json()["tracks"]] == [FIRST_ID]

    assert client.post("/v1/history/clear").status_code == 200
    assert client.get("/v1/history").json()["tracks"] == []


def test_ratings_are_reachable(client: TestClient) -> None:
    put = client.post("/v1/ratings", json={"track_id": FIRST_ID, "stars": 4})
    assert put.status_code == 200, put.text
    got = client.post("/v1/ratings/of", json={"track_ids": [FIRST_ID]})
    assert got.status_code == 200, got.text
