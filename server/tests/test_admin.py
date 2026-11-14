"""FT-682: admin API — people, their devices, the state of the server.

Guarded here:
- only an administrator or the contour key holder gets in; a signed-in tester gets 403 on every route;
- people are added, switched off and on, given a new password and admin rights; the last active
  administrator can be neither switched off nor demoted;
- switching a person off, a new password and revoking a device end their sessions at once
  (tokens deleted, open streams signalled);
- nothing about listening leaves the module; the log names no person; a password is never echoed.

Not proven here: the web page itself, login from a browser and limits on login attempts (later cards);
the one line in main.py is the lead's at wiring.
"""

from __future__ import annotations

import asyncio
import hashlib
import inspect
import json
import logging
import secrets
import uuid
from pathlib import Path
from typing import Any

import asyncpg
import pytest
from fastapi.testclient import TestClient

import app.admin as admin_module
from app.admin import MAX_PASSWORD, MIN_PASSWORD, install_admin
from app.auth import verify_password
from app.main import create_app
from app.migrate import apply

ROOT = Path(__file__).resolve().parents[2]
CATALOG = json.loads((ROOT / "contracts" / "fixtures" / "catalog.json").read_text())[
    "tracks"
]
KEY = "k" * 32
PASSWORD = "correct horse battery"
STORAGE = {"total_bytes": 1000, "free_bytes": 400, "cache_bytes": 250}


def _db(url: str, query: str, *args: Any, many: bool = False) -> Any:
    async def run() -> Any:
        conn = await asyncpg.connect(url)
        try:
            if many:
                return [dict(r) for r in await conn.fetch(query, *args)]
            return await conn.fetchval(query, *args)
        finally:
            await conn.close()

    return asyncio.run(run())


def _reset(url: str) -> None:
    asyncio.run(apply(url))
    _db(url, "TRUNCATE users CASCADE")


def _app(url: str | None, storage: Any = lambda: dict(STORAGE)) -> Any:
    app = create_app(
        database_url=url,
        catalog=CATALOG,
    )
    install_admin(app, database_url=url, api_key=KEY, storage=storage)
    return app


@pytest.fixture
def client(
    postgres_url: str, test_principal: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> TestClient:
    _reset(postgres_url)
    monkeypatch.setitem(test_principal, "is_admin", True)
    return TestClient(_app(postgres_url))


def _add(client: TestClient, username: str = "anna", **extra: Any) -> dict[str, Any]:
    r = client.post(
        "/v1/admin/users", json={"username": username, "password": PASSWORD, **extra}
    )
    assert r.status_code == 201, r.text
    return r.json()["user"]


def _device(
    url: str, user_id: str, name: str = "Pixel", *, expired: bool = False
) -> tuple[str, str]:
    digest = hashlib.sha256(secrets.token_bytes(16)).hexdigest()
    device_id = _db(
        url,
        f"""INSERT INTO user_tokens (user_id, token_hash, device_name, expires_at)
            VALUES ($1, $2, $3, now() {"-" if expired else "+"} interval '1 day') RETURNING id""",
        uuid.UUID(user_id),
        digest,
        name,
    )
    return str(device_id), digest


def _users(client: TestClient) -> list[dict[str, Any]]:
    r = client.get("/v1/admin/users")
    assert r.status_code == 200
    return r.json()["users"]


ROUTES = [
    ("get", "/v1/admin/users"),
    ("post", "/v1/admin/users"),
    ("post", "/v1/admin/users/{id}/password"),
    ("post", "/v1/admin/users/{id}/active"),
    ("post", "/v1/admin/users/{id}/admin"),
    ("get", "/v1/admin/users/{id}/devices"),
    ("post", "/v1/admin/users/{id}/devices/{id}/revoke"),
    ("get", "/v1/admin/state"),
]


def _call(client: TestClient, method: str, path: str, **kwargs: Any) -> Any:
    if method == "get":
        kwargs.pop("json", None)
    return getattr(client, method)(path.replace("{id}", str(uuid.uuid4())), **kwargs)


# --- who gets in -------------------------------------------------------------------------------


@pytest.mark.parametrize(("method", "path"), ROUTES)
def test_tester_is_refused_everywhere(
    client: TestClient,
    test_principal: dict[str, Any],
    monkeypatch: pytest.MonkeyPatch,
    method: str,
    path: str,
) -> None:
    monkeypatch.setitem(test_principal, "is_admin", False)
    r = _call(
        client,
        method,
        path,
        json={"username": "x", "password": PASSWORD, "active": False},
    )
    assert r.status_code == 403
    assert r.json() == {"status": "forbidden"}


def test_tester_with_a_wrong_or_empty_key_header_stays_out(
    client: TestClient, test_principal: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setitem(test_principal, "is_admin", False)
    for sent in ("", "x" * 32, KEY[:-1], KEY + "k"):
        r = client.get("/v1/admin/users", headers={"x-apertonodo-key": sent})
        assert r.status_code == 403, sent


def test_tester_with_the_real_key_gets_in(
    client: TestClient, test_principal: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setitem(test_principal, "is_admin", False)
    assert (
        client.get("/v1/admin/users", headers={"x-apertonodo-key": KEY}).status_code
        == 200
    )


def test_truthy_but_not_true_admin_flag_is_not_admin(
    client: TestClient, test_principal: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setitem(test_principal, "is_admin", "yes")
    assert client.get("/v1/admin/users").status_code == 403


def test_tester_is_refused_before_the_database_is_touched(
    test_principal: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setitem(test_principal, "is_admin", False)
    client = TestClient(_app(None))
    assert client.get("/v1/admin/users").status_code == 403


@pytest.mark.real_auth
def test_key_holder_without_login_gets_in(postgres_url: str) -> None:
    _reset(postgres_url)
    app = create_app(
        database_url=postgres_url,
        catalog=CATALOG,
        api_key=KEY,
    )
    install_admin(app, database_url=postgres_url, api_key=KEY)
    client = TestClient(app)
    assert client.get("/v1/admin/users").status_code == 401
    assert (
        client.get("/v1/admin/users", headers={"x-apertonodo-key": KEY}).status_code
        == 200
    )


@pytest.mark.parametrize(("method", "path"), ROUTES)
def test_no_database_is_unavailable(
    test_principal: dict[str, Any],
    monkeypatch: pytest.MonkeyPatch,
    method: str,
    path: str,
) -> None:
    monkeypatch.setitem(test_principal, "is_admin", True)
    client = TestClient(_app(None))
    r = _call(
        client,
        method,
        path,
        json={"username": "x", "password": PASSWORD, "active": True, "admin": True},
    )
    assert r.status_code == 503
    assert r.json() == {"status": "unavailable"}


def test_unreachable_database_is_unavailable(
    test_principal: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setitem(test_principal, "is_admin", True)
    client = TestClient(_app("postgresql://music@127.0.0.1:1/none"))
    assert client.get("/v1/admin/state").status_code == 503


@pytest.mark.parametrize(("method", "path"), ROUTES)
def test_answers_are_never_cached(client: TestClient, method: str, path: str) -> None:
    r = _call(
        client,
        method,
        path,
        json={"username": "zed", "password": PASSWORD, "active": True, "admin": True},
    )
    assert r.headers["cache-control"] == "no-store"


# --- people ------------------------------------------------------------------------------------


def test_add_and_list(client: TestClient, postgres_url: str) -> None:
    anna = _add(client, "  Anna ")
    boris = _add(client, "boris", is_admin=True)
    assert anna["username"] == "anna", "username is normalized like at login"
    assert set(anna) == {
        "id",
        "username",
        "is_admin",
        "is_active",
        "created_at",
        "devices",
    }
    assert (anna["is_admin"], anna["is_active"], anna["devices"]) == (False, True, 0)
    assert boris["is_admin"] is True
    assert [u["username"] for u in _users(client)] == ["anna", "boris"]
    stored = _db(
        postgres_url, "SELECT password_hash FROM users WHERE username = 'anna'"
    )
    assert stored != PASSWORD
    assert verify_password(stored, PASSWORD)


def test_list_is_sorted_by_name(client: TestClient) -> None:
    for name in ("zoe", "adam", "mila"):
        _add(client, name)
    assert [u["username"] for u in _users(client)] == ["adam", "mila", "zoe"]


def test_same_name_twice_is_refused_and_first_stays(
    client: TestClient, postgres_url: str
) -> None:
    first = _add(client, "anna")
    r = client.post(
        "/v1/admin/users", json={"username": "ANNA", "password": "another password"}
    )
    assert r.status_code == 409
    assert r.json() == {"status": "exists"}
    assert [u["id"] for u in _users(client)] == [first["id"]]
    assert verify_password(
        _db(postgres_url, "SELECT password_hash FROM users"), PASSWORD
    )


@pytest.mark.parametrize(
    "body",
    [
        {},
        [],
        "anna",
        # {"username": "anna"} alone is valid since FT-856: the person gets an invite code.
        {"password": PASSWORD},
        {"username": "", "password": PASSWORD},
        {"username": "   ", "password": PASSWORD},
        {"username": "a" * 129, "password": PASSWORD},
        {"username": "an\nna", "password": PASSWORD},
        {"username": 5, "password": PASSWORD},
        {"username": "anna", "password": "x" * (MIN_PASSWORD - 1)},
        {"username": "anna", "password": "x" * (MAX_PASSWORD + 1)},
        {"username": "anna", "password": 12345678},
        {"username": "anna", "password": PASSWORD, "is_admin": "yes"},
        {"username": "anna", "password": PASSWORD, "is_admin": 1},
        {"username": "anna", "password": PASSWORD, "is_admin": None},
    ],
)
def test_bad_new_person_is_refused(client: TestClient, body: Any) -> None:
    r = client.post("/v1/admin/users", json=body)
    assert r.status_code == 422
    assert r.json() == {"status": "invalid"}
    assert _users(client) == []


def test_broken_json_is_refused(client: TestClient) -> None:
    r = client.post(
        "/v1/admin/users", content=b"{", headers={"content-type": "application/json"}
    )
    assert r.status_code == 422
    assert r.json() == {"status": "invalid"}


def test_password_length_limits_are_inclusive(client: TestClient) -> None:
    for name, size in (("short", MIN_PASSWORD), ("long", MAX_PASSWORD)):
        r = client.post(
            "/v1/admin/users", json={"username": name, "password": "x" * size}
        )
        assert r.status_code == 201, name


def test_refusal_and_answers_never_echo_the_password(client: TestClient) -> None:
    secret = "tell-nobody-12345"
    replies = [
        client.post("/v1/admin/users", json={"username": "an\nna", "password": secret}),
        client.post("/v1/admin/users", json={"username": "anna", "password": secret}),
        client.post("/v1/admin/users", json={"username": "anna", "password": secret}),
        client.get("/v1/admin/users"),
    ]
    for r in replies:
        assert secret not in r.text
        assert "password" not in r.text


def test_new_password_replaces_old_and_ends_sessions(
    client: TestClient, postgres_url: str
) -> None:
    anna, boris = _add(client, "anna"), _add(client, "boris")
    _device(postgres_url, anna["id"])
    _device(postgres_url, boris["id"])
    r = client.post(
        f"/v1/admin/users/{anna['id']}/password", json={"password": "a brand new one"}
    )
    assert (r.status_code, r.json()) == (200, {"status": "changed"})
    stored = _db(
        postgres_url, "SELECT password_hash FROM users WHERE username = 'anna'"
    )
    assert verify_password(stored, "a brand new one")
    assert not verify_password(stored, PASSWORD)
    left = {u["username"]: u["devices"] for u in _users(client)}
    assert left == {"anna": 0, "boris": 1}, "other users' devices are untouched"
    other = _db(
        postgres_url, "SELECT password_hash FROM users WHERE username = 'boris'"
    )
    assert verify_password(other, PASSWORD)


@pytest.mark.parametrize(
    "body",
    [{}, [], {"password": "short"}, {"password": None}, {"password": "x" * 1025}],
)
def test_bad_new_password_changes_nothing(
    client: TestClient, postgres_url: str, body: Any
) -> None:
    anna = _add(client)
    _device(postgres_url, anna["id"])
    r = client.post(f"/v1/admin/users/{anna['id']}/password", json=body)
    assert (r.status_code, r.json()) == (422, {"status": "invalid"})
    assert verify_password(
        _db(postgres_url, "SELECT password_hash FROM users"), PASSWORD
    )
    assert _users(client)[0]["devices"] == 1


def test_switch_off_ends_sessions_and_switch_on_returns_the_person(
    client: TestClient, postgres_url: str
) -> None:
    anna, boris = _add(client, "anna"), _add(client, "boris")
    _device(postgres_url, anna["id"])
    _device(postgres_url, boris["id"])
    r = client.post(f"/v1/admin/users/{anna['id']}/active", json={"active": False})
    assert (r.status_code, r.json()) == (200, {"status": "inactive"})
    state = {u["username"]: (u["is_active"], u["devices"]) for u in _users(client)}
    assert state == {"anna": (False, 0), "boris": (True, 1)}

    r = client.post(f"/v1/admin/users/{anna['id']}/active", json={"active": True})
    assert (r.status_code, r.json()) == (200, {"status": "active"})
    assert _users(client)[0]["is_active"] is True


def test_switching_on_keeps_sessions(client: TestClient, postgres_url: str) -> None:
    anna = _add(client)
    _device(postgres_url, anna["id"])
    client.post(f"/v1/admin/users/{anna['id']}/active", json={"active": True})
    assert _users(client)[0]["devices"] == 1


@pytest.mark.parametrize(
    "body", [{}, [], {"active": "no"}, {"active": 0}, {"active": None}]
)
def test_bad_switch_changes_nothing(
    client: TestClient, postgres_url: str, body: Any
) -> None:
    anna = _add(client)
    _device(postgres_url, anna["id"])
    r = client.post(f"/v1/admin/users/{anna['id']}/active", json=body)
    assert (r.status_code, r.json()) == (422, {"status": "invalid"})
    assert (_users(client)[0]["is_active"], _users(client)[0]["devices"]) == (True, 1)


def test_last_admin_cannot_be_switched_off(
    client: TestClient, postgres_url: str
) -> None:
    root = _add(client, "root", is_admin=True)
    _add(client, "anna")
    _device(postgres_url, root["id"])
    r = client.post(f"/v1/admin/users/{root['id']}/active", json={"active": False})
    assert (r.status_code, r.json()) == (409, {"status": "last_admin"})
    me = next(u for u in _users(client) if u["username"] == "root")
    assert (me["is_active"], me["devices"]) == (True, 1), "sessions remain"


def test_switched_off_admin_does_not_count_as_the_other_admin(
    client: TestClient,
) -> None:
    root = _add(client, "root", is_admin=True)
    spare = _add(client, "spare", is_admin=True)
    assert (
        client.post(
            f"/v1/admin/users/{spare['id']}/active", json={"active": False}
        ).status_code
        == 200
    )
    r = client.post(f"/v1/admin/users/{root['id']}/active", json={"active": False})
    assert r.json() == {"status": "last_admin"}
    r = client.post(f"/v1/admin/users/{root['id']}/admin", json={"admin": False})
    assert r.json() == {"status": "last_admin"}


def test_one_of_two_admins_can_go(client: TestClient) -> None:
    root = _add(client, "root", is_admin=True)
    _add(client, "spare", is_admin=True)
    assert (
        client.post(
            f"/v1/admin/users/{root['id']}/active", json={"active": False}
        ).status_code
        == 200
    )


def test_ordinary_person_can_be_switched_off_with_no_admins_at_all(
    client: TestClient,
) -> None:
    anna = _add(client)
    assert (
        client.post(
            f"/v1/admin/users/{anna['id']}/active", json={"active": False}
        ).status_code
        == 200
    )


def test_admin_rights_given_and_taken(client: TestClient, postgres_url: str) -> None:
    _add(client, "root", is_admin=True)
    anna = _add(client)
    _device(postgres_url, anna["id"])
    r = client.post(f"/v1/admin/users/{anna['id']}/admin", json={"admin": True})
    assert (r.status_code, r.json()) == (200, {"status": "admin"})
    assert _users(client)[0]["is_admin"] is True
    r = client.post(f"/v1/admin/users/{anna['id']}/admin", json={"admin": False})
    assert (r.status_code, r.json()) == (200, {"status": "user"})
    me = _users(client)[0]
    assert (me["is_admin"], me["devices"]) == (False, 1), "changing rights does not terminate sessions"


def test_last_admin_cannot_be_demoted(client: TestClient) -> None:
    root = _add(client, "root", is_admin=True)
    _add(client, "anna")
    r = client.post(f"/v1/admin/users/{root['id']}/admin", json={"admin": False})
    assert (r.status_code, r.json()) == (409, {"status": "last_admin"})
    assert (
        next(u for u in _users(client) if u["username"] == "root")["is_admin"] is True
    )


def test_switched_off_admin_can_be_demoted(client: TestClient) -> None:
    _add(client, "root", is_admin=True)
    spare = _add(client, "spare", is_admin=True)
    client.post(f"/v1/admin/users/{spare['id']}/active", json={"active": False})
    r = client.post(f"/v1/admin/users/{spare['id']}/admin", json={"admin": False})
    assert (r.status_code, r.json()) == (200, {"status": "user"})


@pytest.mark.parametrize(
    "body", [{}, [], {"admin": "yes"}, {"admin": 1}, {"admin": None}]
)
def test_bad_rights_change_nothing(client: TestClient, body: Any) -> None:
    anna = _add(client)
    r = client.post(f"/v1/admin/users/{anna['id']}/admin", json=body)
    assert (r.status_code, r.json()) == (422, {"status": "invalid"})
    assert _users(client)[0]["is_admin"] is False


@pytest.mark.parametrize(
    ("suffix", "body"),
    [
        ("password", {"password": PASSWORD}),
        ("active", {"active": False}),
        ("admin", {"admin": True}),
    ],
)
@pytest.mark.parametrize("who", ["unknown", "not-a-uuid", "UPPER", "braces"])
def test_unknown_person_is_not_found(
    client: TestClient, suffix: str, body: Any, who: str
) -> None:
    anna = _add(client)
    target = {
        "unknown": str(uuid.uuid4()),
        "not-a-uuid": "42",
        "UPPER": anna["id"].replace("-", ""),
        "braces": "{" + anna["id"] + "}",
    }[who]
    r = client.post(f"/v1/admin/users/{target}/{suffix}", json=body)
    assert (r.status_code, r.json()) == (404, {"status": "not_found"})
    me = _users(client)[0]
    assert (me["is_active"], me["is_admin"]) == (True, False)


def test_no_person_and_no_key_is_refused(
    client: TestClient, test_principal: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    from app.guard import UserGuard

    async def nobody(self: UserGuard, scope: Any, receive: Any, send: Any) -> None:
        await self.app(scope, receive, send)

    monkeypatch.setattr(UserGuard, "__call__", nobody)
    assert client.get("/v1/admin/users").status_code == 403
    assert (
        client.get("/v1/admin/users", headers={"x-apertonodo-key": KEY}).status_code
        == 200
    )


@pytest.mark.parametrize("configured", [None, ""])
def test_server_without_a_key_opens_to_no_header(
    postgres_url: str,
    test_principal: dict[str, Any],
    monkeypatch: pytest.MonkeyPatch,
    configured: str | None,
) -> None:
    _reset(postgres_url)
    monkeypatch.setitem(test_principal, "is_admin", False)
    app = create_app(
        database_url=postgres_url,
        catalog=CATALOG,
    )
    install_admin(app, database_url=postgres_url, api_key=configured)
    client = TestClient(app)
    for sent in ("", "None", "x"):
        assert (
            client.get("/v1/admin/users", headers={"x-apertonodo-key": sent}).status_code
            == 403
        )


def test_first_admin_can_be_appointed(client: TestClient) -> None:
    anna = _add(client)
    r = client.post(f"/v1/admin/users/{anna['id']}/admin", json={"admin": True})
    assert (r.status_code, r.json()) == (200, {"status": "admin"})


def test_switched_off_sole_admin_can_be_demoted(
    client: TestClient, postgres_url: str
) -> None:
    solo = _add(client, "solo", is_admin=True)
    _db(
        postgres_url,
        "UPDATE users SET is_active = false WHERE id = $1",
        uuid.UUID(solo["id"]),
    )
    r = client.post(f"/v1/admin/users/{solo['id']}/admin", json={"admin": False})
    assert (r.status_code, r.json()) == (200, {"status": "user"})


# --- devices -----------------------------------------------------------------------------------


def test_devices_of_one_person_only_and_live_only(
    client: TestClient, postgres_url: str
) -> None:
    anna, boris = _add(client, "anna"), _add(client, "boris")
    first, _ = _device(postgres_url, anna["id"], "Pixel")
    second, _ = _device(postgres_url, anna["id"], "Tablet")
    _device(postgres_url, anna["id"], "Old", expired=True)
    _device(postgres_url, boris["id"], "Other")
    r = client.get(f"/v1/admin/users/{anna['id']}/devices")
    assert r.status_code == 200
    devices = r.json()["devices"]
    assert [(d["id"], d["device_name"]) for d in devices] == [
        (first, "Pixel"),
        (second, "Tablet"),
    ]
    assert set(devices[0]) == {"id", "device_name", "last_used_date", "created_at"}
    assert "token" not in r.text
    assert next(u for u in _users(client) if u["username"] == "anna")["devices"] == 2


def test_devices_of_unknown_person(client: TestClient) -> None:
    r = client.get(f"/v1/admin/users/{uuid.uuid4()}/devices")
    assert (r.status_code, r.json()) == (404, {"status": "not_found"})
    anna = _add(client)
    assert client.get(f"/v1/admin/users/{anna['id']}/devices").json() == {"devices": []}


def test_revoke_one_device(client: TestClient, postgres_url: str) -> None:
    anna = _add(client)
    first, _ = _device(postgres_url, anna["id"], "Pixel")
    second, _ = _device(postgres_url, anna["id"], "Tablet")
    r = client.post(f"/v1/admin/users/{anna['id']}/devices/{first}/revoke")
    assert (r.status_code, r.json()) == (200, {"status": "revoked"})
    left = client.get(f"/v1/admin/users/{anna['id']}/devices").json()["devices"]
    assert [d["id"] for d in left] == [second]
    r = client.post(f"/v1/admin/users/{anna['id']}/devices/{first}/revoke")
    assert (r.status_code, r.json()) == (404, {"status": "not_found"})


def test_device_is_revoked_only_through_its_owner(
    client: TestClient, postgres_url: str
) -> None:
    anna, boris = _add(client, "anna"), _add(client, "boris")
    device, _ = _device(postgres_url, anna["id"])
    r = client.post(f"/v1/admin/users/{boris['id']}/devices/{device}/revoke")
    assert r.status_code == 404
    r = client.post(f"/v1/admin/users/{anna['id']}/devices/nope/revoke")
    assert r.status_code == 404
    assert _users(client)[0]["devices"] == 1


def test_open_streams_are_signalled(client: TestClient, postgres_url: str) -> None:
    anna, boris = _add(client, "anna"), _add(client, "boris")
    events: dict[str, list[asyncio.Event]] = {}
    client.app.state.revocation_events = events  # type: ignore[attr-defined]

    def device(user: dict[str, Any]) -> tuple[str, asyncio.Event]:
        device_id, digest = _device(postgres_url, user["id"])
        events[digest] = [asyncio.Event()]
        return device_id, events[digest][0]

    one, one_event = device(anna)
    _, two_event = device(anna)
    _, other_event = device(boris)

    client.post(f"/v1/admin/users/{anna['id']}/devices/{one}/revoke")
    assert (one_event.is_set(), two_event.is_set(), other_event.is_set()) == (
        True,
        False,
        False,
    )

    _, three_event = device(anna)
    client.post(
        f"/v1/admin/users/{anna['id']}/password", json={"password": "a brand new one"}
    )
    assert (two_event.is_set(), three_event.is_set(), other_event.is_set()) == (
        True,
        True,
        False,
    )

    _, four_event = device(anna)
    client.post(f"/v1/admin/users/{anna['id']}/active", json={"active": False})
    assert (four_event.is_set(), other_event.is_set()) == (True, False)


def test_refused_switch_off_signals_nobody(
    client: TestClient, postgres_url: str
) -> None:
    root = _add(client, "root", is_admin=True)
    _, digest = _device(postgres_url, root["id"])
    event = asyncio.Event()
    client.app.state.revocation_events = {digest: [event]}  # type: ignore[attr-defined]
    client.post(f"/v1/admin/users/{root['id']}/active", json={"active": False})
    assert not event.is_set()


def test_works_without_the_stream_registry(
    client: TestClient, postgres_url: str
) -> None:
    anna = _add(client)
    device, _ = _device(postgres_url, anna["id"])
    if hasattr(client.app.state, "revocation_events"):  # type: ignore[attr-defined]
        del client.app.state.revocation_events  # type: ignore[attr-defined]
    assert (
        client.post(f"/v1/admin/users/{anna['id']}/devices/{device}/revoke").status_code
        == 200
    )


# --- state -------------------------------------------------------------------------------------


def test_state_counts_people_devices_and_space(
    client: TestClient, postgres_url: str
) -> None:
    root = _add(client, "root", is_admin=True)
    anna = _add(client, "anna")
    gone = _add(client, "gone", is_admin=True)
    client.post(f"/v1/admin/users/{gone['id']}/active", json={"active": False})
    _device(postgres_url, root["id"])
    _device(postgres_url, anna["id"])
    _device(postgres_url, anna["id"], expired=True)
    r = client.get("/v1/admin/state")
    assert r.status_code == 200
    assert r.json() == {
        "database": "ok",
        "users": {"total": 3, "active": 2, "admins": 1},
        "devices": 2,
        "storage": STORAGE,
    }


@pytest.mark.parametrize(
    "probe",
    [
        None,
        lambda: {"total_bytes": 1},
        lambda: {**STORAGE, "free_bytes": -1},
        lambda: {**STORAGE, "cache_bytes": "many"},
        lambda: 1 / 0,
    ],
)
def test_state_survives_a_broken_space_probe(
    postgres_url: str,
    test_principal: dict[str, Any],
    monkeypatch: pytest.MonkeyPatch,
    probe: Any,
) -> None:
    _reset(postgres_url)
    monkeypatch.setitem(test_principal, "is_admin", True)
    r = TestClient(_app(postgres_url, storage=probe)).get("/v1/admin/state")
    assert r.status_code == 200
    assert r.json()["storage"] is None
    assert r.json()["database"] == "ok"


def test_space_probe_passes_only_its_three_numbers(
    postgres_url: str, test_principal: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    _reset(postgres_url)
    monkeypatch.setitem(test_principal, "is_admin", True)
    probe = lambda: {**STORAGE, "path": "/srv/music/secret"}  # noqa: E731
    r = TestClient(_app(postgres_url, storage=probe)).get("/v1/admin/state")
    assert r.json()["storage"] == STORAGE
    assert "secret" not in r.text


# --- privacy -----------------------------------------------------------------------------------


def test_log_names_the_action_and_no_person(
    client: TestClient, postgres_url: str, caplog: pytest.LogCaptureFixture
) -> None:
    caplog.set_level(logging.INFO, logger="apertonodo")
    anna = _add(client, "anna-unique-name", is_admin=True)
    _add(client, "root", is_admin=True)
    device, _ = _device(postgres_url, anna["id"], "Anna-Phone")
    client.post(f"/v1/admin/users/{anna['id']}/devices/{device}/revoke")
    client.post(
        f"/v1/admin/users/{anna['id']}/password", json={"password": "a brand new one"}
    )
    client.post(f"/v1/admin/users/{anna['id']}/admin", json={"admin": False})
    client.post(f"/v1/admin/users/{anna['id']}/active", json={"active": False})
    client.post(f"/v1/admin/users/{anna['id']}/active", json={"active": True})
    lines = [
        r.getMessage() for r in caplog.records if r.getMessage().startswith("admin:")
    ]
    assert lines == [
        "admin: user added",
        "admin: user added",
        "admin: device revoked",
        "admin: password changed",
        "admin: rights changed",
        "admin: user disabled",
        "admin: user enabled",
    ]
    text = caplog.text
    for secret in (
        "anna-unique-name",
        anna["id"],
        device,
        "Anna-Phone",
        "a brand new one",
        PASSWORD,
    ):
        assert secret not in text


def test_refusals_are_not_logged_as_actions(
    client: TestClient, caplog: pytest.LogCaptureFixture
) -> None:
    caplog.set_level(logging.INFO, logger="apertonodo")
    root = _add(client, "root", is_admin=True)
    caplog.clear()
    client.post("/v1/admin/users", json={"username": "root", "password": PASSWORD})
    client.post(f"/v1/admin/users/{root['id']}/active", json={"active": False})
    client.post(f"/v1/admin/users/{root['id']}/admin", json={"admin": False})
    client.post(f"/v1/admin/users/{uuid.uuid4()}/password", json={"password": PASSWORD})
    client.post(f"/v1/admin/users/{root['id']}/devices/{uuid.uuid4()}/revoke")
    assert [r for r in caplog.records if r.getMessage().startswith("admin:")] == []


def test_module_does_not_read_what_people_listen_to() -> None:
    source = inspect.getsource(admin_module).lower()
    for word in (
        "listens",
        "favorites",
        "playlists",
        "tracks",
        "history",
        "search",
        "ratings",
    ):
        assert word not in source.split('"""', 2)[2], word
