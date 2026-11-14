from __future__ import annotations

import json
from pathlib import Path

from fastapi.testclient import TestClient

from app.main import create_app

ROOT = Path(__file__).resolve().parents[2]
CATALOG = json.loads((ROOT / "contracts" / "fixtures" / "catalog.json").read_text())
SEARCH_CONTRACT = json.loads((ROOT / "contracts" / "search.response.json").read_text())
FORBIDDEN = {"info_hash", "magnet", "torrent", "file_index", "seeds"}


def test_search_collapses_remasters_and_matches_contract_shape() -> None:
    app = create_app(database_url=None, catalog=CATALOG["tracks"])
    client = TestClient(app)
    response = client.get("/v1/search", params={"q": "nothing else matters"})
    assert response.status_code == 200
    payload = response.json()
    # Since Phase J the response has two lists: catalog artists and tracks.
    # Without a database there are no artists, but the key must exist — otherwise the phone would read
    # `null` and crash on the very first search.
    assert list(payload) == list(SEARCH_CONTRACT)
    assert payload["artists"] == []
    assert len(payload["tracks"]) == 1
    track = payload["tracks"][0]
    assert set(track) == set(SEARCH_CONTRACT["tracks"][0])
    assert track["title"] == "Nothing Else Matters"
    assert track["artist"] == "Metallica"
    # Fixture is on disk and always playable.
    assert track["playable"] is True
    assert FORBIDDEN.isdisjoint(track)


def test_search_ignores_stopwords_and_matches_transliteration() -> None:
    catalog = [
        {
            "id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "title": "Группа крови",
            "artist": "Кино",
            "duration_ms": 240000,
            "artwork_url": "https://coverartarchive.org/release/fixture/front",
        }
    ]
    client = TestClient(create_app(database_url=None, catalog=catalog))
    payload = client.get("/v1/search", params={"q": "песня kino gruppa krovi"}).json()
    assert len(payload["tracks"]) == 1
    assert payload["tracks"][0]["title"] == "Группа крови"


def test_search_does_not_log_query(caplog) -> None:
    app = create_app(database_url=None, catalog=CATALOG["tracks"])
    client = TestClient(app)
    with caplog.at_level("INFO"):
        client.get("/v1/search", params={"q": "secret-query-xyz"})
    app_logs = " ".join(
        record.getMessage() for record in caplog.records if record.name.startswith("apertonodo")
    )
    assert "secret-query-xyz" not in app_logs
