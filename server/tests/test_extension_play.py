"""FT-589: core plays through extension per `contracts/extension-api.md`.

Core with `extensions={"fake": url}` (in production — `EXTENSIONS="fake=http://…"`) queries the extension
"what is available for this song", prepares the best candidate, and returns to the phone the same `{token, state, track}` as
today. The `/v1/stream/{token}` stream passes through from the extension's `GET /v1/files/{id}` with Range — core does not
buffer bytes, otherwise time-to-audio will increase. Phone complaints reach the extension's `POST /v1/failed`.

The extension here is real HTTP (`fake_extension.py`, FT-587), not a mocked function: core connects to it over
the network, just like in compose. Legacy path (resolver, rqbit) in these tests is empty — only the extension can play.

What tests do not prove: that BitTorrent extension (FT-592) and phone (device-smoke) play identically, and
production time-to-audio (`ttfa_cold.sh`).
"""

from __future__ import annotations

import json
import logging
import time
import urllib.request
import uuid
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import httpx
from fake_extension import AUDIO, make_fake_extension, running_extension
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response, StreamingResponse
from fastapi.testclient import TestClient

from app.main import create_app

DUALITY = AUDIO / "tone-440hz-4s.mp3"
SONG = {"id": str(uuid.uuid4()), "title": "Duality", "artist": "Slipknot", "duration_ms": 1, "artwork_url": ""}
# Fake extension only has "Slipknot - Duality": confidence for this song is 1/4 — below 0.75.
WEAK = {"id": str(uuid.uuid4()), "title": "Wait and Bleed", "artist": "Slipknot", "duration_ms": 1, "artwork_url": ""}
DEAD = "http://127.0.0.1:9"


def _app(extensions: dict[str, str], tmp_path: Path) -> Any:
    return create_app(
        catalog=[SONG, WEAK],
        extensions=extensions,
    )


def _find(url: str, track: dict[str, Any]) -> list[dict[str, Any]]:
    body = json.dumps({"track": {"artist": track["artist"], "title": track["title"]}, "limit": 4}).encode()
    request = urllib.request.Request(url + "/v1/find", data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=10) as response:
        return json.loads(response.read())["items"]


def test_play_and_stream_through_extension(tmp_path: Path, caplog) -> None:
    audio = DUALITY.read_bytes()
    with running_extension(make_fake_extension()) as url, TestClient(_app({"fake": url}, tmp_path)) as client:
        file_id = _find(url, SONG)[0]["id"]
        with caplog.at_level(logging.INFO, logger="apertonodo"):
            played = client.post("/v1/playback", json={"track_id": SONG["id"]})
            assert played.status_code == 200, played.text
            token = played.json()["token"]
            part = client.get(f"/v1/stream/{token}", headers={"Range": "bytes=0-1023"})
            tail = client.get(f"/v1/stream/{token}", headers={"Range": "bytes=1024-"})
            whole = client.get(f"/v1/stream/{token}")

    # FT-840: формат называет расширение в ответе `ready` — значок в плеере рисуется по нему.
    assert set(played.json()) == {"token", "state", "track", "audio"}, played.json()
    assert played.json()["audio"] == {"format": "mp3"}
    assert played.json()["track"]["id"] == SONG["id"]
    for leak in (file_id, "fake:", url):
        assert leak not in played.text, f"Play response leaked {leak}"
    assert part.status_code == 206, part.text
    assert part.headers["content-range"] == f"bytes 0-1023/{len(audio)}"
    assert part.content == audio[:1024]
    assert part.headers["content-type"].startswith("audio/")
    assert tail.status_code == 206 and tail.content == audio[1024:]
    assert whole.status_code == 200 and whole.content == audio
    for word in ("Duality", "Slipknot", token, file_id):
        assert word not in caplog.text, f"logged {word}"


def test_low_confidence_gets_no_token(tmp_path: Path) -> None:
    with running_extension(make_fake_extension()) as url, TestClient(_app({"fake": url}, tmp_path)) as client:
        assert all(item["confidence"] < 0.75 for item in _find(url, WEAK))
        played = client.post("/v1/playback", json={"track_id": WEAK["id"]})
    assert played.status_code == 409, played.text
    assert "token" not in played.json()


def test_dead_extension_is_skipped(tmp_path: Path) -> None:
    with running_extension(make_fake_extension()) as url:
        with TestClient(_app({"down": DEAD, "fake": url}, tmp_path)) as client:
            started = time.monotonic()
            played = client.post("/v1/playback", json={"track_id": SONG["id"]})
            took = time.monotonic() - started
            search = client.get("/v1/search", params={"q": "Duality"})
    assert played.status_code == 200, played.text
    assert took < 5, f"dead extension delayed Play by {took:.1f} s"
    assert search.status_code == 200, search.text


def test_only_dead_extension_answers_unresolved(tmp_path: Path) -> None:
    with TestClient(_app({"down": DEAD}, tmp_path)) as client:
        played = client.post("/v1/playback", json={"track_id": SONG["id"]})
    assert played.status_code == 409, played.text


def test_phone_complaint_reaches_extension(tmp_path: Path) -> None:
    with running_extension(make_fake_extension()) as url, TestClient(_app({"fake": url}, tmp_path)) as client:
        before = _find(url, SONG)[0]
        token = client.post("/v1/playback", json={"track_id": SONG["id"]}).json()["token"]
        reported = client.post("/v1/playback/failed", json={"token": token})
        after = _find(url, SONG)[0]
        again = client.post("/v1/playback", json={"track_id": SONG["id"]})
    assert reported.status_code == 204, reported.text
    assert after["id"] == before["id"] and after["confidence"] < before["confidence"], "complaint did not reach extension"
    # Sole file after complaint is below threshold — replay honestly refuses to play it again.
    assert again.status_code == 409, again.text


def _slow_extension(audio: bytes, pause_s: float) -> FastAPI:
    """Extension that yields the first kilobyte immediately, and the rest after `pause_s`: download in progress."""
    app = FastAPI()

    @app.get("/v1/info")
    def info() -> dict[str, Any]:
        return {"api": 1, "name": "slow", "version": "0.1.0", "kind": "music", "features": []}

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
        if file_id != "one":
            return JSONResponse({"error": "unknown_id"}, status_code=404)

        def chunks() -> Iterator[bytes]:
            yield audio[:1024]
            time.sleep(pause_s)
            yield audio[1024:]

        return StreamingResponse(chunks(), media_type="audio/mpeg", headers={"Accept-Ranges": "bytes"})

    return app


def test_stream_passes_through_without_waiting_for_whole_file(tmp_path: Path) -> None:
    audio = DUALITY.read_bytes()
    pause = 3.0
    first: dict[str, float] = {}
    with running_extension(_slow_extension(audio, pause)) as url:
        with running_extension(_app({"slow": url}, tmp_path)) as core:
            token = httpx.post(core + "/v1/playback", json={"track_id": SONG["id"]}, timeout=30).json()["token"]
            started = time.monotonic()
            got = b""
            with httpx.stream("GET", f"{core}/v1/stream/{token}", timeout=30) as response:
                for chunk in response.iter_bytes():
                    if not first and chunk:
                        first["s"] = time.monotonic() - started
                    got += chunk
            total = time.monotonic() - started
    assert got == audio
    assert total >= pause, "extension did not hold pause — test verified nothing"
    assert first["s"] < pause / 2, f"first bytes arrived in {first['s']:.1f} s: core buffers the file instead of streaming"


def test_extensions_from_environment() -> None:
    from app.extensions import parse_extensions

    assert parse_extensions("") == {}
    assert parse_extensions("folder=http://folder:8080, bt=http://bt:8080") == {
        "folder": "http://folder:8080",
        "bt": "http://bt:8080",
    }
    for bad in ("Folder=http://x", "folder", "a:b=http://x", "folder=http://a,folder=http://b"):
        try:
            parse_extensions(bad)
        except ValueError:
            continue
        raise AssertionError(f"invalid EXTENSIONS accepted: {bad!r}")


def test_extension_client_has_no_source_words() -> None:
    text = (Path(__file__).resolve().parents[1] / "app" / "extensions.py").read_text(encoding="utf-8").casefold()
    for word in ("magnet", "torrent", "tracker", "info_hash", "infohash", "rqbit"):
        assert word not in text, f"source word «{word}» found in extension client"

