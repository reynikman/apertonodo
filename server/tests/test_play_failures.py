"""List of failures during beta period (FT-520, Р-A55).

Owner 02.10.2026: "I listened to music and ran into errors... it was yesterday, I don't
remember all the songs anymore". The server log intentionally does not carry titles
(`test_privacy.py`), and from `playback N: no candidate above threshold` line
one cannot know which song was silent. Therefore every failure is recorded as a row
in the database — in the same place as playback history: who, when, which song or
artist, at which step, and the playback sequence number from the log. Titles
still do not enter the log.
"""

from __future__ import annotations

import asyncio
import os
import subprocess
import time
import sys
import uuid
from pathlib import Path
from typing import Any

import asyncpg
from fake_extension import AUDIO, make_fake_extension, running_extension
from fastapi import FastAPI, Request
from fastapi.responses import Response, StreamingResponse
from fastapi.testclient import TestClient
from test_catalog_browse import (  # noqa: F401 — catalog fixtures
    FakeMusicBrainz,
    _answer,
    built,
    db,
)
from test_catalog_browse import _app as _catalog_app

from app.main import create_app
from app.migrate import apply
from app.store import persist_tracks

SERVER = Path(__file__).resolve().parent.parent


def _track(title: str = "Duality") -> dict[str, Any]:
    return {
        "id": str(uuid.uuid4()),
        "title": title,
        "artist": "Slipknot",
        "duration_ms": 1,
        "artwork_url": "",
    }


def _prepare(url: str, track: dict[str, Any]) -> None:
    async def run() -> None:
        await apply(url)
        await persist_tracks(url, [track])

    asyncio.run(run())


def _rows(url: str, sql: str, *args: Any) -> list[dict[str, Any]]:
    async def run() -> list[dict[str, Any]]:
        conn = await asyncpg.connect(url)
        try:
            return [dict(row) for row in await conn.fetch(sql, *args)]
        finally:
            await conn.close()

    return asyncio.run(run())


def _failures(url: str, track: dict[str, Any]) -> list[dict[str, Any]]:
    return _rows(
        url,
        "SELECT kind, user_id::text AS user_id, track_id, artist, title, ref "
        "FROM play_failures WHERE track_id = $1 ORDER BY id",
        track["id"],
    )


def _play(url: str, track: dict[str, Any], extensions: dict[str, str]):
    app = create_app(
        database_url=url,
        catalog=[track],
        extensions=extensions,
        playback_budget_s=5.0,
    )
    return TestClient(app)


def _number(caplog, prefix: str) -> str:
    """Playback or stream number from log: `playback 1a2b3c: start` → `1a2b3c`."""
    for record in caplog.records:
        line = record.getMessage()
        if line.startswith(prefix + " "):
            return line.split()[1].rstrip(":")
    raise AssertionError(f"no line {prefix} in log")


def _no_names_in_log(caplog) -> None:
    for record in caplog.records:
        line = record.getMessage()
        for word in ("Duality", "Wait and Bleed", "Slipknot", "Nobody Here"):
            assert word not in line, f"title in log: {line}"


def _stalling_extension() -> FastAPI:
    """Extension that serves a kilobyte and stalls: stream hangs midway through song."""
    audio = (AUDIO / "tone-440hz-4s.mp3").read_bytes()
    app = FastAPI()

    @app.get("/v1/info")
    def info() -> dict[str, Any]:
        return {"api": 1, "name": "stall", "version": "0.1.0", "kind": "music", "features": []}

    @app.get("/v1/health")
    def health() -> dict[str, Any]:
        return {"ok": True}

    @app.post("/v1/find")
    def find() -> dict[str, Any]:
        return {"items": [{"id": "one", "confidence": 0.9, "format": "mp3", "size": len(audio), "quality": "lossy"}]}

    @app.post("/v1/prepare")
    def prepare() -> dict[str, Any]:
        return {"state": "ready", "format": "mp3", "size": len(audio)}

    @app.get("/v1/files/{file_id}")
    def files(file_id: str, request: Request) -> Response:
        def chunks() -> Any:
            yield audio[:1024]
            time.sleep(3)
            yield audio[1024:]

        return StreamingResponse(chunks(), media_type="audio/mpeg")

    return app


def test_no_source_is_noted_with_the_song_and_who(
    tmp_path: Path, postgres_url: str, test_principal, caplog
) -> None:
    track = _track()
    _prepare(postgres_url, track)
    with _play(postgres_url, track, {}) as client:
        response = client.post("/v1/playback", json={"track_id": track["id"]})
    assert response.status_code == 409, response.text

    play = _number(caplog, "playback")
    assert _failures(postgres_url, track) == [
        {
            "kind": "no_source",
            "user_id": test_principal["id"],
            "track_id": track["id"],
            "artist": "Slipknot",
            "title": "Duality",
            "ref": f"playback {play}",
        }
    ]
    _no_names_in_log(caplog)


def test_source_that_gave_nothing_is_noted_as_unresolved(
    tmp_path: Path, postgres_url: str, caplog
) -> None:
    # Extension only has "Duality": confidence for this song is below threshold.
    track = _track("Wait and Bleed")
    _prepare(postgres_url, track)
    with running_extension(make_fake_extension()) as ext:
        with _play(postgres_url, track, {"fake": ext}) as client:
            response = client.post("/v1/playback", json={"track_id": track["id"]})
    assert response.status_code == 409, response.text

    rows = _failures(postgres_url, track)
    assert [row["title"] for row in rows] == ["Wait and Bleed"]
    assert rows[0]["kind"] in ("unresolved", "no_source")
    assert rows[0]["ref"] == f"playback {_number(caplog, 'playback')}"
    _no_names_in_log(caplog)


def test_stalled_stream_is_noted_with_the_stream_number(
    tmp_path: Path, postgres_url: str, test_principal, caplog, monkeypatch
) -> None:
    import app.extensions as extensions

    monkeypatch.setattr(extensions, "STREAM_READ_S", 0.5)
    track = _track()
    _prepare(postgres_url, track)
    with running_extension(_stalling_extension()) as ext:
        with _play(postgres_url, track, {"stall": ext}) as client:
            response = client.post("/v1/playback", json={"track_id": track["id"]})
            assert response.status_code == 200, response.text
            try:
                client.get(f"/v1/stream/{response.json()['token']}")
            except Exception:  # noqa: BLE001 — disconnect midway through body is seen by client as exception
                pass
            time.sleep(0.5)

    rows = _failures(postgres_url, track)
    assert [(row["kind"], row["artist"], row["title"]) for row in rows] == [
        ("stream_stalled", "Slipknot", "Duality")
    ]
    assert rows[0]["user_id"] == test_principal["id"]
    assert rows[0]["ref"] == f"stream {_number(caplog, 'stream')}"
    _no_names_in_log(caplog)


def test_a_song_that_played_leaves_nothing(tmp_path: Path, postgres_url: str) -> None:
    track = _track()
    _prepare(postgres_url, track)
    with running_extension(make_fake_extension()) as ext:
        with _play(postgres_url, track, {"fake": ext}) as client:
            response = client.post("/v1/playback", json={"track_id": track["id"]})
            assert response.status_code == 200, response.text
            assert client.get(f"/v1/stream/{response.json()['token']}").status_code in (200, 206)
    assert _failures(postgres_url, track) == []


def test_missing_artist_page_is_noted(built: str, test_principal, caplog) -> None:  # noqa: F811
    # Distinct name for each run: neighboring test_catalog_browse also queries
    # "Nobody Here", and its row lives in the same database.
    name = f"Nobody Here {uuid.uuid4().hex[:8]}"
    mb = FakeMusicBrainz()
    with TestClient(_catalog_app(built, mb)) as client:
        mb.get_json = _answer({"artists": []}, mb)  # type: ignore[method-assign]
        assert client.get("/v1/artist", params={"name": name}).status_code == 404
    rows = _rows(
        built,
        "SELECT kind, user_id::text AS user_id, artist, title FROM play_failures "
        "WHERE kind = 'artist_not_found' AND artist = $1",
        name,
    )
    assert rows == [
        {"kind": "artist_not_found", "user_id": test_principal["id"], "artist": name, "title": ""}
    ]
    _no_names_in_log(caplog)


def test_note_that_failed_does_not_change_the_answer(
    tmp_path: Path, postgres_url: str, caplog
) -> None:
    """List is for triage, not for operation: without the table Play answers as before."""
    track = _track()
    _prepare(postgres_url, track)

    async def rename(old: str, new: str) -> None:
        conn = await asyncpg.connect(postgres_url)
        try:
            await conn.execute(f"ALTER TABLE {old} RENAME TO {new}")
        finally:
            await conn.close()

    asyncio.run(rename("play_failures", "play_failures_away"))
    try:
        with _play(postgres_url, track, {}) as client:
            response = client.post("/v1/playback", json={"track_id": track["id"]})
    finally:
        asyncio.run(rename("play_failures_away", "play_failures"))
    assert response.status_code == 409, response.text
    assert response.json() == {"state": "unresolved"}
    lines = [record.getMessage() for record in caplog.records]
    assert any(line.startswith("failure note failed: ") for line in lines), lines
    _no_names_in_log(caplog)


def test_list_command_shows_songs(tmp_path: Path, postgres_url: str, caplog) -> None:
    """`python -m app.failures` — how lead answers "check my errors"."""
    track = _track()
    _prepare(postgres_url, track)
    with _play(postgres_url, track, {}) as client:
        client.post("/v1/playback", json={"track_id": track["id"]})
    play = _number(caplog, "playback")

    result = subprocess.run(
        [sys.executable, "-m", "app.failures", "--days", "1"],
        cwd=SERVER,
        env={**os.environ, "DATABASE_URL": postgres_url},
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert result.returncode == 0, result.stderr
    line = next((row for row in result.stdout.splitlines() if play in row), "")
    assert "no_source" in line, result.stdout
    assert "Slipknot — Duality" in line, result.stdout

