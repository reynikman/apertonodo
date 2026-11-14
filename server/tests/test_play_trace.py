"""Each Play press leaves a step trace in the log — without the song title.

Why. On September 18 the owner pressed Play on "Enter Sandman" by Apocalyptica,
received "Failed — retry" after 27 seconds, while the server log had a single line
`candidate metadata did not arrive`: which candidate, how long it waited, how many there
were in total — not visible. From such a log the cause had to be guessed.

Now a press has a short random ID, and each line tells which
step took how long and how it ended. Stream logs how response ended: whether
the audio completed, whether phone disconnected or release stalled.

What must NOT be in the log and what is guarded here: query text, song
title, artist and file names (file names the song) and the token itself.
"""

from __future__ import annotations

import logging
import re
from pathlib import Path

from typing import Any

import pytest
from fake_extension import running_extension
from fastapi import FastAPI
from fastapi.testclient import TestClient
from test_extension_asset import Disk, _tone

from app.main import create_app
from app.store import token_hash

TRACK = {
    "id": "5e1f0000-0000-4000-8000-000000000002",
    "title": "Tajnaya Pesnya",
    "artist": "Sekretny Artist",
    "duration_ms": 1,
    "artwork_url": "",
}
SECRETS = ("Tajnaya", "Pesnya", "Sekretny", "tajnaya", "pesnya", "sekretny", "Album")


def _lines(caplog: pytest.LogCaptureFixture) -> list[str]:
    return [
        record.getMessage()
        for record in caplog.records
        if record.name == "apertonodo"
    ]


def test_play_leaves_a_step_trail_without_the_song(
    caplog: pytest.LogCaptureFixture, tmp_path: Path
) -> None:
    disk = Disk(_tone(tmp_path / "music" / "01.flac", TRACK))
    with caplog.at_level(logging.INFO, logger="apertonodo"), running_extension(disk.app()) as url:
        app = create_app(catalog=[TRACK], extensions={"disk": url}, variant_dir=tmp_path / "variants")
        with TestClient(app) as client:
            played = client.post("/v1/playback", json={"track_id": TRACK["id"]})
            assert played.status_code == 200, played.text
            token = played.json()["token"]
            streamed = client.get(f"/v1/stream/{token}")
            assert streamed.status_code == 200

    lines = _lines(caplog)
    play = [line for line in lines if line.startswith("playback ")]
    ids = {line.split()[1].rstrip(":") for line in play}
    assert len(ids) == 1, f"lines of single press have different IDs: {play}"
    joined = "\n".join(play)
    sid = token_hash(token)[:8]
    assert re.search(rf"token after \d+ ms, stream {sid}$", joined, re.M), joined

    assert any(line.startswith(f"stream {sid}: open GET range=-") for line in lines), lines
    assert any(
        re.match(rf"stream {sid}: complete after \d+ bytes, \d+ ms", line) for line in lines
    ), lines

    everything = "\n".join(lines)
    for secret in SECRETS:
        assert secret not in everything, f"leaked into log '{secret}'"
    assert token not in everything, "token itself leaked into log"


def test_unresolved_play_without_extensions_says_so(caplog: pytest.LogCaptureFixture) -> None:
    """Without extensions there is nothing to play: former honest refusal, with its trace in log."""
    app = create_app(catalog=[TRACK])
    with caplog.at_level(logging.INFO, logger="apertonodo"), TestClient(app) as client:
        response = client.post("/v1/playback", json={"track_id": TRACK["id"]})

    assert response.status_code == 409
    joined = "\n".join(_lines(caplog))
    assert re.search(r"playback \w+: no extensions", joined), joined
    for secret in SECRETS:
        assert secret not in joined, f"leaked into log '{secret}'"


def test_unresolved_play_says_why_when_the_extension_has_nothing(
    caplog: pytest.LogCaptureFixture,
) -> None:
    empty = FastAPI()

    @empty.get("/v1/info")
    def info() -> dict[str, Any]:
        return {"api": 1, "name": "empty", "version": "0", "kind": "music", "features": []}

    @empty.post("/v1/find")
    def find() -> dict[str, Any]:
        return {"items": []}

    with caplog.at_level(logging.INFO, logger="apertonodo"), running_extension(empty) as url:
        with TestClient(create_app(catalog=[TRACK], extensions={"empty": url})) as client:
            response = client.post("/v1/playback", json={"track_id": TRACK["id"]})

    assert response.status_code == 409
    joined = "\n".join(_lines(caplog))
    assert re.search(r"playback \w+: extensions: 1 answered, 0 above threshold, \d+ ms", joined), joined
    assert re.search(r"playback \w+: no candidate above threshold", joined), joined
    for secret in SECRETS:
        assert secret not in joined, f"leaked into log '{secret}'"
