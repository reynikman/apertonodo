"""Blind review of wire-12 (FT-635, server-side loudness measurement and extension CI).

Verification of 8 areas:
1. Measurement does not block the event loop (runs in a thread) and closes connections.
2. File is not re-measured on subsequent passes; deduplication of session paths.
3. Incompletely written or changed file: measurement is not saved or is discarded.
4. No leakage of private fields (media_path, info_hash, file name) in status response and Play.
5. Fault tolerance (corrupted file, ffmpeg unavailable, database error): background loop does not die.
6. Clean background task shutdown on server lifespan termination.
7. Log privacy: file paths and song titles do not enter logs.
8. Passing extension test exit codes through CI and check.sh.
"""

from __future__ import annotations

import asyncio
import logging
from pathlib import Path
import secrets
from datetime import datetime, timedelta, timezone
from typing import Any

from fastapi.testclient import TestClient
import pytest

from app.main import create_app
from app.store import token_hash
from app import loudness


def _create_session(app: Any, path: Path, *, track_title: str = "Secret Song") -> str:
    token = secrets.token_urlsafe(24)
    app.state.sessions[token_hash(token)] = {
        "state": "resolved",
        "track": {"id": "t-1", "artist": "Artist", "title": track_title},
        "buffered_ms": 0,
        "media_path": str(path),
        "expires_at": datetime.now(timezone.utc) + timedelta(minutes=10),
        "user_id": None,
    }
    return token


def test_loudness_does_not_block_event_loop(tmp_path: Path, postgres_url: str) -> None:
    """Measurement runs in a thread (asyncio.to_thread) and does not freeze event loop."""
    song = tmp_path / "song.flac"
    song.write_bytes(b"fLaC" + b"\0" * 64)

    app = create_app(catalog=[], database_url=postgres_url)
    with TestClient(app):
        _create_session(app, song)

        event_loop_ticked = False

        async def ticker() -> None:
            nonlocal event_loop_ticked
            await asyncio.sleep(0.01)
            event_loop_ticked = True

        def slow_measure(path: Path) -> float:
            import time
            time.sleep(0.1)
            return -14.0

        async def run_both() -> None:
            await asyncio.gather(
                app.state.loudness_pass(measure=slow_measure),
                ticker(),
            )

        asyncio.run(run_both())
        assert event_loop_ticked, "event loop must continue working during measurement"


def test_deduplication_and_no_re_measurement(tmp_path: Path, postgres_url: str) -> None:
    """Multiple sessions with the same file are measured once; repeat pass does not measure again."""
    song = tmp_path / "shared.flac"
    song.write_bytes(b"fLaC" + b"\0" * 64)
    measured: list[Path] = []

    def measure(path: Path) -> float:
        measured.append(path)
        return -12.0

    app = create_app(catalog=[], database_url=postgres_url)
    with TestClient(app) as client:
        # Two different sessions refer to the same file
        token1 = _create_session(app, song)
        token2 = _create_session(app, song)

        asyncio.run(app.state.loudness_pass(measure=measure))
        assert measured == [song], "file from two sessions must be measured exactly once"

        # Repeat pass
        asyncio.run(app.state.loudness_pass(measure=measure))
        assert measured == [song], "repeat pass must not measure the file again"

        status1 = client.get(f"/v1/playback/{token1}/status").json()
        status2 = client.get(f"/v1/playback/{token2}/status").json()
        assert status1["audio"]["gain_db"] == -6.0
        assert status2["audio"]["gain_db"] == -6.0


def test_file_modified_after_measurement_does_not_use_stale_gain(
    tmp_path: Path, postgres_url: str
) -> None:
    """If a file was downloaded further or changed after measurement, stale gain is not returned."""
    song = tmp_path / "growing.flac"
    song.write_bytes(b"fLaC" + b"\0" * 32)
    call_count = 0

    def measure(path: Path) -> float:
        nonlocal call_count
        call_count += 1
        return -10.0 if call_count == 1 else -16.0

    app = create_app(catalog=[], database_url=postgres_url)
    with TestClient(app) as client:
        token = _create_session(app, song)
        asyncio.run(app.state.loudness_pass(measure=measure))
        assert call_count == 1

        # File changed (appended by source)
        song.write_bytes(b"fLaC" + b"\0" * 128)

        # Next measurement pass detects size/mtime change and re-measures
        asyncio.run(app.state.loudness_pass(measure=measure))
        assert call_count == 2, "modified file must be re-measured"

        status = client.get(f"/v1/playback/{token}/status").json()
        assert status["audio"]["gain_db"] == -2.0


def test_no_leak_of_file_path_info_hash_in_responses(tmp_path: Path, postgres_url: str) -> None:
    """In status and Play responses with gain_db there are no media_path, info_hash, or internal paths."""
    song = tmp_path / "confidential_file_name.flac"
    song.write_bytes(b"fLaC" + b"\0" * 64)

    app = create_app(catalog=[], database_url=postgres_url)
    with TestClient(app) as client:
        token = _create_session(app, song)
        asyncio.run(app.state.loudness_pass(measure=lambda p: -14.0))

        status_resp = client.get(f"/v1/playback/{token}/status")
        assert status_resp.status_code == 200
        status_text = status_resp.text

        assert "confidential_file_name" not in status_text
        assert "media_path" not in status_text
        assert "info_hash" not in status_text
        assert str(tmp_path) not in status_text

        status_json = status_resp.json()
        assert status_json["audio"] == {"format": "flac", "gain_db": -4.0}


def test_corrupt_file_or_unavailable_ffmpeg_does_not_crash_loop(
    tmp_path: Path, postgres_url: str
) -> None:
    """Measurement failure (corrupt file, ffmpeg missing) does not break background pass or server."""
    bad_song = tmp_path / "corrupt.flac"
    bad_song.write_bytes(b"bad_data")

    good_song = tmp_path / "good.flac"
    good_song.write_bytes(b"fLaC" + b"\0" * 64)

    def measure(path: Path) -> float:
        if path == bad_song:
            raise loudness.LoudnessFailed("corrupted audio")
        return -12.0

    app = create_app(catalog=[], database_url=postgres_url)
    with TestClient(app) as client:
        token_bad = _create_session(app, bad_song)
        token_good = _create_session(app, good_song)

        # Pass must process both files successfully without crashing
        asyncio.run(app.state.loudness_pass(measure=measure))

        bad_status = client.get(f"/v1/playback/{token_bad}/status").json()
        good_status = client.get(f"/v1/playback/{token_good}/status").json()

        # Corrupt file lacks gain_db, but format is detected
        assert bad_status["audio"] == {"format": "flac"}
        assert good_status["audio"] == {"format": "flac", "gain_db": -6.0}


def test_lifespan_clean_shutdown(tmp_path: Path, postgres_url: str) -> None:
    """On lifespan end, background measurement task is cancelled cleanly."""
    app = create_app(catalog=[], database_url=postgres_url)
    with TestClient(app):
        task = app.state.loudness_task
        assert task is not None
        assert not task.done()
    assert task.done()


def test_privacy_logs_have_no_path_or_title(
    tmp_path: Path, postgres_url: str, caplog: pytest.LogCaptureFixture
) -> None:
    """Logs during measurement and failures contain no file paths or track titles."""
    caplog.set_level(logging.DEBUG, logger="apertonodo")

    secret_name = "SuperSecretSongName123"
    song = tmp_path / f"{secret_name}.flac"
    song.write_bytes(b"fLaC" + b"\0" * 64)

    app = create_app(catalog=[], database_url=postgres_url)
    with TestClient(app):
        _create_session(app, song, track_title=secret_name)
        asyncio.run(app.state.loudness_pass(measure=lambda p: -10.0))

    all_logs = " ".join(record.getMessage() for record in caplog.records)
    assert secret_name not in all_logs
    assert str(tmp_path) not in all_logs

