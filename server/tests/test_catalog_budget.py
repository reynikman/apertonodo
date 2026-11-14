"""Search does not wait for live catalog beyond budget and does not query dead catalog.

Verified on production address on September 18, 2026: provider cuts TLS to
musicbrainz.org by SNI (same connection without SNI succeeds), catalog responded
with `ConnectTimeout`, and each search hung for 12–22 seconds to return the exact same
fixture output. The phone would not wait, and on-device run turned red.

What these tests prove: slow catalog does not delay response, after failure
it is not queried during the cooldown period, and fast live results still
reach the output. What they do not prove: that catalog is available at all — that
is a network matter, not a code matter.
"""

from __future__ import annotations

import asyncio
import json
import time
from pathlib import Path
from typing import Any

from fastapi.testclient import TestClient

from app.main import create_app

ROOT = Path(__file__).resolve().parents[2]
CATALOG = json.loads((ROOT / "contracts" / "fixtures" / "catalog.json").read_text())["tracks"]


class _SlowCatalog:
    """Catalog that does not respond: exactly what blocked MusicBrainz does."""

    def __init__(self, delay_s: float = 5.0) -> None:
        self.delay_s = delay_s
        self.calls = 0

    async def search(self, query: str, limit: int) -> list[dict[str, Any]]:
        self.calls += 1
        await asyncio.sleep(self.delay_s)
        return []


class _FastCatalog:
    def __init__(self) -> None:
        self.calls = 0

    async def search(self, query: str, limit: int) -> list[dict[str, Any]]:
        self.calls += 1
        return [
            {
                "id": "mb-1",
                "artist": "Metallica",
                "title": "Enter Sandman",
                "duration_ms": 331560,
                "artwork_url": "",
            }
        ]


def test_slow_catalog_does_not_hold_up_search() -> None:
    port = _SlowCatalog()
    app = create_app(catalog=CATALOG, catalog_port=port)
    app.state.catalog_timeout_s = 0.3
    with TestClient(app) as client:
        started = time.monotonic()
        response = client.get("/v1/search", params={"q": "duality"})
        elapsed = time.monotonic() - started

    assert elapsed < 2.0, f"search waited for catalog {elapsed:.1f} s instead of budget"
    # Nothing local for query, catalog exceeded budget — honest failure, not empty output.
    assert response.status_code == 503
    assert response.json() == {"status": "catalog_unavailable"}


def test_dead_catalog_is_skipped_for_the_cooldown() -> None:
    """Dead catalog stops being queried — but not on the first failure."""
    port = _SlowCatalog()
    app = create_app(catalog=CATALOG, catalog_port=port)
    app.state.catalog_timeout_s = 0.3
    app.state.catalog_cooldown_s = 60.0
    with TestClient(app) as client:
        client.get("/v1/search", params={"q": "duality"})
        client.get("/v1/search", params={"q": "duality"})
        started = time.monotonic()
        response = client.get("/v1/search", params={"q": "duality"})
        elapsed = time.monotonic() - started

    assert port.calls == 2, f"queried dead catalog {port.calls} time(s)"
    assert elapsed < 0.3, f"third search still waited {elapsed:.2f} s"
    # Cooldown is also 'catalog unavailable', not 'nothing found'.
    assert response.status_code == 503


class _FlakyCatalog:
    """Exceeded budget once, then responds normally."""

    def __init__(self) -> None:
        self.calls = 0

    async def search(self, query: str, limit: int) -> list[dict[str, Any]]:
        self.calls += 1
        if self.calls == 1:
            await asyncio.sleep(5)
        return [
            {
                "id": "mb-1",
                "artist": "Pink Floyd",
                "title": "Time",
                "duration_ms": 413000,
                "artwork_url": "",
            }
        ]


def test_one_slow_search_does_not_blank_the_catalog() -> None:
    """A minute without search is too high a cost for one slow query.

    Measurement in prod on September 18, 2026: a single `TimeoutError` was enough
    for search to serve a single fixture for the next 60 seconds and look broken.
    Cooldown is needed against a dead catalog, not against bad luck.
    """
    port = _FlakyCatalog()
    app = create_app(catalog=CATALOG, catalog_port=port)
    app.state.catalog_timeout_s = 0.3
    app.state.catalog_cooldown_s = 60.0
    with TestClient(app) as client:
        client.get("/v1/search", params={"q": "duality"})
        response = client.get("/v1/search", params={"q": "pink floyd time"})

    assert port.calls == 2, "catalog stopped being queried after one failure"
    assert "Time" in [track["title"] for track in response.json()["tracks"]]


def test_cooldown_expires_and_the_catalog_gets_another_chance() -> None:
    """Cooldown is not forever: catalog might have recovered."""
    port = _SlowCatalog()
    app = create_app(catalog=CATALOG, catalog_port=port)
    app.state.catalog_timeout_s = 0.2
    app.state.catalog_cooldown_s = 0.0
    with TestClient(app) as client:
        client.get("/v1/search", params={"q": "duality"})
        client.get("/v1/search", params={"q": "duality"})

    assert port.calls == 2, f"catalog was queried {port.calls} time(s) after cooldown"


def test_fast_catalog_results_still_join_the_answer() -> None:
    """Budget does not cancel live catalog — it cancels waiting."""
    port = _FastCatalog()
    app = create_app(catalog=CATALOG, catalog_port=port)
    with TestClient(app) as client:
        response = client.get("/v1/search", params={"q": "enter sandman"})

    titles = [track["title"] for track in response.json()["tracks"]]
    assert "Enter Sandman" in titles, titles
    assert port.calls == 1
