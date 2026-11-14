"""FT-888: the server speaks new `apertonodo` names and still accepts the old `flowtune` ones."""

import pytest
from fastapi.testclient import TestClient

from app import musicbrainz
from app.main import create_app
from app.env_names import env

KEY = "pytest-key-" + "0" * 24


@pytest.fixture
def client(monkeypatch):
    with TestClient(create_app(database_url=None, catalog=[], api_key=KEY)) as c:
        yield c


@pytest.mark.parametrize("header", ["x-apertonodo-key", "x-flowtune-key"])
def test_key_in_new_or_old_header_opens_v1(client, header):
    assert client.get("/v1/features", headers={header: KEY}).status_code == 200


def test_without_key_is_401(client):
    assert client.get("/v1/features").status_code == 401
    assert client.get("/v1/features", headers={"x-apertonodo-key": "wrong" * 8}).status_code == 401


def test_health_carries_both_revision_headers(monkeypatch):
    monkeypatch.setenv("APERTONODO_REVISION", "b" * 40)
    with TestClient(create_app(database_url=None, catalog=[], api_key=KEY)) as c:
        r = c.get("/v1/health")
    assert r.headers["X-Apertonodo-Revision"] == "b" * 40
    assert r.headers["X-Flowtune-Revision"] == "b" * 40


def test_old_revision_variable_still_works(monkeypatch):
    monkeypatch.delenv("APERTONODO_REVISION", raising=False)
    monkeypatch.setenv("FLOWTUNE_REVISION", "c" * 40)
    with TestClient(create_app(database_url=None, catalog=[], api_key=KEY)) as c:
        r = c.get("/v1/health")
    assert r.headers["X-Apertonodo-Revision"] == "c" * 40


def test_new_variable_wins_over_old(monkeypatch):
    monkeypatch.setenv("FLOWTUNE_X", "old")
    assert env("X") == "old"
    monkeypatch.setenv("APERTONODO_X", "new")
    assert env("X") == "new"
    monkeypatch.delenv("APERTONODO_X")
    monkeypatch.delenv("FLOWTUNE_X")
    assert env("X", "d") == "d"


def test_user_agent_is_apertonodo():
    import inspect

    from app import images, lastfm, mbcopy

    for module in (musicbrainz, lastfm, mbcopy, images):
        source = inspect.getsource(module)
        assert "apertonodo/" in source
        assert '"flowtune/' not in source and 'f"flowtune/' not in source


def test_logger_is_apertonodo():
    from app.log_config import LOGGING_CONFIG

    assert "apertonodo" in LOGGING_CONFIG["loggers"]
    assert "music_stream" not in LOGGING_CONFIG["loggers"]
