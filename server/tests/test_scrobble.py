"""FT-631 (R-A94): scrobbling to ListenBrainz — server side.

A user who tracks their history on ListenBrainz provides their token to Apertonodo, and each
counted listen is submitted there. Without a token, the server sends nothing outside: this is
the only place where a track title leaves the server, and only at the user's explicit request.

Guarded:
- without a token — not a single outgoing request;
- request — strictly according to the ListenBrainz specification (`POST /1/submit-listens`, `Authorization: Token …`);
- network failure, 5xx, and 429 crash nothing and do not mark the token as bad; 401 marks it, and requests stop;
- the token cannot be read back: not in responses, not in parsing errors, not in logs;
- each user has their own connection;
- logs contain no artist names or track titles.

What tests do not prove: that real ListenBrainz accepted the listen (no network in tests); that
the server calls `scrobble` on listening — the call from `history_add` and `install_scrobble` in `main.py`
is inserted by the lead during merge (R-A92). Last.fm is a separate card. The token is stored in the database
as plain text — like the rest of the database contents, it is protected only by access to the server and its backups.
"""

from __future__ import annotations

import asyncio
import json
import logging
import uuid
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import asyncpg
import httpx
import pytest
from fastapi.testclient import TestClient

from app.main import create_app
from app.migrate import apply
from app.scrobble import LISTENBRAINZ_URL, Listen, install_scrobble, scrobble

ROOT = Path(__file__).resolve().parents[2]
CATALOG = json.loads((ROOT / "contracts" / "fixtures" / "catalog.json").read_text())[
    "tracks"
]
TOKEN = "3f9a1c52-7b1e-4a44-9d1e-0c5b7e6a2f10"
PLAYED = datetime(2026, 10, 6, 12, 30, 5, tzinfo=UTC)
LISTEN = Listen(
    artist="Glass Harbor", title="Paper Lanterns", duration_ms=240_500, played_at=PLAYED
)


def _sql(url: str, query: str, *args: Any) -> Any:
    async def run() -> Any:
        conn = await asyncpg.connect(url)
        try:
            return await conn.fetchval(query, *args)
        finally:
            await conn.close()

    return asyncio.run(run())


def _prepare(url: str) -> None:
    async def run() -> None:
        await apply(url)
        conn = await asyncpg.connect(url)
        try:
            await conn.execute("TRUNCATE scrobble_accounts")
        finally:
            await conn.close()

    asyncio.run(run())


def _app(url: str | None) -> Any:
    app = create_app(
        database_url=url,
        catalog=CATALOG,
    )
    install_scrobble(app, database_url=url)
    return app


@pytest.fixture
def client(postgres_url: str) -> TestClient:
    _prepare(postgres_url)
    return TestClient(_app(postgres_url))


class Outside:
    """Test ListenBrainz: remembers requests and returns configured responses."""

    def __init__(self, status: int = 200, error: Exception | None = None) -> None:
        self.status = status
        self.error = error
        self.requests: list[httpx.Request] = []

    def answer(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.error is not None:
            raise self.error
        return httpx.Response(self.status, json={"status": "ok"})


def _scrobble(url: str, user_id: str, outside: Outside, listen: Listen = LISTEN) -> str:
    async def run() -> str:
        conn = await asyncpg.connect(url)
        try:
            async with httpx.AsyncClient(
                transport=httpx.MockTransport(outside.answer)
            ) as http:
                return await scrobble(conn, uuid.UUID(user_id), listen, client=http)
        finally:
            await conn.close()

    return asyncio.run(run())


def _connect(client: TestClient, token: str = TOKEN) -> Any:
    return client.post("/v1/scrobble/listenbrainz", json={"token": token})


def test_without_token_nothing_leaves(
    client: TestClient, postgres_url: str, test_principal: dict[str, Any]
) -> None:
    assert client.get("/v1/scrobble").json() == {"listenbrainz": "off"}
    outside = Outside()
    assert _scrobble(postgres_url, str(test_principal["id"]), outside) == "off"
    assert outside.requests == []


def test_listen_goes_out_as_listenbrainz_wants(
    client: TestClient, postgres_url: str, test_principal: dict[str, Any]
) -> None:
    r = _connect(client, f"  {TOKEN}\n")
    assert r.status_code == 200
    assert r.json() == {"listenbrainz": "on"}
    assert client.get("/v1/scrobble").json() == {"listenbrainz": "on"}

    outside = Outside()
    assert _scrobble(postgres_url, str(test_principal["id"]), outside) == "sent"
    [request] = outside.requests
    assert request.method == "POST"
    assert (
        str(request.url)
        == LISTENBRAINZ_URL
        == "https://api.listenbrainz.org/1/submit-listens"
    )
    assert request.headers["authorization"] == f"Token {TOKEN}"
    assert json.loads(request.content) == {
        "listen_type": "single",
        "payload": [
            {
                "listened_at": int(PLAYED.timestamp()),
                "track_metadata": {
                    "artist_name": "Glass Harbor",
                    "track_name": "Paper Lanterns",
                    "additional_info": {
                        "duration_ms": 240_500,
                        "media_player": "Apertono",
                        "submission_client": "Apertonodo",
                    },
                },
            }
        ],
    }


def test_unknown_duration_is_left_out(
    client: TestClient, postgres_url: str, test_principal: dict[str, Any]
) -> None:
    _connect(client)
    outside = Outside()
    listen = Listen(
        artist="Glass Harbor", title="Northern Wire", duration_ms=0, played_at=PLAYED
    )
    assert _scrobble(postgres_url, str(test_principal["id"]), outside, listen) == "sent"
    info = json.loads(outside.requests[0].content)["payload"][0]["track_metadata"][
        "additional_info"
    ]
    assert "duration_ms" not in info


@pytest.mark.parametrize(
    "outside",
    [
        Outside(status=500),
        Outside(status=503),
        Outside(status=429),
        Outside(error=httpx.ConnectTimeout("slow")),
        Outside(error=httpx.ConnectError("down")),
    ],
)
def test_outside_trouble_breaks_nothing(
    client: TestClient,
    postgres_url: str,
    test_principal: dict[str, Any],
    outside: Outside,
) -> None:
    _connect(client)
    outside.requests.clear()
    assert _scrobble(postgres_url, str(test_principal["id"]), outside) == "failed"
    assert len(outside.requests) == 1, (
        "no retries: listening is not more important than external server"
    )
    assert client.get("/v1/scrobble").json() == {"listenbrainz": "on"}, (
        "token is not to blame"
    )


def test_rejected_token_stops_requests_until_replaced(
    client: TestClient, postgres_url: str, test_principal: dict[str, Any]
) -> None:
    me = str(test_principal["id"])
    _connect(client)
    refused = Outside(status=401)
    assert _scrobble(postgres_url, me, refused) == "bad_token"
    assert client.get("/v1/scrobble").json() == {"listenbrainz": "bad_token"}

    assert _scrobble(postgres_url, me, refused) == "bad_token"
    assert len(refused.requests) == 1, "do not make external requests with a bad token"

    assert _connect(client, "new-token-0123456789").json() == {"listenbrainz": "on"}
    fine = Outside()
    assert _scrobble(postgres_url, me, fine) == "sent"
    assert fine.requests[0].headers["authorization"] == "Token new-token-0123456789"
    assert _sql(postgres_url, "SELECT count(*) FROM scrobble_accounts") == 1


def test_disconnect_forgets_the_token(
    client: TestClient, postgres_url: str, test_principal: dict[str, Any]
) -> None:
    _connect(client)
    r = client.post("/v1/scrobble/listenbrainz/remove")
    assert r.status_code == 200
    assert r.json() == {"listenbrainz": "off"}
    assert _sql(postgres_url, "SELECT count(*) FROM scrobble_accounts") == 0
    outside = Outside()
    assert _scrobble(postgres_url, str(test_principal["id"]), outside) == "off"
    assert outside.requests == []
    assert client.post("/v1/scrobble/listenbrainz/remove").status_code == 200


def test_token_cannot_be_read_back(client: TestClient) -> None:
    for response in (
        _connect(client),
        client.get("/v1/scrobble"),
        client.post("/v1/scrobble/listenbrainz", json={"token": TOKEN, "extra": TOKEN}),
        client.post("/v1/scrobble/listenbrainz", json={"token": TOKEN + " " + TOKEN}),
        client.post("/v1/scrobble/listenbrainz", json={"token": [TOKEN]}),
    ):
        assert TOKEN not in response.text, response.text


@pytest.mark.parametrize(
    "token",
    [
        "",
        "   ",
        "short",
        "x" * 201,
        "two words here",
        "токен-по-русски-0123",
        "line\nbreak-0123456",
        12345,
    ],
)
def test_bad_token_is_refused(
    client: TestClient, postgres_url: str, token: Any
) -> None:
    assert (
        client.post("/v1/scrobble/listenbrainz", json={"token": token}).status_code
        == 422
    )
    assert client.post("/v1/scrobble/listenbrainz", json={}).status_code == 422
    assert _sql(postgres_url, "SELECT count(*) FROM scrobble_accounts") == 0


def test_each_person_has_own_connection(
    client: TestClient,
    postgres_url: str,
    test_principal: dict[str, Any],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    me = str(test_principal["id"])
    other = str(uuid.uuid4())
    _connect(client)

    monkeypatch.setitem(test_principal, "id", other)
    assert client.get("/v1/scrobble").json() == {"listenbrainz": "off"}
    outside = Outside()
    assert _scrobble(postgres_url, other, outside) == "off"
    client.post("/v1/scrobble/listenbrainz/remove")
    assert _scrobble(postgres_url, me, outside) == "sent", "cannot disconnect another user's connection"


def test_log_has_no_token_names_or_titles(
    client: TestClient,
    postgres_url: str,
    test_principal: dict[str, Any],
    caplog: pytest.LogCaptureFixture,
) -> None:
    caplog.set_level(logging.DEBUG)
    me = str(test_principal["id"])
    _connect(client)
    _scrobble(postgres_url, me, Outside())
    _scrobble(
        postgres_url,
        me,
        Outside(error=httpx.ConnectError(f"cannot reach with {TOKEN}")),
    )
    _scrobble(postgres_url, me, Outside(status=401))
    text = "\n".join(r.getMessage() for r in caplog.records)
    assert "scrobble listenbrainz sent" in text
    assert "scrobble listenbrainz failed" in text
    assert "scrobble listenbrainz bad_token" in text
    for secret in (TOKEN, "Glass Harbor", "Paper Lanterns", me):
        assert secret not in text, secret


def test_no_database_is_503() -> None:
    client = TestClient(_app(None))
    for r in (
        client.get("/v1/scrobble"),
        _connect(client),
        client.post("/v1/scrobble/listenbrainz/remove"),
    ):
        assert r.status_code == 503
        assert r.json() == {"status": "library_unavailable"}


@pytest.mark.real_auth
def test_without_login_refused(postgres_url: str) -> None:
    client = TestClient(_app(postgres_url))
    assert client.get("/v1/scrobble").status_code == 401
    assert _connect(client).status_code == 401
    assert client.post("/v1/scrobble/listenbrainz/remove").status_code == 401
