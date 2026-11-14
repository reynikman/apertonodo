"""FT-622 (Р-A87, beta requirement): "Report a problem" — reception on own Apertonodo.

A user in the app clicks "Report a problem" on a song, album, artist, playlist, or in the player, and
selects a reason. The server writes the report to its database (not to a third-party service), owner reads them as a list.

Guarded:
- reasons and places are closed lists; place has its mandatory id; "other" — only with text;
- parsing error does not echo received text (like `app_reports.py`);
- only admin sees the reports list;
- one user — at most 20 reports per hour;
- log contains only reason and place, without text, names, or ids.

What the tests do not prove: app buttons — separate card after wave A P9.
"""

from __future__ import annotations

import asyncio
import json
import logging
import secrets
import uuid
from pathlib import Path
from typing import Any

import asyncpg
import pytest
from fastapi.testclient import TestClient

from app.main import create_app
from app.migrate import apply

ROOT = Path(__file__).resolve().parents[2]
CATALOG = json.loads((ROOT / "contracts" / "fixtures" / "catalog.json").read_text())["tracks"]
TRACK = "33333333-3333-3333-3333-333333333333"
ALBUM = str(uuid.uuid4())
PLAYLIST = str(uuid.uuid4())
SECRET = "мой сосед Пётр поёт лучше"


def _reset(url: str) -> None:
    async def run() -> None:
        await apply(url)
        conn = await asyncpg.connect(url)
        try:
            await conn.execute("TRUNCATE problem_reports")
        finally:
            await conn.close()

    asyncio.run(run())


def _rows(url: str) -> list[dict[str, Any]]:
    async def run() -> list[dict[str, Any]]:
        conn = await asyncpg.connect(url)
        try:
            return [dict(r) for r in await conn.fetch("SELECT * FROM problem_reports ORDER BY id")]
        finally:
            await conn.close()

    return asyncio.run(run())


@pytest.fixture
def client(postgres_url: str) -> TestClient:
    _reset(postgres_url)
    app = create_app(
        database_url=postgres_url,
        catalog=CATALOG,
    )
    return TestClient(app)


def _report(**overrides: Any) -> dict[str, Any]:
    body: dict[str, Any] = {
        "reason": "wrong_track",
        "place": "song",
        "track_id": TRACK,
        "app_version": "0.9.0+42",
    }
    body.update(overrides)
    return {k: v for k, v in body.items() if v is not None}


def test_report_is_stored_with_who_and_where(
    client: TestClient, postgres_url: str, test_principal: dict[str, Any]
) -> None:
    r = client.post("/v1/problems", json=_report())
    assert r.status_code == 202
    assert r.json() == {"status": "accepted"}
    [row] = _rows(postgres_url)
    assert row["reason"] == "wrong_track"
    assert row["place"] == "song"
    assert str(row["track_id"]) == TRACK
    assert row["app_version"] == "0.9.0+42"
    assert str(row["user_id"]) == test_principal["id"], "owner sees who reported"
    assert row["created_at"] is not None


@pytest.mark.parametrize(
    "body",
    [
        _report(place="album", track_id=None, album_id=ALBUM, reason="cover"),
        _report(place="artist", track_id=None, artist="Glass Harbor", reason="wrong_name"),
        _report(place="playlist", track_id=None, playlist_id=PLAYLIST, reason="no_play"),
        _report(place="player", reason="bad_sound"),
        _report(reason="other", text="играет вторая половина песни дважды"),
    ],
)
def test_every_place_and_reason(client: TestClient, body: dict[str, Any]) -> None:
    assert client.post("/v1/problems", json=body).status_code == 202


@pytest.mark.parametrize(
    "body",
    [
        _report(reason="hate_it"),
        _report(place="home"),
        _report(track_id=None),
        _report(place="album", track_id=None),
        _report(place="artist", track_id=None),
        _report(place="playlist", track_id=None),
        _report(track_id="not-a-uuid"),
        _report(reason="other"),
        _report(reason="other", text="   "),
        _report(text="x" * 501),
        _report(artist="y" * 201),
        _report(app_version=None),
        _report(magnet="magnet:?xt=urn:btih:abc"),
    ],
)
def test_bad_report_is_refused(client: TestClient, postgres_url: str, body: dict[str, Any]) -> None:
    r = client.post("/v1/problems", json=body)
    assert r.status_code == 422
    assert _rows(postgres_url) == []


def test_refusal_does_not_echo_what_was_sent(client: TestClient) -> None:
    for body in (
        _report(reason="nope", text=SECRET),
        _report(text=SECRET * 30),
        _report(**{SECRET: 1}),
    ):
        r = client.post("/v1/problems", json=body)
        assert r.status_code == 422
        assert SECRET not in r.text
        assert "Пётр" not in r.text


def test_only_admin_reads_the_list(
    client: TestClient, test_principal: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    client.post("/v1/problems", json=_report())
    client.post("/v1/problems", json=_report(reason="other", text=SECRET, place="player"))

    assert client.get("/v1/problems").status_code == 403

    monkeypatch.setitem(test_principal, "is_admin", True)
    r = client.get("/v1/problems")
    assert r.status_code == 200
    items = r.json()["items"]
    assert [i["reason"] for i in items] == ["other", "wrong_track"], "newest on top"
    assert items[0]["text"] == SECRET
    assert items[1]["track_id"] == TRACK
    for key in ("id", "created_at", "place", "app_version", "user_id"):
        assert key in items[0], key

    r = client.get("/v1/problems", params={"limit": 1})
    assert len(r.json()["items"]) == 1


def test_twenty_an_hour_per_person(client: TestClient, postgres_url: str) -> None:
    for _ in range(20):
        assert client.post("/v1/problems", json=_report()).status_code == 202
    r = client.post("/v1/problems", json=_report())
    assert r.status_code == 429
    assert len(_rows(postgres_url)) == 20


def test_log_names_only_reason_and_place(
    client: TestClient, caplog: pytest.LogCaptureFixture
) -> None:
    caplog.set_level(logging.DEBUG)
    client.post(
        "/v1/problems",
        json=_report(place="artist", track_id=None, artist="Glass Harbor", reason="wrong_name"),
    )
    client.post("/v1/problems", json=_report(reason="other", text=SECRET))
    text = "\n".join(r.getMessage() for r in caplog.records)
    assert "problem wrong_name artist" in text
    assert "problem other song" in text
    for secret in ("Glass Harbor", SECRET, "Пётр", TRACK):
        assert secret not in text, secret


@pytest.mark.real_auth
def test_without_login_or_key_refused(postgres_url: str) -> None:
    app = create_app(database_url=postgres_url, catalog=CATALOG, api_key=secrets.token_urlsafe(32))
    client = TestClient(app)
    assert client.post("/v1/problems", json=_report()).status_code == 401
    assert client.get("/v1/problems").status_code == 401


def test_any_key_header_does_not_open_the_list(postgres_url: str) -> None:
    """Lead 06.10: the lock lets authenticated user in by token, ignoring the key header.

    An authenticated tester (not admin) with a made-up `x-apertonodo-key` cannot read other reports;
    with the real perimeter key — can read.
    """
    _reset(postgres_url)
    key = secrets.token_urlsafe(32)
    app = create_app(
        database_url=postgres_url,
        catalog=CATALOG,
        api_key=key,
    )
    client = TestClient(app)
    tester = {"Authorization": f"Bearer {secrets.token_urlsafe(32)}"}
    assert client.post("/v1/problems", json=_report(), headers=tester).status_code == 202
    forged = client.get("/v1/problems", headers={**tester, "x-apertonodo-key": "guess"})
    assert forged.status_code == 403
    real = client.get("/v1/problems", headers={"x-apertonodo-key": key})
    assert real.status_code == 200
    assert len(real.json()["items"]) == 1
