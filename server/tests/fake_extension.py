"""Fake extension following contract `contracts/extension-api.md` (FT-587).

Serves files from a folder like "own folder" in miniature: file `Artist - Title.mp3` is one track.
Used by the contract check itself (`test_extension_contract.py`) and core tests (FT-589). `broken` breaks
exactly one contract rule — proving that `scripts/extension_check.py` catches this rule.
"""

from __future__ import annotations

import hashlib
import json
import re
import socket
import threading
import time
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import Any

import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response, StreamingResponse
from pydantic import BaseModel, Field

AUDIO = Path(__file__).resolve().parents[2] / "contracts" / "fixtures" / "audio"
# The tone files are named by what they are; the song they stand for is test data.
SONG_OF = {
    "tone-220hz-90s.mp3": ("Metallica", "Nothing Else Matters"),
    "tone-440hz-4s.mp3": ("Slipknot", "Duality"),
}


def _song(path: Path) -> tuple[str, str]:
    if path.name in SONG_OF:
        return SONG_OF[path.name]
    artist, _, title = path.stem.partition(" - ")
    return artist, title


BROKEN = (
    "no_range",
    "unknown_is_found",
    "unsorted",
    "failed_ignored",
    "bad_id",
    "wrong_bytes",
    "bad_genre",
    "has_says_yes",
    "has_short",
    "has_no_limit",
    "has_misses_own",
    "has_list",
    "has_sorted",
    "genre_case",
)


class Track(BaseModel):
    artist: str
    title: str
    id: str | None = None
    album: str | None = None
    duration_ms: int | None = None
    recording_mbid: str | None = None


class FindBody(BaseModel):
    track: Track
    limit: int = Field(default=4, ge=1, le=10)


class IdBody(BaseModel):
    id: str


class FailedBody(BaseModel):
    id: str
    reason: str


class Pair(BaseModel):
    artist: str
    title: str


class HasBody(BaseModel):
    pairs: list[Pair]


class PinBody(BaseModel):
    id: str
    pinned: bool


def _words(text: str) -> set[str]:
    return set(re.findall(r"\w+", text.casefold()))


def make_fake_extension(audio: Path = AUDIO, broken: str | None = None) -> FastAPI:
    assert broken in (None, *BROKEN), broken
    files: dict[str, Path] = {}
    for path in sorted(audio.glob("*.mp3")):
        files[hashlib.sha1(path.name.encode()).hexdigest()[:16]] = path
    failed: set[str] = set()
    pins: set[str] = set()
    app = FastAPI()
    app.state.pins = pins

    def score(track: Track, path: Path) -> float:
        artist, title = _song(path)
        want = _words(track.artist) | _words(track.title)
        have = _words(artist) | _words(title)
        return round(len(want & have) / len(want), 3) if want else 0.0

    @app.get("/v1/info")
    def info() -> dict[str, Any]:
        return {"api": 1, "name": "fake", "version": "0.1.0", "kind": "music", "features": ["catalog", "has", "pins"]}

    @app.get("/v1/health")
    def health() -> dict[str, Any]:
        return {"ok": True}

    @app.post("/v1/find")
    def find(body: FindBody) -> dict[str, Any]:
        items = []
        for file_id, path in files.items():
            confidence = score(body.track, path)
            if confidence <= 0:
                continue
            if file_id in failed and broken != "failed_ignored":
                confidence = round(confidence / 2, 3)
            shown = f"bad:{file_id}" if broken == "bad_id" else file_id
            items.append(
                {"id": shown, "confidence": confidence, "format": "mp3", "size": path.stat().st_size, "quality": "lossy"}
            )
        if broken == "unknown_is_found":
            items.append({"id": "anything", "confidence": 0.99, "format": "mp3", "size": None, "quality": "lossy"})
        items.sort(key=lambda item: item["confidence"], reverse=broken != "unsorted")
        if broken == "unsorted" and len(items) < 2:
            items.append({"id": "zz-low", "confidence": 0.01, "format": "mp3", "size": None, "quality": "lossy"})
            items.reverse()
        return {"items": items[: body.limit]}

    @app.post("/v1/prepare")
    def prepare(body: IdBody) -> Response:
        path = files.get(body.id)
        if path is None:
            if broken == "unknown_is_found":
                return JSONResponse({"state": "ready", "format": "mp3", "size": None})
            return JSONResponse({"error": "unknown_id"}, status_code=404)
        return JSONResponse({"state": "ready", "format": "mp3", "size": path.stat().st_size})

    @app.get("/v1/files/{file_id}")
    def file(file_id: str, request: Request) -> Response:
        path = files.get(file_id)
        if path is None:
            if broken == "unknown_is_found":
                return Response(b"\0" * 16, media_type="audio/mpeg")
            return JSONResponse({"error": "unknown_id"}, status_code=404)
        data = path.read_bytes()
        if broken == "wrong_bytes":
            data = bytes(reversed(data))
        size = len(data)
        header = request.headers.get("range")
        if header is None or broken == "no_range":
            return Response(data, media_type="audio/mpeg", headers={"Accept-Ranges": "bytes"})
        match = re.fullmatch(r"bytes=(\d+)-(\d*)", header.strip())
        if match is None:
            return JSONResponse({"error": "bad_request"}, status_code=400)
        start = int(match.group(1))
        end = int(match.group(2)) if match.group(2) else size - 1
        if start >= size:
            return Response(status_code=416, headers={"Content-Range": f"bytes */{size}"})
        end = min(end, size - 1)

        def chunks() -> Iterator[bytes]:
            yield data[start : end + 1]

        return StreamingResponse(
            chunks(),
            status_code=206,
            media_type="audio/mpeg",
            headers={
                "Accept-Ranges": "bytes",
                "Content-Range": f"bytes {start}-{end}/{size}",
                "Content-Length": str(end - start + 1),
            },
        )

    @app.post("/v1/failed", status_code=204)
    def report_failed(body: FailedBody) -> Response:
        failed.add(body.id)
        return Response(status_code=204)

    @app.post("/v1/pins", status_code=204)
    def pin(body: PinBody) -> Response:
        (pins.add if body.pinned else pins.discard)(body.id)
        return Response(status_code=204)

    @app.get("/v1/catalog")
    def catalog() -> Response:
        lines = []
        for path in files.values():
            artist, title = _song(path)
            line: dict[str, Any] = {"artist": artist, "title": title, "popularity": 1}
            if artist == "Slipknot":
                line["genre"] = {"bad_genre": "nu-rock", "genre_case": "Heavy-Metal"}.get(broken or "", "heavy-metal")
            lines.append(json.dumps(line, ensure_ascii=False))
        return Response("\n".join(lines) + "\n", media_type="application/x-ndjson")

    @app.post("/v1/has")
    def has(body: HasBody) -> Response:
        limit = 10_000 if broken == "has_no_limit" else 50
        if not 1 <= len(body.pairs) <= limit:
            return JSONResponse({"error": "bad_request"}, status_code=400)
        hits = []
        for pair in body.pairs:
            track = Track(artist=pair.artist, title=pair.title)
            hit = max((score(track, path) for path in files.values()), default=0.0) >= 0.75
            if broken == "has_says_yes":
                hit = True
            if broken == "has_misses_own":
                hit = False
            hits.append(hit)
        if broken == "has_short":
            hits = hits[:-1]
        if broken == "has_sorted":
            hits = sorted(hits, reverse=True)
        if broken == "has_list":
            return JSONResponse(hits)
        return JSONResponse({"hits": hits})

    return app


def _free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


@contextmanager
def running_extension(app: FastAPI) -> Iterator[str]:
    """Real HTTP server on loopback: core and checks access extension over network, like in compose."""
    port = _free_port()
    server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port, log_level="warning"))
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    deadline = time.monotonic() + 10
    while not server.started:
        if time.monotonic() > deadline:
            raise RuntimeError("поддельное расширение не поднялось за 10 с")
        time.sleep(0.05)
    try:
        yield f"http://127.0.0.1:{port}"
    finally:
        server.should_exit = True
        thread.join(timeout=10)
