"""FT-592 (R-A90): Opus copy and offline download — by `<extension>:<id>` key rather than torrent infohash.

Currently an Opus copy resides in `<variant_dir>/<info_hash>/<file_index>.opus`, while the `downloads` row keeps
`info_hash`. A song played via an extension has no torrent hash: without this card it would never
get an Opus copy and would not download for offline. Core fetches the complete file from the extension (`GET /v1/files/{id}`) and
then proceeds as usual: compresses FLAC, serves the finished file with Range, pins the downloaded file — via
`POST /v1/pins` of the extension.

The extension here is a real HTTP server with a single file on disk. The old resolver path is empty.

What tests do not prove: the same via BitTorrent extension and a real engine — that is
`extensions/bittorrent/tests/`; pinning in `user_pins` by `asset` key — FT-595.
"""

# Fixtures `db`/`prepared_db` are taken from test_library.py: import and test parameter with the same name — this is how pytest finds
# the fixture, not an unused import.
# ruff: noqa: F401, F811
from __future__ import annotations

import asyncio
import json
import random
import string
import uuid
from pathlib import Path
from typing import Any

import asyncpg
import pytest
from fake_extension import running_extension
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response
from fastapi.testclient import TestClient
from test_library import _AUTH_HEADER, db, prepared_db
from test_opus_variant import _ffmpeg, _wait

from app.main import create_app
from app.media import audio_response

FORMATS = {".flac": "flac", ".mp3": "mp3"}


def _song() -> dict[str, Any]:
    # Unique artist per test: shared database, memory of "where the song was played from" must not interfere.
    artist = "Ext" + "".join(random.choices(string.ascii_lowercase, k=8))
    return {
        "id": str(uuid.uuid4()),
        "title": "Disasterpiece",
        "artist": artist,
        "duration_ms": 1,
        "artwork_url": "",
    }


def _tone(path: Path, song: dict[str, Any], seconds: float = 3.0) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    _ffmpeg(
        "-f", "lavfi", "-i", f"sine=frequency=440:duration={seconds}",
        "-metadata", f"artist={song['artist']}", "-metadata", f"title={song['title']}",
        str(path),
    )  # fmt: skip
    return path


class Disk:
    """Extension with a single file on disk; remembers what it was told regarding pins and complaints."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.pins: list[tuple[str, bool]] = []
        self.file_reads = 0

    def app(self) -> FastAPI:
        app = FastAPI()
        fmt = FORMATS[self.path.suffix]

        @app.get("/v1/info")
        def info() -> dict[str, Any]:
            return {
                "api": 1,
                "name": "disk",
                "version": "0.1.0",
                "kind": "music",
                "features": ["pins"],
            }

        @app.get("/v1/health")
        def health() -> dict[str, Any]:
            return {"ok": True}

        @app.post("/v1/find")
        def find() -> dict[str, Any]:
            size = self.path.stat().st_size
            return {
                "items": [
                    {
                        "id": "one",
                        "confidence": 0.95,
                        "format": fmt,
                        "size": size,
                        "quality": "lossy",
                    }
                ]
            }

        @app.post("/v1/prepare")
        def prepare() -> dict[str, Any]:
            return {"state": "ready", "format": fmt, "size": self.path.stat().st_size}

        @app.get("/v1/files/{file_id}")
        def files(file_id: str, request: Request) -> Response:
            if file_id != "one":
                return JSONResponse({"error": "unknown_id"}, status_code=404)
            self.file_reads += 1
            return audio_response(self.path, request.headers.get("range"))

        @app.post("/v1/failed")
        def failed() -> Response:
            return Response(status_code=204)

        @app.post("/v1/pins")
        async def pins(request: Request) -> Response:
            body = await request.json()
            self.pins.append((body["id"], body["pinned"]))
            return Response(status_code=204)

        return app


def _core(
    url: str, song: dict[str, Any], tmp_path: Path, database_url: str | None = None
) -> Any:
    return create_app(
        database_url=database_url,
        catalog=[song],
        variant_dir=tmp_path / "variants",
        download_poll_s=0.05,
        extensions={"disk": url},
    )


def _play(client: TestClient, song: dict[str, Any], **body: Any) -> Any:
    played = client.post("/v1/playback", json={"track_id": song["id"], **body})
    assert played.status_code == 200, played.text
    return client.get(f"/v1/stream/{played.json()['token']}")


# ------------------------------------------------------------ Opus


def test_listened_flac_from_an_extension_gets_an_opus_copy(tmp_path: Path) -> None:
    song = _song()
    disk = Disk(_tone(tmp_path / "music" / "01.flac", song))
    with (
        running_extension(disk.app()) as url,
        TestClient(_core(url, song, tmp_path)) as client,
    ):
        first = _play(client, song, prefer="opus")
        assert first.content == disk.path.read_bytes(), (
            "copy does not exist yet — original is played"
        )
        assert first.headers["content-type"].startswith("audio/flac")

        def opus_plays() -> bool:
            return (
                _play(client, song, prefer="opus")
                .headers["content-type"]
                .startswith("audio/ogg")
            )

        assert _wait(opus_plays, 30), (
            "after playing FLAC through extension, Opus copy did not appear"
        )
        copies = list((tmp_path / "variants").rglob("*.opus"))
        assert len(copies) == 1, copies
        played = client.post(
            "/v1/playback", json={"track_id": song["id"], "prefer": "opus"}
        )
        part = client.get(
            f"/v1/stream/{played.json()['token']}", headers={"Range": "bytes=100-199"}
        )
        assert part.status_code == 206, "copy can be sought"
        assert part.content == copies[0].read_bytes()[100:200]
        wifi = _play(client, song)
        assert wifi.content == disk.path.read_bytes(), (
            "without prefer — original, as before"
        )

    name = str(copies[0].relative_to(tmp_path / "variants")).casefold()
    for word in (song["artist"].casefold(), "disasterpiece", "music", "01.flac"):
        assert word not in name, f"copy path mentions '{word}'"


def test_mp3_from_an_extension_gets_no_copy(tmp_path: Path) -> None:
    song = _song()
    disk = Disk(_tone(tmp_path / "music" / "01.mp3", song))
    with (
        running_extension(disk.app()) as url,
        TestClient(_core(url, song, tmp_path)) as client,
    ):
        assert _play(client, song).content == disk.path.read_bytes()
        assert not _wait(lambda: any((tmp_path / "variants").rglob("*.opus")), 3), (
            "MP3 is not compressed"
        )
        assert disk.file_reads == 1, (
            "after playing MP3, core fetched file from extension again"
        )


# ------------------------------------------------------------ downloads


def _sql(url: str, sql: str, *args: Any) -> Any:
    async def run() -> Any:
        conn = await asyncpg.connect(url)
        try:
            return await conn.fetchrow(sql, *args)
        finally:
            await conn.close()

    return asyncio.run(run())


def _forget_disk(url: str) -> None:
    """The id `disk:one` is the same across tests while database is shared: foreign downloads would keep it pinned (FT-762)."""
    _sql(url, "DELETE FROM downloads WHERE asset LIKE 'disk:%'")


def _state(client: TestClient, track_id: str) -> str | None:
    items = {
        item["track_id"]: item for item in client.get("/v1/downloads").json()["items"]
    }
    return items[track_id]["state"] if track_id in items else None


@pytest.mark.real_auth
@pytest.mark.parametrize("suffix", [".mp3", ".flac"])
def test_download_through_an_extension(db: str, tmp_path: Path, suffix: str) -> None:
    _forget_disk(db)
    song = _song()
    disk = Disk(_tone(tmp_path / "music" / f"01{suffix}", song))
    with running_extension(disk.app()) as url:
        with TestClient(
            _core(url, song, tmp_path, db), headers=_AUTH_HEADER.get()
        ) as client:
            asked = client.post("/v1/downloads", json={"track_ids": [song["id"]]})
            assert asked.status_code == 202, asked.text
            assert _wait(lambda: _state(client, song["id"]) in ("ready", "failed"), 30)
            assert _state(client, song["id"]) == "ready"

            listing = client.get("/v1/downloads").text
            for leak in ("disk:", '"one"', url):
                assert leak not in listing, f"downloads response contains {leak}"

            row = _sql(
                db,
                "SELECT asset FROM downloads WHERE track_id = $1",
                uuid.UUID(song["id"]),
            )
            assert dict(row) == {"asset": "disk:one"}
            assert disk.pins == [("one", True)], "downloaded item is pinned in extension"

            got = client.get(f"/v1/downloads/{song['id']}/file")
            assert got.status_code == 200, got.text
            if suffix == ".mp3":
                assert got.content == disk.path.read_bytes()
                assert got.headers["content-type"].startswith("audio/mpeg")
            else:
                assert got.headers["content-type"].startswith("audio/ogg"), (
                    "FLAC is downloaded as Opus copy"
                )
                assert got.content[:4] == b"OggS"
            part = client.get(
                f"/v1/downloads/{song['id']}/file", headers={"Range": "bytes=10-19"}
            )
            assert part.status_code == 206 and part.content == got.content[10:20], (
                "interrupted download can be resumed"
            )

            assert (
                client.post(
                    "/v1/downloads/remove", json={"track_ids": [song["id"]]}
                ).status_code
                == 204
            )
            assert disk.pins == [("one", True), ("one", False)], (
                "removed — pin is released"
            )


@pytest.mark.real_auth
def test_download_of_two_songs_from_one_file_keeps_the_pin(
    db: str, tmp_path: Path
) -> None:
    """Two catalog tracks — one extension id: removing the first still holds the id for the second."""
    _forget_disk(db)
    song, twin = _song(), _song()
    disk = Disk(_tone(tmp_path / "music" / "01.mp3", song))
    with running_extension(disk.app()) as url:
        app = create_app(
            database_url=db,
            catalog=[song, twin],
            variant_dir=tmp_path / "variants",
            download_poll_s=0.05,
            extensions={"disk": url},
        )
        with TestClient(app, headers=_AUTH_HEADER.get()) as client:
            client.post("/v1/downloads", json={"track_ids": [song["id"], twin["id"]]})
            assert _wait(
                lambda: (
                    _state(client, song["id"]) == "ready"
                    and _state(client, twin["id"]) == "ready"
                ),
                30,
            )
            client.post("/v1/downloads/remove", json={"track_ids": [song["id"]]})
            assert ("one", False) not in disk.pins, (
                "second track still waits for the file — do not unpin the id"
            )
            client.post("/v1/downloads/remove", json={"track_ids": [twin["id"]]})
            assert disk.pins[-1] == ("one", False)


def test_download_contract_has_no_extension_words() -> None:
    root = Path(__file__).resolve().parents[2] / "contracts"
    for name in ("downloads.request.json", "downloads.response.json"):
        text = json.dumps(json.loads((root / name).read_text())).casefold()
        assert "asset" not in text and "extension" not in text, name
