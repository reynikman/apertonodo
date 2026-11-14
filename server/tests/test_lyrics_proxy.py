"""FT-624 (Р-A77, Р-A88): lyrics — core asks the "lyrics" extension (FT-620).

The app knows only track ID and calls `GET /v1/lyrics/{track_id}`. Core takes artist,
title, and duration from its database and asks the extension (`LYRICS_URL`, contract `contracts/lyrics-api.md`).
The extension's response goes to the app with the same fields — `found`, `instrumental`, `plain`, `synced`, and nothing else.

Extension here is a fake HTTP server on 127.0.0.1: tests do not make network calls. Guarded:
- core sends artist, title, and duration in seconds to the extension (without duration if none);
- unknown song yields 404, and extension is not asked;
- empty `LYRICS_URL` yields 503 `lyrics_off`; extension silent or responding 503/500 yields 503 `unavailable`, does not hang;
- log contains neither artist nor title.

What tests do not prove: live extension with LRCLIB — lead on production after compose integration.
"""

from __future__ import annotations

import asyncio
import json
import logging
import socket
import threading
import time
import uuid
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import Any

import asyncpg
import pytest
import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from fastapi.testclient import TestClient

from app.main import create_app
from app.migrate import apply

ROOT = Path(__file__).resolve().parents[2]
CATALOG = json.loads((ROOT / "contracts" / "fixtures" / "catalog.json").read_text())["tracks"]
SONG = str(uuid.uuid4())
NO_LENGTH = str(uuid.uuid4())
ARTIST, TITLE = "Glass Harbor", "Northern Lights"
SYNCED = "[00:12.30] Под северным небом"


class Extension:
    def __init__(self) -> None:
        self.asked: list[dict[str, Any]] = []
        self.answer: tuple[int, Any] = (
            200,
            {"found": True, "instrumental": False, "plain": "Под северным небом", "synced": SYNCED},
        )
        self.delay = 0.0

    def app(self) -> FastAPI:
        app = FastAPI()

        @app.post("/v1/lyrics")
        async def lyrics(request: Request) -> JSONResponse:
            self.asked.append(await request.json())
            await asyncio.sleep(self.delay)
            code, body = self.answer
            return JSONResponse(body, status_code=code)

        return app


def _free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


@contextmanager
def _serve(app: Any) -> Iterator[str]:
    port = _free_port()
    server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port, log_level="warning"))
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    deadline = time.monotonic() + 10
    while not server.started:
        assert time.monotonic() < deadline, "extension did not start within 10 s"
        time.sleep(0.05)
    try:
        yield f"http://127.0.0.1:{port}"
    finally:
        server.should_exit = True
        thread.join(timeout=10)


def _seed(url: str) -> None:
    async def run() -> None:
        await apply(url)
        conn = await asyncpg.connect(url)
        try:
            await conn.execute("DELETE FROM tracks WHERE id = ANY($1::uuid[])", [uuid.UUID(SONG), uuid.UUID(NO_LENGTH)])
            await conn.execute(
                "INSERT INTO tracks (id, title, artist, duration_ms, canonical_key) VALUES "
                "($1, $2, $3, 241400, 'ft624-a'), ($4, $2, $3, 0, 'ft624-b')",
                uuid.UUID(SONG), TITLE, ARTIST, uuid.UUID(NO_LENGTH),
            )
        finally:
            await conn.close()

    asyncio.run(run())


@contextmanager
def _world(
    postgres_url: str, monkeypatch: pytest.MonkeyPatch, *, url: str | None = None
) -> Iterator[tuple[Extension, TestClient]]:
    _seed(postgres_url)
    ext = Extension()
    with _serve(ext.app()) as served:
        monkeypatch.setenv("LYRICS_URL", served if url is None else url)
        app = create_app(
            database_url=postgres_url,
            catalog=CATALOG,
        )
        yield ext, TestClient(app)


def test_words_come_from_the_extension(postgres_url: str, monkeypatch: pytest.MonkeyPatch) -> None:
    with _world(postgres_url, monkeypatch) as (ext, client):
        r = client.get(f"/v1/lyrics/{SONG}")
        assert r.status_code == 200
        assert r.json() == {
            "found": True,
            "instrumental": False,
            "plain": "Под северным небом",
            "synced": SYNCED,
        }
        assert ext.asked == [{"artist": ARTIST, "title": TITLE, "duration_s": 241}]


def test_without_length_asks_without_it(postgres_url: str, monkeypatch: pytest.MonkeyPatch) -> None:
    with _world(postgres_url, monkeypatch) as (ext, client):
        client.get(f"/v1/lyrics/{NO_LENGTH}")
        assert ext.asked == [{"artist": ARTIST, "title": TITLE}]


def test_not_found_and_instrumental_pass_through(
    postgres_url: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    with _world(postgres_url, monkeypatch) as (ext, client):
        ext.answer = (200, {"found": False})
        assert client.get(f"/v1/lyrics/{SONG}").json() == {"found": False}
        ext.answer = (
            200,
            {"found": True, "instrumental": True, "plain": None, "synced": None, "debug": "x"},
        )
        assert client.get(f"/v1/lyrics/{SONG}").json() == {
            "found": True,
            "instrumental": True,
            "plain": None,
            "synced": None,
        }, "extra extension field does not go to the app"


def test_unknown_song_does_not_ask(postgres_url: str, monkeypatch: pytest.MonkeyPatch) -> None:
    with _world(postgres_url, monkeypatch) as (ext, client):
        assert client.get(f"/v1/lyrics/{uuid.uuid4()}").status_code == 404
        assert client.get("/v1/lyrics/not-a-uuid").status_code in (404, 422)
        assert ext.asked == []


def test_off_without_lyrics_url(postgres_url: str, monkeypatch: pytest.MonkeyPatch) -> None:
    with _world(postgres_url, monkeypatch, url="") as (ext, client):
        r = client.get(f"/v1/lyrics/{SONG}")
        assert r.status_code == 503
        assert r.json() == {"error": "lyrics_off"}
        assert ext.asked == []


@pytest.mark.parametrize("answer", [(503, {"error": "unavailable"}), (500, {"x": 1}), (200, "не json")])
def test_extension_trouble_is_unavailable(
    postgres_url: str, monkeypatch: pytest.MonkeyPatch, answer: tuple[int, Any]
) -> None:
    with _world(postgres_url, monkeypatch) as (ext, client):
        ext.answer = answer
        r = client.get(f"/v1/lyrics/{SONG}")
        assert r.status_code == 503
        assert r.json() == {"error": "unavailable"}


def test_silent_extension_does_not_hang(postgres_url: str, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("LYRICS_TIMEOUT_S", "0.5")
    with _world(postgres_url, monkeypatch) as (ext, client):
        ext.delay = 3.0
        began = time.monotonic()
        r = client.get(f"/v1/lyrics/{SONG}")
        assert time.monotonic() - began < 2.5
        assert r.status_code == 503


def test_log_has_no_names(
    postgres_url: str, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    caplog.set_level(logging.DEBUG)
    with _world(postgres_url, monkeypatch) as (ext, client):
        client.get(f"/v1/lyrics/{SONG}")
        ext.answer = (200, {"found": False})
        client.get(f"/v1/lyrics/{SONG}")
    text = "\n".join(r.getMessage() for r in caplog.records)
    assert "lyrics found" in text
    assert "lyrics not_found" in text
    for secret in (ARTIST, TITLE, "Glass+Harbor", "Northern+Lights", "северным"):
        assert secret not in text, secret
