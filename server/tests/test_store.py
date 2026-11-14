"""What the server writes to the database and what it loads from it — on real PostgreSQL.

Audit findings from September 18, each guarded here.

1. Records already written with indexer key were never cleaned up — migration 006 handles this.
2. A displayed track lived only in memory: after deployment Play returned 404, and
   "retry" did not help — only a new search helped.
3. Database failure after the source was already ready yielded 500.

Without a database these tests are not silently skipped: under `CI=1` missing
`DATABASE_URL` is an error (`tests/conftest.py`).
"""

from __future__ import annotations

import logging
import uuid
from pathlib import Path
from typing import Any

import asyncpg
import pytest
from fastapi.testclient import TestClient
from fake_extension import running_extension
from test_extension_asset import Disk, _tone

from app.main import create_app
from app.migrate import apply
from app.store import token_hash

INFO_HASH = "c" * 40
MAGNET_WITH_PASSKEY = (
    f"magnet:?xt=urn:btih:{INFO_HASH}"
    "&tr=http%3A%2F%2Fbt.t-ru.org%2Fann%3Fmagnet"
    "&tr=http%3A%2F%2Fbt2.t-ru.org%2Fann%3Fpk%3DSECRETPASSKEY"
)


def _track(**overrides: Any) -> dict[str, Any]:
    track = {
        "id": str(uuid.uuid4()),
        "title": "Disasterpiece",
        "artist": "Slipknot",
        "duration_ms": 1,
        "artwork_url": "",
    }
    track.update(overrides)
    return track


async def _row(url: str, token: str) -> dict[str, Any]:
    conn = await asyncpg.connect(url)
    try:
        row = await conn.fetchrow(
            "SELECT * FROM playback_sessions WHERE token_hash = $1", token_hash(token)
        )
    finally:
        await conn.close()
    assert row is not None, "session is not written to database"
    return dict(row)


# FT-908: the scrub migration (006) is a no-op now; its test is replaced in test_migrations.py.


class _Catalog:
    def __init__(self, tracks: list[dict[str, Any]]) -> None:
        self.tracks = tracks

    async def search(self, query: str, limit: int) -> list[dict[str, Any]]:
        return [dict(track) for track in self.tracks]


async def test_shown_track_is_still_playable_after_a_restart(postgres_url: str) -> None:
    await apply(postgres_url)
    track = _track(title="Master of Puppets", artist="Metallica")
    before = create_app(database_url=postgres_url, catalog=[], catalog_port=_Catalog([track]))
    with TestClient(before) as client:
        shown = client.get("/v1/search", params={"q": "master of puppets"}).json()["tracks"]
    assert [item["id"] for item in shown] == [track["id"]]

    # Deployment: new process, empty memory, live catalog does not respond.
    after = create_app(
        database_url=postgres_url,
        catalog=[],
        catalog_port=_Catalog([]),
    )
    assert after.state.tracks == {}
    with TestClient(after) as client:
        played = client.post("/v1/playback", json={"track_id": track["id"]})

    # 409 "no source" — honest: there are no sources in the test. The main point is not
    # 404 "track not found", where "retry" never helps.
    assert played.status_code == 409, played.text
    assert after.state.tracks[track["id"]]["title"] == "Master of Puppets"


def test_database_down_after_the_source_is_ready_does_not_500(
    tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    track = _track()
    disk = Disk(_tone(tmp_path / "music" / "01.mp3", track))
    with running_extension(disk.app()) as url:
        app = create_app(
            database_url="postgresql://music@127.0.0.1:1/music",
            catalog=[track],
            extensions={"disk": url},
        )
        with caplog.at_level(logging.INFO, logger="apertonodo"), TestClient(
            app, raise_server_exceptions=False
        ) as client:
            response = client.post("/v1/playback", json={"track_id": track["id"]})
            token = response.json().get("token", "")
            stream = client.get(f"/v1/stream/{token}")

    assert response.status_code == 200, response.text
    assert stream.status_code == 200
    assert "session persist failed" in caplog.text
