from __future__ import annotations

from fastapi.testclient import TestClient

from app.main import create_app


def test_ready_without_database_is_503() -> None:
    client = TestClient(create_app(database_url=None))
    response = client.get("/v1/ready")
    assert response.status_code == 503
    assert response.json()["status"] == "not_ready"
