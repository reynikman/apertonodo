from __future__ import annotations

import json
from pathlib import Path

import pytest
from fakes import folder_extension
from fastapi import FastAPI, WebSocket
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

import app.main as production
from app.guard import API_KEY_HEADER, MIN_API_KEY_LEN, require_api_key
from app.main import create_app

ROOT = Path(__file__).resolve().parents[2]
CATALOG = json.loads((ROOT / "contracts" / "fixtures" / "catalog.json").read_text())["tracks"]
DUALITY_ID = "33333333-3333-3333-3333-333333333333"
KEY = "guard-test-key-" + "x" * 20
HEADER = API_KEY_HEADER.decode()


def _client() -> TestClient:
    return TestClient(create_app(database_url=None, catalog=CATALOG, api_key=KEY))


def test_health_stays_open_without_key() -> None:
    """Public smoke is on /v1/health — it must work without secrets."""
    response = _client().get("/v1/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_search_without_key_says_nothing_about_catalog() -> None:
    response = _client().get("/v1/search", params={"q": "duality"})
    assert response.status_code == 401
    assert response.json() == {"status": "unauthorized"}
    assert "Duality" not in response.text


def test_wrong_key_is_refused() -> None:
    """Key value is checked, not just header presence."""
    response = _client().get(
        "/v1/search", params={"q": "duality"}, headers={HEADER: KEY + "a"}
    )
    assert response.status_code == 401


def test_search_with_key_works() -> None:
    response = _client().get(
        "/v1/search", params={"q": "duality"}, headers={HEADER: KEY}
    )
    assert response.status_code == 200
    assert response.json()["tracks"]


def test_playback_without_key_issues_no_token() -> None:
    response = _client().post("/v1/playback", json={"track_id": DUALITY_ID})
    assert response.status_code == 401
    assert "token" not in response.text


def test_stream_needs_key_even_with_a_valid_token() -> None:
    """The key point of this step: token is not a pass.

    Token is visible in proxy logs and debug, and lives for an hour. Without a key it
    must not provide a single byte of audio, otherwise the lock protects only search.
    """
    with folder_extension() as extensions:
        client = TestClient(
            create_app(database_url=None, catalog=CATALOG, api_key=KEY, extensions=extensions)
        )
        token = client.post(
            "/v1/playback", json={"track_id": DUALITY_ID}, headers={HEADER: KEY}
        ).json()["token"]
        allowed = client.get(f"/v1/stream/{token}", headers={HEADER: KEY})
        refused = client.get(f"/v1/stream/{token}")

    assert refused.status_code == 401
    assert b"ID3" not in refused.content
    assert "audio/mpeg" not in refused.headers.get("content-type", "")

    assert allowed.status_code == 200
    assert "audio/mpeg" in allowed.headers["content-type"]
    assert len(allowed.content) > 1000


def test_no_endpoint_stays_open_by_accident() -> None:
    """Lock is checked across the entire list of routes, not just three familiar ones.

    This is exactly where any newly added endpoint is caught: if it turns out
    to be open, this test turns red without knowing anything about it beforehand.
    """
    app = create_app(database_url=None, catalog=CATALOG, api_key=KEY)
    client = TestClient(app)
    checked = []
    for route in _flat(app.routes):
        path = str(getattr(route, "path", ""))
        methods = set(getattr(route, "methods", None) or {"GET"})
        # Intentionally open: smoke, login (client has no shared key), and three
        # /admin page files with no data (FT-699). List here is independent, not
        # from guard.py: otherwise the guard would agree with any edit to the lock.
        if not path or path in (
            "/v1/health",
            "/v1/auth/login",
            "/v1/auth/claim",
            "/admin",
            "/admin/",
            "/admin/admin.css",
            "/admin/admin.js",
        ):
            continue
        # Parameter value does not matter: lock responds before route handler.
        probe = "/".join("x" if part.startswith("{") else part for part in path.split("/"))
        method = "GET" if "GET" in methods else sorted(methods)[0]
        response = client.request(method, probe)
        assert response.status_code == 401, f"{method} {probe} is open without key"
        checked.append(probe)
    assert len(checked) >= 6, f"too few paths checked: {checked}"
    # FastAPI 0.141 nests included routers (`include_router`):
    # flat traversal of `app.routes` missed them, silently skipping the test.
    for path in ("/v1/favorites", "/v1/playlists/x/order", "/v1/history", "/v1/admin/users"):
        assert path in checked, f"{path} was not checked: {checked}"


def _flat(routes: list) -> list:
    """Application routes together with routes of included routers."""
    flat = []
    for route in routes:
        inner = getattr(route, "original_router", None)
        flat.extend(_flat(inner.routes) if inner is not None else [route])
    return flat


def test_production_app_is_locked() -> None:
    """`app.main:app` is what uvicorn runs in the container."""
    response = TestClient(production.app).get("/v1/search", params={"q": "duality"})
    assert response.status_code == 401


@pytest.mark.parametrize("env", [{}, {"MUSIC_API_KEY": ""}, {"MUSIC_API_KEY": "test"}])
def test_server_refuses_to_start_without_a_real_key(env: dict[str, str]) -> None:
    with pytest.raises(RuntimeError, match="MUSIC_API_KEY"):
        require_api_key(env)


def test_real_key_is_accepted_and_trimmed() -> None:
    key = "k" * MIN_API_KEY_LEN
    assert require_api_key({"MUSIC_API_KEY": f" {key}\n"}) == key


def _app_with_a_websocket() -> FastAPI:
    """No websocket route yet — adding a probe one, matching how the next one will be added."""
    app = create_app(database_url=None, catalog=CATALOG, api_key=KEY)

    async def probe(websocket: WebSocket) -> None:
        await websocket.accept()
        await websocket.send_text("open")
        await websocket.close()

    app.add_api_websocket_route("/v1/ws-probe", probe)
    return app


def test_websocket_without_key_is_closed_before_accept() -> None:
    """September 18 audit: lock only checked http, websocket bypassed it."""
    client = TestClient(_app_with_a_websocket())
    with pytest.raises(WebSocketDisconnect) as refused:
        with client.websocket_connect("/v1/ws-probe"):
            pass
    assert refused.value.code == 1008


def test_websocket_with_key_opens() -> None:
    client = TestClient(_app_with_a_websocket())
    with client.websocket_connect("/v1/ws-probe", headers={HEADER: KEY}) as websocket:
        assert websocket.receive_text() == "open"
