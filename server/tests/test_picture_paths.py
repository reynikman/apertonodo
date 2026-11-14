"""Image does not open a database connection on every request (P3.5, phase 9; measurement 01.10).

`/v1/covers` and `/v1/photos` serve ready file from disk, while database only holds
the path to it. Each request opened its own connection just for that path: one photo —
156 ms, twelve at once — 1.1–1.9 s each, genre screen with 60 photos — almost 6 s.
The server caches the found image path; if file is missing, queries the database again.
"""

from __future__ import annotations

import asyncio
import uuid
from pathlib import Path
from typing import Any

import pytest
from fakes import FakeWeb, pictures
from fastapi.testclient import TestClient
from test_catalog_browse import (
    _extension,
    JPEG,
    LOW_TIDE,
    FakeMusicBrainz,
    _app,
    _seed,
    _wait,
)


@pytest.fixture
def built(postgres_url: str) -> str:
    """Same common set as test_catalog_browse: schema, rows, catalog build."""
    asyncio.run(_seed(postgres_url))
    asyncio.run(_extension().build_catalog(postgres_url))
    return postgres_url


def _counting(app: Any) -> list[int]:
    pages = app.state.catalog_pages
    real = pages.connect
    opened: list[int] = []

    async def connect() -> Any:
        opened.append(1)
        return await real()

    pages.connect = connect
    return opened


def _ready(built: str, tmp_path: Path) -> tuple[Any, TestClient]:
    web = FakeWeb({"coverartarchive.org": JPEG})
    app = _app(built, FakeMusicBrainz(), None, pictures(tmp_path, built, web))
    client = TestClient(app)
    client.__enter__()
    client.get(f"/v1/albums/{LOW_TIDE}")
    _wait(lambda: client.get(f"/v1/covers/{LOW_TIDE}").status_code == 200)
    return app, client


def test_known_picture_does_not_open_the_database_again(
    built: str, tmp_path: Path
) -> None:
    app, client = _ready(built, tmp_path)
    try:
        opened = _counting(app)
        for _ in range(20):
            response = client.get(f"/v1/covers/{LOW_TIDE}")
            assert response.status_code == 200
            assert response.content == JPEG
            assert response.headers["content-type"] == "image/jpeg"
    finally:
        client.__exit__(None, None, None)
    assert len(opened) <= 1, (
        f"20 requests for the same image opened database {len(opened)} times"
    )


def test_unknown_picture_is_still_404(built: str, tmp_path: Path) -> None:
    app, client = _ready(built, tmp_path)
    try:
        missing = uuid.uuid4()
        assert [client.get(f"/v1/covers/{missing}").status_code for _ in range(3)] == [
            404,
            404,
            404,
        ]
        assert client.get(f"/v1/photos/{missing}").status_code == 404
    finally:
        client.__exit__(None, None, None)


def test_vanished_file_is_asked_again_not_served_from_memory(
    built: str, tmp_path: Path
) -> None:
    app, client = _ready(built, tmp_path)
    try:
        files = [
            p for p in tmp_path.rglob("*") if p.is_file() and p.read_bytes() == JPEG
        ]
        assert files, "cover did not land on disk"
        for file in files:
            file.unlink()
        opened = _counting(app)
        response = client.get(f"/v1/covers/{LOW_TIDE}")
    finally:
        client.__exit__(None, None, None)
    assert response.status_code == 404
    assert len(opened) == 1, "missing file did not trigger re-querying the database"
