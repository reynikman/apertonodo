from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app.main import create_app


def test_health_ok() -> None:
    client = TestClient(create_app(database_url=None))
    response = client.get("/v1/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_health_carries_revision_header_without_changing_body(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("APERTONODO_REVISION", "a" * 40)
    response = TestClient(create_app(database_url=None)).get("/v1/health")
    assert response.headers["X-Apertonodo-Revision"] == "a" * 40
    assert response.content == b'{"status":"ok"}'


def test_health_has_no_revision_header_when_unset(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("APERTONODO_REVISION", raising=False)
    response = TestClient(create_app(database_url=None)).get("/v1/health")
    assert "X-Apertonodo-Revision" not in response.headers
