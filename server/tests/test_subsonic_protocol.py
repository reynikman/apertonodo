"""FT-632 (Р-A94, Р-A16): OpenSubsonic server, first layer — "handshake" with third-party player.

Third-party players (Symfonium, DSub, Tempo, Feishin) communicate with the server in Subsonic dialect: `/rest/…` endpoints,
credentials in parameters, response in single envelope `subsonic-response`, error — code inside 200 response.
This card is language only: envelope, error codes, authentication, three utility endpoints. No music here yet.

Guarded:
- envelope and error codes match OpenSubsonic spec (JSON and XML);
- login by key (`apiKey`) and password (`p`, including `enc:`); "token + salt" login is honestly rejected
  with code 41 — server hashes passwords irreversibly and cannot verify such login;
- two login methods at once is rejected, rather than picking randomly;
- `getOpenSubsonicExtensions` responds without login (per spec), rest — only after login;
- parameters accepted both in URL and in POST body (`formPost` extension);
- logs contain no username, password, or key.

What tests do not prove: that real player connected; that login verifies real accounts
(verification is passed from outside — `SubsonicAuth`); that `/rest/…` endpoints are exposed on server — wiring in
`main.py`, guard entry (`guard.py`), and rate limiting brute force is done by lead on merge (Р-A92).
"""

from __future__ import annotations

import logging
from typing import Any
from xml.etree import ElementTree

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.subsonic import SubsonicUser, install_subsonic

NS = "{http://subsonic.org/restapi}"
PASSWORD = "sesam öffne dich"
API_KEY = "k9Qm2-apertonodo-key-7f3a"


class Accounts:
    """Test auth checker: one user, one password, one key."""

    def __init__(self) -> None:
        self.password_calls: list[tuple[str, str]] = []
        self.key_calls: list[str] = []

    async def by_password(self, username: str, password: str) -> SubsonicUser | None:
        self.password_calls.append((username, password))
        if username == "anna" and password == PASSWORD:
            return SubsonicUser(id="u-1", username="anna")
        return None

    async def by_api_key(self, api_key: str) -> SubsonicUser | None:
        self.key_calls.append(api_key)
        return SubsonicUser(id="u-1", username="anna") if api_key == API_KEY else None


@pytest.fixture
def accounts() -> Accounts:
    return Accounts()


@pytest.fixture
def client(accounts: Accounts) -> TestClient:
    app = FastAPI()
    install_subsonic(app, auth=accounts, server_version="0.9.0")
    return TestClient(app)


BY_KEY = {"apiKey": API_KEY, "v": "1.16.1", "c": "pytest", "f": "json"}
BY_PASSWORD = {"u": "anna", "p": PASSWORD, "v": "1.16.1", "c": "pytest", "f": "json"}


def _body(response: Any) -> dict[str, Any]:
    assert response.status_code == 200, response.text
    assert response.headers["content-type"].startswith("application/json")
    return response.json()["subsonic-response"]


def _ok(response: Any) -> dict[str, Any]:
    body = _body(response)
    assert body["status"] == "ok", body
    return body


def _error(response: Any) -> dict[str, Any]:
    body = _body(response)
    assert body["status"] == "failed", body
    assert set(body) == {
        "status",
        "version",
        "type",
        "serverVersion",
        "openSubsonic",
        "error",
    }
    assert isinstance(body["error"]["message"], str) and body["error"]["message"]
    return body["error"]


def test_ping_envelope(client: TestClient) -> None:
    assert _ok(client.get("/rest/ping", params=BY_KEY)) == {
        "status": "ok",
        "version": "1.16.1",
        "type": "Apertonodo",
        "serverVersion": "0.9.0",
        "openSubsonic": True,
    }


def test_view_suffix_and_post_form(client: TestClient) -> None:
    assert _ok(client.get("/rest/ping.view", params=BY_KEY))["status"] == "ok"
    assert _ok(client.post("/rest/ping.view", data=BY_KEY))["status"] == "ok"
    assert _ok(client.post("/rest/ping", data=BY_PASSWORD))["status"] == "ok"
    # Part of parameters in query, part in body — also common among players.
    mixed = client.post(
        "/rest/ping", params={"f": "json", "c": "pytest"}, data={"apiKey": API_KEY}
    )
    assert _ok(mixed)["status"] == "ok"


def test_xml_is_the_default_format(client: TestClient) -> None:
    params = {k: v for k, v in BY_KEY.items() if k != "f"}
    for response in (
        client.get("/rest/ping", params=params),
        client.get("/rest/ping", params={**params, "f": "xml"}),
    ):
        assert response.status_code == 200
        assert response.headers["content-type"].startswith(
            ("application/xml", "text/xml")
        )
        root = ElementTree.fromstring(response.content)
        assert root.tag == f"{NS}subsonic-response"
        assert root.attrib == {
            "status": "ok",
            "version": "1.16.1",
            "type": "Apertonodo",
            "serverVersion": "0.9.0",
            "openSubsonic": "true",
        }


def test_xml_error_and_license(client: TestClient) -> None:
    root = ElementTree.fromstring(
        client.get("/rest/ping", params={"apiKey": "wrong"}).content
    )
    assert root.attrib["status"] == "failed"
    [error] = root.findall(f"{NS}error")
    assert error.attrib["code"] == "44"
    assert error.attrib["message"]

    params = {k: v for k, v in BY_KEY.items() if k != "f"}
    root = ElementTree.fromstring(client.get("/rest/getLicense", params=params).content)
    [licence] = root.findall(f"{NS}license")
    assert licence.attrib["valid"] == "true"


def test_password_login_plain_and_hex(client: TestClient, accounts: Accounts) -> None:
    assert _ok(client.get("/rest/ping", params=BY_PASSWORD))["status"] == "ok"
    encoded = "enc:" + PASSWORD.encode().hex()
    assert (
        _ok(client.get("/rest/ping", params={**BY_PASSWORD, "p": encoded}))["status"]
        == "ok"
    )
    assert accounts.password_calls == [("anna", PASSWORD), ("anna", PASSWORD)]

    assert (
        _error(client.get("/rest/ping", params={**BY_PASSWORD, "p": "nope"}))["code"]
        == 40
    )
    assert (
        _error(client.get("/rest/ping", params={**BY_PASSWORD, "u": "boris"}))["code"]
        == 40
    )
    assert (
        _error(client.get("/rest/ping", params={**BY_PASSWORD, "p": "enc:zz"}))["code"]
        == 40
    )


def test_wrong_api_key(client: TestClient) -> None:
    assert (
        _error(client.get("/rest/ping", params={**BY_KEY, "apiKey": "wrong"}))["code"]
        == 44
    )


def test_token_and_salt_login_is_honestly_refused(
    client: TestClient, accounts: Accounts
) -> None:
    params = {
        "u": "anna",
        "t": "26719a1196d2a940705a59634eb18eab",
        "s": "c19b2d",
        "f": "json",
    }
    assert _error(client.get("/rest/ping", params=params))["code"] == 41
    assert accounts.password_calls == [] and accounts.key_calls == []


def test_conflicting_or_missing_credentials(
    client: TestClient, accounts: Accounts
) -> None:
    both = {**BY_KEY, "u": "anna"}
    assert _error(client.get("/rest/ping", params=both))["code"] == 43
    with_password = {**BY_KEY, "u": "anna", "p": PASSWORD}
    assert _error(client.get("/rest/ping", params=with_password))["code"] == 43
    assert accounts.password_calls == [] and accounts.key_calls == []

    assert _error(client.get("/rest/ping", params={"f": "json"}))["code"] == 10
    assert (
        _error(client.get("/rest/ping", params={"f": "json", "u": "anna"}))["code"]
        == 10
    )
    assert (
        _error(client.get("/rest/ping", params={"f": "json", "p": PASSWORD}))["code"]
        == 10
    )
    assert (
        _error(client.get("/rest/ping", params={"f": "json", "apiKey": ""}))["code"]
        == 10
    )


def test_license_and_token_info(client: TestClient) -> None:
    assert _ok(client.get("/rest/getLicense", params=BY_KEY))["license"] == {
        "valid": True
    }
    assert _ok(client.get("/rest/tokenInfo", params=BY_KEY))["tokenInfo"] == {
        "username": "anna"
    }
    by_password = client.get("/rest/tokenInfo.view", params=BY_PASSWORD)
    assert _ok(by_password)["tokenInfo"] == {"username": "anna"}


def test_extensions_are_public_everything_else_is_not(
    client: TestClient, accounts: Accounts
) -> None:
    body = _ok(client.get("/rest/getOpenSubsonicExtensions", params={"f": "json"}))
    assert body["openSubsonicExtensions"] == [
        {"name": "apiKeyAuthentication", "versions": [1]},
        {"name": "formPost", "versions": [1]},
    ]
    assert accounts.password_calls == [] and accounts.key_calls == []
    wrong = {"f": "json", "apiKey": "wrong"}
    assert (
        _ok(client.get("/rest/getOpenSubsonicExtensions.view", params=wrong))["status"]
        == "ok"
    )

    for method in ("ping", "getLicense", "tokenInfo"):
        assert (
            _error(client.get(f"/rest/{method}", params={"f": "json"}))["code"] == 10
        ), method
        assert _error(client.get(f"/rest/{method}", params=wrong))["code"] == 44, method


def test_unknown_method_is_an_error_after_login(client: TestClient) -> None:
    assert (
        _error(client.get("/rest/jukeboxControl", params={"f": "json"}))["code"] == 10
    )
    error = _error(client.get("/rest/jukeboxControl.view", params=BY_KEY))
    assert error["code"] == 0
    assert "jukeboxControl" not in error["message"], (
        "do not echo foreign text from url back in response"
    )


def test_auth_check_failing_is_a_generic_error(
    client: TestClient, accounts: Accounts, caplog: pytest.LogCaptureFixture
) -> None:
    caplog.set_level(logging.DEBUG)

    async def broken(api_key: str) -> SubsonicUser | None:
        raise RuntimeError(f"database down while checking {api_key}")

    accounts.by_api_key = broken  # type: ignore[method-assign]
    response = client.get("/rest/ping", params=BY_KEY)
    assert _error(response)["code"] == 0
    assert API_KEY not in response.text
    # Exception text contains the key: neither it, nor trace, nor query params must hit the log.
    ours = [r for r in caplog.records if r.name == "apertonodo"]
    assert ours, "auth check failure must leave a log line"
    for record in ours:
        assert API_KEY not in record.getMessage()
        assert record.exc_info is None


def test_log_has_no_credentials(
    client: TestClient, caplog: pytest.LogCaptureFixture, accounts: Accounts
) -> None:
    caplog.set_level(logging.DEBUG)
    client.get("/rest/ping", params=BY_KEY)
    client.get("/rest/ping", params=BY_PASSWORD)
    client.get(
        "/rest/ping", params={**BY_PASSWORD, "p": "enc:" + PASSWORD.encode().hex()}
    )
    client.get("/rest/ping", params={**BY_PASSWORD, "p": "wrong-guess-123"})
    client.post("/rest/ping", data={**BY_KEY, "apiKey": "wrong-key-456"})
    text = "\n".join(r.getMessage() for r in caplog.records if r.name == "apertonodo")
    for secret in (
        API_KEY,
        PASSWORD,
        PASSWORD.encode().hex(),
        "anna",
        "wrong-guess-123",
        "wrong-key-456",
    ):
        assert secret not in text, secret
