"""FT-762: extension file pinning — shared across users, and core does not lose it.

The pin key is the extension file number (`<name>:<number>`, extension contract). The number is shared across all
server users: unpinning is only possible when no user's download holds it. The extension could have lost
its pin (fresh database, failed call) — core repeats pins of all live downloads upon startup.
"""

from __future__ import annotations

import asyncio
import secrets
import uuid
from pathlib import Path

import asyncpg
import pytest
from fake_extension import running_extension
from fastapi.testclient import TestClient
from test_extension_asset import Disk, _core, _forget_disk, _song, _state, _tone
from test_library import _AUTH_HEADER, db, prepared_db  # noqa: F401
from test_opus_variant import _wait

from app.users import create_user


def _second_user(client: TestClient, url: str) -> dict[str, str]:
    username = f"pins_{uuid.uuid4().hex}"
    password = secrets.token_urlsafe(32)

    async def add() -> None:
        conn = await asyncpg.connect(url)
        try:
            await create_user(conn, username, password)
        finally:
            await conn.close()

    asyncio.run(add())
    got = client.post(
        "/v1/auth/login",
        json={"username": username, "password": password, "device_name": "pins-test"},
    )
    assert got.status_code == 200, got.text
    return {"Authorization": f"Bearer {got.json()['token']}"}


@pytest.mark.real_auth
def test_one_person_removing_keeps_the_pin_of_another(db: str, tmp_path: Path) -> None:  # noqa: F811
    _forget_disk(db)
    song = _song()
    disk = Disk(_tone(tmp_path / "music" / "01.mp3", song))
    with running_extension(disk.app()) as url:
        with TestClient(
            _core(url, song, tmp_path, db), headers=_AUTH_HEADER.get()
        ) as client:
            other = _second_user(client, db)
            for headers in (None, other):
                asked = client.post(
                    "/v1/downloads", json={"track_ids": [song["id"]]}, headers=headers
                )
                assert asked.status_code == 202, asked.text
            assert _wait(lambda: _state(client, song["id"]) == "ready", 30)
            assert _wait(
                lambda: (
                    {
                        i["track_id"]: i["state"]
                        for i in client.get("/v1/downloads", headers=other).json()[
                            "items"
                        ]
                    }.get(song["id"])
                    == "ready"
                ),
                30,
            )

            client.post("/v1/downloads/remove", json={"track_ids": [song["id"]]})
            assert ("one", False) not in disk.pins, (
                "second user still holds the file — do not unpin the number"
            )

            client.post(
                "/v1/downloads/remove", json={"track_ids": [song["id"]]}, headers=other
            )
            assert disk.pins[-1] == ("one", False), (
                "no one holds the file — pinning released"
            )


@pytest.mark.real_auth
def test_core_repeats_pins_after_restart(db: str, tmp_path: Path) -> None:  # noqa: F811
    _forget_disk(db)
    song = _song()
    path = _tone(tmp_path / "music" / "01.mp3", song)
    disk = Disk(path)
    with running_extension(disk.app()) as url:
        with TestClient(
            _core(url, song, tmp_path, db), headers=_AUTH_HEADER.get()
        ) as client:
            client.post("/v1/downloads", json={"track_ids": [song["id"]]})
            assert _wait(lambda: _state(client, song["id"]) == "ready", 30)

    # Extension restarted with a clean database: knows nothing about the pin.
    fresh = Disk(path)
    with running_extension(fresh.app()) as url:
        with TestClient(_core(url, song, tmp_path, db), headers=_AUTH_HEADER.get()):
            assert _wait(lambda: ("one", True) in fresh.pins, 10), (
                "core did not repeat pin for live download"
            )
