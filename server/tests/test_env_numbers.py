"""An empty environment variable does not crash the server.

It previously crashed this way in production: compose passes unset variables
as empty strings (`CATALOG_COOLDOWN_S: ${CATALOG_COOLDOWN_S:-}`), and code called
`float("")`. The app failed to create upon import, the container entered a restart
loop, and deployment failed with `Connection refused` — the error didn't
reveal the root cause at all, requiring inspection of container logs.

Rule enforced here: "variable unset" and "variable set to empty"
are the same thing for the server.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.main import create_app, env_float

ROOT = Path(__file__).resolve().parents[2]
CATALOG = json.loads((ROOT / "contracts" / "fixtures" / "catalog.json").read_text())["tracks"]


def test_empty_value_means_default(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("CATALOG_TIMEOUT_S", "")
    assert env_float("CATALOG_TIMEOUT_S", 4.0) == 4.0


def test_blank_value_means_default(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("CATALOG_TIMEOUT_S", "   ")
    assert env_float("CATALOG_TIMEOUT_S", 4.0) == 4.0


def test_real_value_wins(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("CATALOG_TIMEOUT_S", "6")
    assert env_float("CATALOG_TIMEOUT_S", 4.0) == 6.0


def test_garbage_does_not_kill_the_server(monkeypatch: pytest.MonkeyPatch) -> None:
    """A typo in an environment variable is no reason not to start up at all."""
    monkeypatch.setenv("CATALOG_TIMEOUT_S", "шесть")
    assert env_float("CATALOG_TIMEOUT_S", 4.0) == 4.0


def test_app_starts_with_all_number_variables_empty(monkeypatch: pytest.MonkeyPatch) -> None:
    """Exactly the scenario that crashed the production server."""
    for name in ("CATALOG_TIMEOUT_S", "CATALOG_COOLDOWN_S", "TORZNAB_TIMEOUT_S"):
        monkeypatch.setenv(name, "")

    with TestClient(create_app(catalog=CATALOG)) as client:
        assert client.get("/v1/health").status_code == 200
