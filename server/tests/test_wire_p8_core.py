"""Wiring of P8 core (FT-757, FT-758): with `EXTENSIONS` set, the genre catalog
is built from extension dumps, and "is the song playable" is queried from them
(`POST /v1/has`) — in all places at once, via `catalog.playable`/`playable_pairs`.
Empty `EXTENSIONS` — nothing to play with: "is playable" is "no" everywhere.

What the test does not prove: that real extension dump at prod scale
is built within reasonable time — that is the switchover day FT-598.
"""

from __future__ import annotations

import asyncio
import json
from pathlib import Path
from typing import Any

import httpx
from fastapi.testclient import TestClient

from app import catalog, catalog_from_extensions
from app.catalog_from_extensions import BuildResult
from app.main import create_app
from app.playable_from_extensions import Playable

HAVE = {("Metallica", "Enter Sandman")}


async def _answer(request: httpx.Request) -> httpx.Response:
    if request.url.path == "/v1/info":
        return httpx.Response(200, json={"name": "ext", "version": "1", "features": ["catalog", "has"]})
    pairs = [(p["artist"], p["title"]) for p in json.loads(request.content)["pairs"]]
    return httpx.Response(200, json={"hits": [pair in HAVE for pair in pairs]})


class _NoDb:
    """Own releases table is not needed with extensions: touching the database makes test red."""

    async def fetch(self, *_args: Any, **_kwargs: Any) -> Any:
        raise AssertionError("при расширениях в свою таблицу раздач не ходят")


def test_playable_asks_extensions_when_set() -> None:
    async def go() -> tuple[list[bool], list[bool]]:
        async with httpx.AsyncClient(transport=httpx.MockTransport(_answer)) as client:
            catalog.use_extensions(Playable({"ext": "http://ext.test"}, client=client))
            try:
                page = await catalog.playable(_NoDb(), "Metallica", ["Enter Sandman", "No Song"])
                pairs = await catalog.playable_pairs(
                    _NoDb(), [("Metallica", "Enter Sandman"), ("Nobody", "No Song")]
                )
            finally:
                catalog.use_extensions(None)
        return page, pairs

    assert asyncio.run(go()) == ([True, False], [True, False])


def _app(extensions: dict[str, str], tmp_path: Path) -> Any:
    return create_app(catalog=[], extensions=extensions)


def test_app_with_extensions_switches_playable_and_back(tmp_path: Path) -> None:
    with TestClient(_app({"ext": "http://127.0.0.1:9"}, tmp_path)):
        assert catalog._extensions is not None
    assert catalog._extensions is None


def test_app_without_extensions_plays_nothing(tmp_path: Path) -> None:
    with TestClient(_app({}, tmp_path)):
        assert catalog._extensions is None
        assert asyncio.run(catalog.playable(None, "Metallica", ["Enter Sandman"])) == [False]
        assert asyncio.run(catalog.playable_pairs(None, [("Metallica", "Enter Sandman")])) == [False]


def test_build_command_uses_extensions(monkeypatch: Any) -> None:
    monkeypatch.setenv("DATABASE_URL", "postgresql://unused")
    monkeypatch.setenv("EXTENSIONS", "ext=http://ext.test")
    seen: dict[str, Any] = {}

    async def fake_build(url: str, urls: dict[str, str], *, client: httpx.AsyncClient) -> BuildResult:
        seen["urls"] = urls
        return BuildResult(status="built", artists=3, genres=2)

    async def fake_tracks(url: str, *, ask: Playable | None = None) -> int:
        # FT-763: dedicated query to extensions, build does not touch global `use_extensions`.
        seen["tracks_through_extensions"] = isinstance(ask, Playable)
        return 5

    monkeypatch.setattr(catalog_from_extensions, "build", fake_build)
    monkeypatch.setattr(catalog, "build_tracks", fake_tracks)

    assert catalog.main(["build"]) == 0
    assert seen == {"urls": {"ext": "http://ext.test"}, "tracks_through_extensions": True}
    assert catalog._extensions is None


def test_build_command_keeps_old_catalog_when_extension_fails(monkeypatch: Any) -> None:
    monkeypatch.setenv("DATABASE_URL", "postgresql://unused")
    monkeypatch.setenv("EXTENSIONS", "ext=http://ext.test")

    async def kept(url: str, urls: dict[str, str], *, client: httpx.AsyncClient) -> BuildResult:
        return BuildResult(status="kept", artists=0, genres=0, reason="info_failed")

    async def no_tracks(url: str, *, ask: Playable | None = None) -> int:
        raise AssertionError("старый каталог оставлен — песни не пересобираются")

    monkeypatch.setattr(catalog_from_extensions, "build", kept)
    monkeypatch.setattr(catalog, "build_tracks", no_tracks)

    assert catalog.main(["build"]) == 1
