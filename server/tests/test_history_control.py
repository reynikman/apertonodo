"""FT-630 (Р-A49): user-controlled history — remove entry, clear all, pause recording.

Currently history is only written: removing a song from it or asking the server not to record for some time
is impossible. Here is the server side of three actions.

Guarded:
- exactly one row is deleted — the one the user saw (song + timestamp), not all listenings of the song;
- clear wipes all history of the user and only theirs;
- "Do not record to history" automatically turns off after three hours;
- another user's history and pause cannot be seen or altered;
- no titles, artists, or IDs in the logs.

What tests do not prove: that listen recording (`POST /v1/history`) remains silent during a pause — the
`history_paused` check is inserted into it by the lead at merge time (Р-A92), as is the `install_history_control` call;
UI buttons and 5-second "Undo" belong to the app, a separate card.
"""

from __future__ import annotations

import asyncio
import json
import logging
import uuid
from datetime import UTC, datetime, timedelta
from pathlib import Path
from collections.abc import Iterator
from typing import Any

import asyncpg
import pytest
from fastapi.testclient import TestClient

from app.history_control import history_paused, install_history_control
from app.main import create_app
from app.migrate import apply
from app.store import persist_tracks

ROOT = Path(__file__).resolve().parents[2]
CATALOG = json.loads((ROOT / "contracts" / "fixtures" / "catalog.json").read_text())[
    "tracks"
]

FIRST_ID = str(uuid.uuid4())
SECOND_ID = str(uuid.uuid4())
THIRD_ID = str(uuid.uuid4())


def _song(track_id: str, title: str) -> dict[str, Any]:
    return {
        "id": track_id,
        "title": title,
        "artist": "Glass Harbor",
        "duration_ms": 240_000,
        "artwork_url": "",
    }


SONGS = [
    _song(FIRST_ID, "Paper Lanterns"),
    _song(SECOND_ID, "Northern Wire"),
    _song(THIRD_ID, "Velvet Hours"),
]


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
            await conn.execute("TRUNCATE listens, history_pause")
            await conn.execute(
                "DELETE FROM tracks WHERE id = ANY($1::uuid[])",
                [s["id"] for s in SONGS],
            )
        finally:
            await conn.close()
        await persist_tracks(url, SONGS)

    asyncio.run(run())


def _app(url: str | None) -> Any:
    app = create_app(
        database_url=url,
        catalog=CATALOG,
    )
    install_history_control(app, database_url=url)
    return app


@pytest.fixture
def client(postgres_url: str) -> Iterator[TestClient]:
    _prepare(postgres_url)
    yield TestClient(_app(postgres_url))
    # Pause is connected to history recording: left active, it would silently
    # disable recording in other tests of the same user.
    _sql(postgres_url, "TRUNCATE history_pause")


def _listen(client: TestClient, *track_ids: str) -> None:
    for track_id in track_ids:
        r = client.post(
            "/v1/history", json={"track_id": track_id, "listened_ms": 60_000}
        )
        assert r.json() == {"recorded": True}


def _history(client: TestClient) -> list[dict[str, Any]]:
    return client.get("/v1/history").json()["tracks"]


def _remove(client: TestClient, row: dict[str, Any]) -> Any:
    return client.post(
        "/v1/history/remove",
        json={"track_id": row["id"], "played_at": row["played_at"]},
    )


def test_remove_deletes_exactly_the_row_seen(client: TestClient) -> None:
    _listen(client, FIRST_ID, SECOND_ID, FIRST_ID, THIRD_ID)
    rows = _history(client)
    assert [r["id"] for r in rows] == [THIRD_ID, FIRST_ID, SECOND_ID, FIRST_ID]

    r = _remove(client, rows[1])
    assert r.status_code == 200
    assert r.json() == {"removed": 1}
    left = _history(client)
    assert [r["id"] for r in left] == [THIRD_ID, SECOND_ID, FIRST_ID], (
        "second listen remained"
    )
    assert left[2]["played_at"] == rows[3]["played_at"]

    assert _remove(client, rows[1]).json() == {"removed": 0}, "already removed — not an error"
    assert len(_history(client)) == 3


def test_remove_needs_both_song_and_time(client: TestClient) -> None:
    _listen(client, FIRST_ID, SECOND_ID)
    first_seen, second_seen = _history(client)[1], _history(client)[0]
    swapped = {"id": first_seen["id"], "played_at": second_seen["played_at"]}
    assert _remove(client, swapped).json() == {"removed": 0}
    assert len(_history(client)) == 2


@pytest.mark.parametrize(
    "body",
    [
        {},
        {"track_id": FIRST_ID},
        {"played_at": "2026-10-06T12:00:00+00:00"},
        {"track_id": "not-a-uuid", "played_at": "2026-10-06T12:00:00+00:00"},
        {"track_id": FIRST_ID, "played_at": "вчера"},
        {"track_id": FIRST_ID, "played_at": "2026-10-06T12:00:00"},
        {"track_id": FIRST_ID, "played_at": "2026-10-06T12:00:00+00:00", "all": True},
    ],
)
def test_bad_remove_is_refused(client: TestClient, body: dict[str, Any]) -> None:
    _listen(client, FIRST_ID)
    assert client.post("/v1/history/remove", json=body).status_code == 422
    assert len(_history(client)) == 1


def test_clear_wipes_own_history_only(
    client: TestClient, test_principal: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    _listen(client, FIRST_ID, SECOND_ID, THIRD_ID)
    mine = _history(client)

    me = test_principal["id"]
    monkeypatch.setitem(test_principal, "id", str(uuid.uuid4()))
    _listen(client, SECOND_ID)
    assert _remove(client, mine[0]).json() == {"removed": 0}, "cannot remove another user's entry"
    r = client.post("/v1/history/clear")
    assert r.status_code == 200
    assert r.json() == {"removed": 1}
    assert _history(client) == []
    assert client.post("/v1/history/clear").json() == {"removed": 0}

    monkeypatch.setitem(test_principal, "id", me)
    assert [r["id"] for r in _history(client)] == [THIRD_ID, SECOND_ID, FIRST_ID]
    assert client.post("/v1/history/clear").json() == {"removed": 3}
    assert client.get("/v1/history").json() == {"tracks": [], "total": 0}


def _paused(url: str, user_id: str) -> bool:
    async def run() -> bool:
        conn = await asyncpg.connect(url)
        try:
            return await history_paused(conn, uuid.UUID(user_id))
        finally:
            await conn.close()

    return asyncio.run(run())


def test_pause_turns_itself_off_after_three_hours(
    client: TestClient, postgres_url: str, test_principal: dict[str, Any]
) -> None:
    me = str(test_principal["id"])
    assert client.get("/v1/history/pause").json() == {"paused": False, "until": None}
    assert _paused(postgres_url, me) is False

    before = datetime.now(UTC)
    r = client.post("/v1/history/pause", json={"paused": True})
    assert r.status_code == 200
    answer = r.json()
    assert answer["paused"] is True
    until = datetime.fromisoformat(answer["until"])
    assert until.tzinfo is not None
    assert (
        timedelta(hours=2, minutes=59) < until - before < timedelta(hours=3, minutes=1)
    )
    assert client.get("/v1/history/pause").json() == answer
    assert _paused(postgres_url, me) is True

    # Three hours passed: deadline in the past — pause expired on its own.
    _sql(postgres_url, "UPDATE history_pause SET until = now() - interval '1 second'")
    assert client.get("/v1/history/pause").json() == {"paused": False, "until": None}
    assert _paused(postgres_url, me) is False


def test_pause_takes_the_deadline_the_person_chose(
    client: TestClient, postgres_url: str, test_principal: dict[str, Any]
) -> None:
    """FT-853: an hour, till tomorrow or "until I turn it back on" — the app
    names the deadline, the server keeps exactly it."""
    me = str(test_principal["id"])
    hour = datetime.now(UTC).replace(microsecond=0) + timedelta(hours=1)
    r = client.post(
        "/v1/history/pause", json={"paused": True, "until": hour.isoformat()}
    )
    assert r.status_code == 200
    answer = r.json()
    assert answer["paused"] is True
    assert datetime.fromisoformat(answer["until"]) == hour
    assert client.get("/v1/history/pause").json() == answer
    assert _paused(postgres_url, me) is True

    # "Until I turn it back on" is a deadline far away, not a special state.
    far = datetime.now(UTC).replace(microsecond=0) + timedelta(days=365 * 100)
    r = client.post(
        "/v1/history/pause", json={"paused": True, "until": far.isoformat()}
    )
    assert r.status_code == 200
    assert datetime.fromisoformat(r.json()["until"]) == far
    assert _sql(postgres_url, "SELECT count(*) FROM history_pause") == 1


def test_pause_refuses_a_deadline_that_has_passed(
    client: TestClient, postgres_url: str, test_principal: dict[str, Any]
) -> None:
    me = str(test_principal["id"])
    past = datetime.now(UTC) - timedelta(minutes=1)
    r = client.post(
        "/v1/history/pause", json={"paused": True, "until": past.isoformat()}
    )
    assert r.status_code == 422
    assert _paused(postgres_url, me) is False
    # A deadline without a time zone is ambiguous — refused as well.
    r = client.post(
        "/v1/history/pause", json={"paused": True, "until": "2099-01-01T00:00:00"}
    )
    assert r.status_code == 422


def test_pause_again_restarts_the_clock_and_off_is_off(
    client: TestClient, postgres_url: str, test_principal: dict[str, Any]
) -> None:
    me = str(test_principal["id"])
    client.post("/v1/history/pause", json={"paused": True})
    _sql(postgres_url, "UPDATE history_pause SET until = now() + interval '5 minutes'")
    again = client.post("/v1/history/pause", json={"paused": True}).json()
    left = datetime.fromisoformat(again["until"]) - datetime.now(UTC)
    assert left > timedelta(hours=2, minutes=59), "re-enabling — three hours again"
    assert _sql(postgres_url, "SELECT count(*) FROM history_pause") == 1

    off = client.post("/v1/history/pause", json={"paused": False})
    assert off.json() == {"paused": False, "until": None}
    assert _paused(postgres_url, me) is False
    assert _sql(postgres_url, "SELECT count(*) FROM history_pause") == 0
    assert client.post("/v1/history/pause", json={"paused": False}).status_code == 200


def test_pause_is_personal(
    client: TestClient,
    postgres_url: str,
    test_principal: dict[str, Any],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    me = str(test_principal["id"])
    other = str(uuid.uuid4())
    client.post("/v1/history/pause", json={"paused": True})

    monkeypatch.setitem(test_principal, "id", other)
    assert client.get("/v1/history/pause").json() == {"paused": False, "until": None}
    assert _paused(postgres_url, other) is False
    client.post("/v1/history/pause", json={"paused": False})
    assert _paused(postgres_url, me) is True, "cannot remove another user's pause"


@pytest.mark.parametrize(
    "body", [{}, {"paused": "yes"}, {"paused": 1}, {"paused": True, "hours": 99}]
)
def test_bad_pause_is_refused(client: TestClient, body: dict[str, Any]) -> None:
    assert client.post("/v1/history/pause", json=body).status_code == 422
    assert client.get("/v1/history/pause").json() == {"paused": False, "until": None}


def test_log_has_no_names_or_ids(
    client: TestClient, caplog: pytest.LogCaptureFixture
) -> None:
    _listen(client, FIRST_ID, SECOND_ID)
    rows = _history(client)
    caplog.clear()
    caplog.set_level(logging.DEBUG)
    _remove(client, rows[0])
    client.post("/v1/history/pause", json={"paused": True})
    client.get("/v1/history/pause")
    client.post("/v1/history/clear")
    text = "\n".join(r.getMessage() for r in caplog.records)
    for secret in (
        "Paper Lanterns",
        "Northern Wire",
        "Glass Harbor",
        FIRST_ID,
        SECOND_ID,
    ):
        assert secret not in text, secret


def test_no_database_is_503() -> None:
    client = TestClient(_app(None))
    for r in (
        client.post(
            "/v1/history/remove",
            json={"track_id": FIRST_ID, "played_at": "2026-10-06T12:00:00+00:00"},
        ),
        client.post("/v1/history/clear"),
        client.post("/v1/history/pause", json={"paused": True}),
        client.get("/v1/history/pause"),
    ):
        assert r.status_code == 503
        assert r.json() == {"status": "library_unavailable"}


@pytest.mark.real_auth
def test_without_login_refused(postgres_url: str) -> None:
    client = TestClient(_app(postgres_url))
    assert client.post("/v1/history/clear").status_code == 401
    assert client.get("/v1/history/pause").status_code == 401
    assert client.post("/v1/history/pause", json={"paused": True}).status_code == 401
