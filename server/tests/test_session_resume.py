"""Session survives a process restart.

Previously tokens lived only in memory: a user pressed Play, music played,
the container was restarted — and the stream dropped, while the token turned into 404.
"""

from __future__ import annotations

import json
from pathlib import Path

from fake_extension import running_extension
from fastapi.testclient import TestClient
from test_extension_asset import Disk

from app.main import create_app
from app.migrate import apply

ROOT = Path(__file__).resolve().parents[2]
CATALOG = json.loads((ROOT / "contracts" / "fixtures" / "catalog.json").read_text())["tracks"]
DUALITY_ID = "33333333-3333-3333-3333-333333333333"
FIXTURE = ROOT / "contracts" / "fixtures" / "audio" / "tone-440hz-4s.mp3"


def _app(url: str, extension_url: str):
    return create_app(database_url=url, catalog=CATALOG, extensions={"disk": extension_url})


async def test_token_survives_a_restart(postgres_url: str) -> None:
    await apply(postgres_url)

    with running_extension(Disk(FIXTURE).app()) as ext:
        with TestClient(_app(postgres_url, ext)) as before:
            played = before.post("/v1/playback", json={"track_id": DUALITY_ID})
            assert played.status_code == 200
            token = played.json()["token"]
            assert before.get(f"/v1/stream/{token}").status_code == 200

        # A new application instance represents the restarted container:
        # memory is empty, only the database knows about the token.
        after = _app(postgres_url, ext)
        assert after.state.sessions == {}
        with TestClient(after) as client:
            stream = client.get(f"/v1/stream/{token}")
            status = client.get(f"/v1/playback/{token}/status")

    assert stream.status_code == 200
    assert stream.content[:3] == b"ID3"
    assert status.status_code == 200
    body = status.json()
    assert body["track"]["title"] == "Duality"
    assert body["state"] == "ready"


async def test_restart_does_not_resurrect_an_unknown_token(postgres_url: str) -> None:
    await apply(postgres_url)
    with TestClient(create_app(database_url=postgres_url, catalog=CATALOG)) as client:
        assert client.get("/v1/stream/выдуманный-токен").status_code == 404


async def test_restored_session_hides_source_fields(postgres_url: str) -> None:
    await apply(postgres_url)
    with running_extension(Disk(FIXTURE).app()) as ext:
        with TestClient(_app(postgres_url, ext)) as before:
            token = before.post("/v1/playback", json={"track_id": DUALITY_ID}).json()["token"]

        with TestClient(_app(postgres_url, ext)) as after:
            status = after.get(f"/v1/playback/{token}/status")

    blob = status.text.casefold()
    for word in ("info_hash", "media_path", "magnet", "rqbit", "file_index", "asset"):
        assert word not in blob, f"{word} leaked after session recovery"
