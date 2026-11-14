"""Typeahead suggestions (Phase J, G53) — from own database only.

Owner's decision: the text typed by a user does not leave to external services,
neither to Apple, nor Deezer, nor Last.fm, nor MusicBrainz. This is verified not by words,
but by two things at once: suggestion responds with an active catalog that fails on any
call, and the catalog was never queried afterwards.

The second guard is response format: suggestion returns strings, not tracks. A track in
suggestion would imply it is already playable, but there is no live release verification
on this path.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from fastapi.testclient import TestClient
from test_search_own import LASTFM, RELEASES, filled  # noqa: F401  (fixture)

from app.main import create_app

ROOT = Path(__file__).resolve().parents[2]
CONTRACT = json.loads((ROOT / "contracts" / "suggest.response.json").read_text())


class ExplodingCatalog:
    """MusicBrainz, which must remain untouched."""

    def __init__(self) -> None:
        self.asked = 0

    async def search(self, query: str, limit: int) -> list[dict[str, Any]]:
        self.asked += 1
        raise AssertionError("подсказка не имеет права спрашивать чужой каталог")


def test_release_data_is_shared_with_the_search_tests() -> None:
    """Input guard: suggestions rely on the same releases as search."""
    assert RELEASES and LASTFM


async def test_suggest_answers_from_the_own_base_only(filled: str) -> None:  # noqa: F811
    port = ExplodingCatalog()
    with TestClient(create_app(database_url=filled, catalog=[], catalog_port=port)) as http:
        payload = http.get("/v1/suggest", params={"q": "lin"}).json()
    assert list(payload) == list(CONTRACT)
    assert payload["suggestions"][0] == "Linkin Park"
    assert all(isinstance(item, str) for item in payload["suggestions"])
    assert port.asked == 0


async def test_suggest_finds_songs_too(filled: str) -> None:  # noqa: F811
    with TestClient(create_app(database_url=filled, catalog=[], catalog_port=None)) as http:
        payload = http.get("/v1/suggest", params={"q": "num"}).json()
    assert "Numb" in payload["suggestions"]


async def test_suggest_is_quiet_on_one_letter(filled: str) -> None:  # noqa: F811
    """A single letter is not yet typing: tens of thousands of names match it."""
    with TestClient(create_app(database_url=filled, catalog=[], catalog_port=None)) as http:
        assert http.get("/v1/suggest", params={"q": "l"}).json()["suggestions"] == []


async def test_suggest_needs_the_key(filled: str) -> None:  # noqa: F811
    """The new path is locked by default: whitelist is only `/v1/health`."""
    key = "suggest-key-" + "0" * 24
    app = create_app(database_url=filled, catalog=[], catalog_port=None, api_key=key)
    with TestClient(app) as http:
        assert http.get("/v1/suggest", params={"q": "lin"}).status_code == 401
        answer = http.get(
            "/v1/suggest", params={"q": "lin"}, headers={"x-apertonodo-key": key}
        )
    assert answer.status_code == 200
