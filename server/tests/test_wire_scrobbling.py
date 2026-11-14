"""Wiring D1: report from `POST /v1/history` -> queue -> ListenBrainz.

Individual modules are maintained by `test_play_reports.py`, `test_play_sender.py`,
`test_scrobble.py`; here — verifying they are connected in the app. No real
external requests: ListenBrainz — `httpx.MockTransport`.
"""

from __future__ import annotations

import asyncio
import json
import uuid
from pathlib import Path
from typing import Any

import asyncpg
import httpx
import pytest
from fastapi.testclient import TestClient

from app.main import create_app
from app.migrate import apply
from app.play_worker import PlaySender, install_play_sender

ROOT = Path(__file__).resolve().parents[2]
CATALOG = json.loads((ROOT / "contracts" / "fixtures" / "catalog.json").read_text())[
    "tracks"
]
SONG = CATALOG[0]
TOKEN = "3f9a1c52-7b1e-4a44-9d1e-0c5b7e6a2f10"


def _run(url: str, query: str, *args: Any) -> Any:
    async def run() -> Any:
        conn = await asyncpg.connect(url)
        try:
            return await conn.fetch(query, *args)
        finally:
            await conn.close()

    return asyncio.run(run())


@pytest.fixture
def client(postgres_url: str) -> TestClient:
    async def prepare() -> None:
        await apply(postgres_url)
        conn = await asyncpg.connect(postgres_url)
        try:
            await conn.execute(
                "TRUNCATE scrobble_accounts, play_reports, play_deliveries,"
                " listens, history_pause"
            )
        finally:
            await conn.close()

    asyncio.run(prepare())
    app = create_app(
        database_url=postgres_url,
        catalog=CATALOG,
    )
    return TestClient(app)


def _listen(client: TestClient, listen_id: uuid.UUID | None, listened_ms: int) -> Any:
    body: dict[str, Any] = {"track_id": SONG["id"], "listened_ms": listened_ms}
    if listen_id is not None:
        body["listen_id"] = str(listen_id)
        body["started_at"] = "2026-10-11T20:00:00+00:00"
    return client.post("/v1/history", json=body)


def _deliveries(url: str) -> list[tuple[str, str]]:
    rows = _run(url, "SELECT service, state FROM play_deliveries ORDER BY service")
    return [(r["service"], r["state"]) for r in rows]


def test_connect_route_is_installed(client: TestClient) -> None:
    assert client.post("/v1/scrobble/listenbrainz", json={"token": TOKEN}).json() == {
        "listenbrainz": "on"
    }
    assert client.get("/v1/scrobble/lastfm").json() == {"lastfm": "unavailable"}


def test_report_with_listen_id_queues_listenbrainz(
    client: TestClient, postgres_url: str
) -> None:
    client.post("/v1/scrobble/listenbrainz", json={"token": TOKEN})
    listen_id = uuid.uuid4()

    assert _listen(client, listen_id, 1_000).json() == {"recorded": False}
    assert _deliveries(postgres_url) == [], "external threshold not passed"
    assert len(_run(postgres_url, "SELECT 1 FROM play_reports")) == 1

    assert _listen(client, listen_id, SONG["duration_ms"]).json() == {"recorded": True}
    assert _deliveries(postgres_url) == [("listenbrainz", "waiting")]


def test_report_without_listen_id_stays_in_history(
    client: TestClient, postgres_url: str
) -> None:
    client.post("/v1/scrobble/listenbrainz", json={"token": TOKEN})

    assert _listen(client, None, SONG["duration_ms"]).json() == {"recorded": True}
    assert _run(postgres_url, "SELECT 1 FROM play_reports") == []


def test_pause_refuses_reports_and_drops_waiting(
    client: TestClient, postgres_url: str
) -> None:
    client.post("/v1/scrobble/listenbrainz", json={"token": TOKEN})
    _listen(client, uuid.uuid4(), SONG["duration_ms"])

    client.post("/v1/history/pause", json={"paused": True})

    assert _deliveries(postgres_url) == [("listenbrainz", "dropped")]
    assert _listen(client, uuid.uuid4(), SONG["duration_ms"]).json() == {
        "recorded": False
    }
    assert len(_run(postgres_url, "SELECT 1 FROM play_reports")) == 1


def test_sender_pass_sends_the_song(client: TestClient, postgres_url: str) -> None:
    client.post("/v1/scrobble/listenbrainz", json={"token": TOKEN})
    _listen(client, uuid.uuid4(), SONG["duration_ms"])
    sent: list[httpx.Request] = []

    def outside(request: httpx.Request) -> httpx.Response:
        sent.append(request)
        return httpx.Response(200, json={"status": "ok"})

    app: Any = client.app
    sender = PlaySender(app, postgres_url, {}, transport=httpx.MockTransport(outside))

    async def once() -> dict[str, int]:
        try:
            return await sender.once()
        finally:
            await sender.close()

    assert asyncio.run(once()) == {"sent": 1}
    [request] = sent
    meta = json.loads(request.content)["payload"][0]["track_metadata"]
    assert (meta["artist_name"], meta["track_name"]) == (SONG["artist"], SONG["title"])
    assert _deliveries(postgres_url) == [("listenbrainz", "sent")]
    assert set(sender.senders) == {"listenbrainz"}, "without Last.fm secret we do not send"


def test_sender_is_off_unless_asked(client: TestClient, postgres_url: str) -> None:
    app: Any = client.app
    assert app.state.play_sender is None
    install_play_sender(app, database_url=postgres_url, env={"PLAY_SENDER": "1"})
    assert isinstance(app.state.play_sender, PlaySender)
    asyncio.run(app.state.play_sender.close())


def test_worker_starts_and_stops_with_the_server(
    postgres_url: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("PLAY_SENDER", "1")
    app = create_app(
        database_url=postgres_url,
        catalog=CATALOG,
    )
    sender = app.state.play_sender
    assert isinstance(sender, PlaySender)
    with TestClient(app) as running:
        assert running.get("/v1/health").status_code == 200
    assert all(client.is_closed for client in sender._clients)
