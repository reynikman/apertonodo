"""FT-763: with `EXTENSIONS` catalog rebuilds itself — by age, not by its own releases table.

Catalog rebuilds by age: there are no own seeders by which to judge freshness. Build inside the server does not touch the overall "playable" question (`use_extensions`):
resetting it to empty would cause the whole server to silently fall back to its releases table.
"""

from __future__ import annotations

import asyncio
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

import asyncpg
import pytest

from app import catalog, catalog_from_extensions
from app.catalog_from_extensions import BuildResult
from app.main import create_app
from app.migrate import apply


def _set_built(url: str, hours_ago: float | None) -> None:
    async def go() -> None:
        await apply(url)
        conn = await asyncpg.connect(url)
        try:
            await conn.execute("DELETE FROM catalog_built")
            if hours_ago is not None:
                await conn.execute(
                    "INSERT INTO catalog_built (id, built_at) VALUES (1, $1)",
                    datetime.now(UTC) - timedelta(hours=hours_ago),
                )
        finally:
            await conn.close()

    asyncio.run(go())


def _pages(url: str, tmp_path: Path) -> Any:
    app = create_app(
        database_url=url,
        catalog=[],
        extensions={"ext": "http://127.0.0.1:9"},
    )
    return app.state.catalog_pages


@pytest.fixture
def builds(monkeypatch: pytest.MonkeyPatch) -> list[dict[str, str]]:
    seen: list[dict[str, str]] = []

    async def build(_url: str, urls: dict[str, str]) -> dict[str, Any]:
        seen.append(urls)
        return {"artists": 1, "genres": 1, "songs": 1}

    monkeypatch.setattr(catalog, "build_from_extensions", build)
    return seen


@pytest.mark.parametrize("hours_ago", [None, 7.0])
def test_old_or_missing_catalog_is_rebuilt_from_extensions(
    postgres_url: str,
    tmp_path: Path,
    builds: list[dict[str, str]],
    hours_ago: float | None,
) -> None:
    _set_built(postgres_url, hours_ago)
    asyncio.run(_pages(postgres_url, tmp_path)._build_if_stale())
    assert builds == [{"ext": "http://127.0.0.1:9"}]


def test_fresh_catalog_is_left_alone(
    postgres_url: str, tmp_path: Path, builds: list[dict[str, str]]
) -> None:
    _set_built(postgres_url, 1.0)
    asyncio.run(_pages(postgres_url, tmp_path)._build_if_stale())
    assert builds == []


def test_build_leaves_the_servers_playable_alone(
    postgres_url: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    async def built(*_args: Any, **_kwargs: Any) -> BuildResult:
        return BuildResult(status="built", artists=1, genres=1)

    asked: list[Any] = []

    async def tracks(_url: str, *, ask: Any = None) -> int:
        asked.append(ask)
        return 0

    monkeypatch.setattr(catalog_from_extensions, "build", built)
    monkeypatch.setattr(catalog, "build_tracks", tracks)
    servers = object()
    catalog.use_extensions(servers)  # type: ignore[arg-type]
    try:
        asyncio.run(
            catalog.build_from_extensions(postgres_url, {"ext": "http://127.0.0.1:9"})
        )
        assert catalog._extensions is servers, (
            "build reset the whole server's 'playable' check"
        )
    finally:
        catalog.use_extensions(None)
    assert asked and asked[0] is not None, (
        "build songs query extensions with their own client"
    )
