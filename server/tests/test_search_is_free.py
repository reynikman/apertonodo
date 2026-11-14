"""Search does not query sources, while playback does.

Measurement on prod address on September 18, 2026: more than half of Play clicks
responded "Failed — retry". Prewarming was to blame: `/v1/search`
scheduled a background task and polled sources for five more tracks in the results.
Each such query went through a shared queue, which did not drain, and the request
the user was waiting for hit a timeout.

The first test catches prewarming regression. The second prevents "fixing" the first
by disabling source lookup entirely.
"""

from __future__ import annotations

import json
from pathlib import Path

from fake_extension import running_extension
from fakes import CountingExtension
from fastapi.testclient import TestClient

from app.main import create_app

ROOT = Path(__file__).resolve().parents[2]
CATALOG = json.loads((ROOT / "contracts" / "fixtures" / "catalog.json").read_text())["tracks"]


def test_search_never_asks_the_sources() -> None:
    extension = CountingExtension()
    with running_extension(extension.app()) as url:
        app = create_app(database_url=None, catalog=CATALOG, catalog_port=None, extensions={"count": url})
        with TestClient(app) as client:
            response = client.get("/v1/search", params={"q": "duality slipknot"})

    assert response.status_code == 200
    assert response.json()["tracks"], "search must find something in fixture"
    # Exactly zero. Even one call is prewarming returned under a different name.
    assert extension.asked == [], f"search queried sources: {len(extension.asked)} time(s)"


def test_playback_still_asks_the_sources() -> None:
    extension = CountingExtension()
    with running_extension(extension.app()) as url:
        app = create_app(database_url=None, catalog=CATALOG, catalog_port=None, extensions={"count": url})
        with TestClient(app) as client:
            track_id = client.get("/v1/search", params={"q": "duality slipknot"}).json()["tracks"][0]["id"]
            client.post("/v1/playback", json={"track_id": track_id})

    assert extension.asked, "playback must query the source"
