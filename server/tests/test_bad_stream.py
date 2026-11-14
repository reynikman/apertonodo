"""Phone could not play stream — report `POST /v1/playback/failed` (FT-536).

Retry "to another release" is now decided by the extension (`test_extension_play.py`).
Here remains the core contract itself: unknown token is 404.
"""

from __future__ import annotations

import uuid

from fastapi.testclient import TestClient

from app.main import create_app

SONG = {
    "id": str(uuid.uuid4()),
    "title": "Disasterpiece",
    "artist": "Slipknot",
    "duration_ms": 1,
    "artwork_url": "",
}


def test_unknown_token_is_404() -> None:
    with TestClient(create_app(catalog=[SONG])) as client:
        response = client.post("/v1/playback/failed", json={"token": "nope"})
    assert response.status_code == 404
