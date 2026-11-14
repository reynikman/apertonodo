"""Loudness is connected to Play (wiring 12, FT-635, D2).

Server measured loudness only in its own tests: nobody called `measure_pending`,
and `audio.gain_db` was not sent in response. Now a background pass every minute measures
files of playing tracks, and Play and status response takes adjustment from memory.

What the check does not prove: that ffmpeg on prod measures in seconds and that
the phone lowers the volume — measurement here is fake, the app is probe P8a.
"""

from __future__ import annotations

import asyncio
import secrets
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from fastapi.testclient import TestClient

from app.main import create_app
from app.store import token_hash


def _session(app: Any, path: Path) -> str:
    token = secrets.token_urlsafe(24)
    app.state.sessions[token_hash(token)] = {
        "state": "resolved",
        "track": {"id": "t", "artist": "A", "title": "B"},
        "buffered_ms": 0,
        "media_path": str(path),
        "expires_at": datetime.now(timezone.utc) + timedelta(minutes=10),
        "user_id": None,
    }
    return token


def test_pass_measures_playing_file_and_status_gives_gain(
    tmp_path: Path, postgres_url: str
) -> None:
    song = tmp_path / "01 - Song.flac"
    song.write_bytes(b"fLaC" + b"\0" * 64)
    measured: list[Path] = []

    def measure(path: Path) -> float:
        measured.append(path)
        return -10.0

    app = create_app(catalog=[], database_url=postgres_url)
    with TestClient(app) as client:
        token = _session(app, song)
        before = client.get(f"/v1/playback/{token}/status").json()
        assert before["audio"] == {"format": "flac"}, "no adjustment before measurement"

        asyncio.run(app.state.loudness_pass(measure=measure))
        after = client.get(f"/v1/playback/{token}/status").json()
        assert after["audio"] == {"format": "flac", "gain_db": -8.0}

        asyncio.run(app.state.loudness_pass(measure=measure))
        task = app.state.loudness_task
        assert task is not None and not task.done(), "pass runs in background while server lives"
    assert task.done(), "pass stopped when server stops"
    assert measured == [song], "already measured file is not measured twice"
    assert "Song" not in str(after), "filename does not leak outside"


def test_without_database_nothing_is_measured(tmp_path: Path) -> None:
    song = tmp_path / "01.mp3"
    song.write_bytes(b"ID3" + b"\0" * 64)
    app = create_app(catalog=[])

    def measure(path: Path) -> float:
        raise AssertionError("без базы замера нет")

    with TestClient(app):
        _session(app, song)
        asyncio.run(app.state.loudness_pass(measure=measure))
    assert app.state.gains == {}
