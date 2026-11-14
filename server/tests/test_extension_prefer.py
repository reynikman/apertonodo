"""FT-806: "Lossless only" reaches file selection on the extension path as well.

On the legacy path, core prioritized lossless files (`prefer_order`, FT-633). The extension path
(`_select_extension`) was unaware of `prefer` and picked the most confident candidate — after flag
day, lossless mode would have silently stopped working. The extension provides `quality`
for each file (`contracts/extension-api.md`): core orders by it accordingly.

The extension here is a small real HTTP server: it tracks which file IDs core requested to prepare.

What tests do not prove: that real extensions honestly report `quality` for live files.
"""

from __future__ import annotations

import uuid
from typing import Any

from fake_extension import running_extension
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from fastapi.testclient import TestClient

from app.main import create_app

SONG = {"id": str(uuid.uuid4()), "title": "Duality", "artist": "Slipknot", "duration_ms": 1, "artwork_url": ""}

MP3 = {"id": "mp3", "confidence": 0.97, "format": "mp3", "size": 5_000_000, "quality": "lossy"}
VINYL = {"id": "vinyl", "confidence": 0.95, "format": "flac", "size": 40_000_000, "quality": "analog"}
FLAC = {"id": "flac", "confidence": 0.90, "format": "flac", "size": 30_000_000, "quality": "lossless"}
HIRES = {"id": "hires", "confidence": 0.85, "format": "flac", "size": 90_000_000, "quality": "hires"}
WEAK_FLAC = {"id": "weak", "confidence": 0.40, "format": "flac", "size": 30_000_000, "quality": "lossless"}


def _extension(items: list[dict[str, Any]], broken: set[str] | None = None) -> tuple[FastAPI, list[str]]:
    app = FastAPI()
    prepared: list[str] = []

    @app.get("/v1/info")
    def info() -> dict[str, Any]:
        return {"api": 1, "name": "q", "version": "0.1.0", "kind": "music", "features": []}

    @app.post("/v1/find")
    def find() -> dict[str, Any]:
        return {"items": items}

    @app.post("/v1/prepare")
    async def prepare(request: Request) -> JSONResponse:
        file_id = (await request.json())["id"]
        prepared.append(file_id)
        if broken and file_id in broken:
            return JSONResponse({"error": "unavailable"}, status_code=503)
        fmt = next(item["format"] for item in items if item["id"] == file_id)
        return JSONResponse({"state": "ready", "format": fmt, "size": 1})

    return app, prepared


def _play(items: list[dict[str, Any]], prefer: str | None, broken: set[str] | None = None) -> tuple[int, list[str]]:
    app, prepared = _extension(items, broken)
    with running_extension(app) as url, TestClient(create_app(catalog=[SONG], extensions={"q": url})) as client:
        body: dict[str, Any] = {"track_id": SONG["id"]}
        if prefer is not None:
            body["prefer"] = prefer
        answer = client.post("/v1/playback", json=body)
    return answer.status_code, prepared


def test_without_mode_the_most_confident_file_plays() -> None:
    status, prepared = _play([FLAC, MP3], None)
    assert status == 200
    assert prepared == ["mp3"]


def test_lossless_mode_takes_the_lossless_file_first() -> None:
    status, prepared = _play([MP3, FLAC], "lossless")
    assert status == 200
    assert prepared == ["flac"]


def test_hires_counts_as_lossless_and_confidence_orders_inside_the_group() -> None:
    status, prepared = _play([MP3, HIRES, FLAC], "lossless")
    assert status == 200
    assert prepared == ["flac"]


def test_vinyl_rip_is_not_promoted() -> None:
    """Vinyl rip is FLAC format-wise, but not "lossless" sound-wise (as in `prefer_order`)."""
    status, prepared = _play([MP3, VINYL], "lossless")
    assert status == 200
    assert prepared == ["mp3"]


def test_unsure_lossless_never_beats_a_confident_file() -> None:
    """Quality mode is no excuse to play the wrong song: confidence threshold takes priority."""
    status, prepared = _play([MP3, WEAK_FLAC], "lossless")
    assert status == 200
    assert prepared == ["mp3"]


def test_lossless_mode_still_plays_when_there_is_no_lossless() -> None:
    status, prepared = _play([MP3], "lossless")
    assert status == 200
    assert prepared == ["mp3"]


def test_broken_lossless_falls_back_to_the_next_file() -> None:
    status, prepared = _play([MP3, FLAC], "lossless", broken={"flac"})
    assert status == 200
    assert prepared == ["flac", "mp3"]


def test_opus_mode_does_not_reorder_files() -> None:
    status, prepared = _play([FLAC, MP3], "opus")
    assert status == 200
    assert prepared == ["mp3"]
