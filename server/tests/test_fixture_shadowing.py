"""Real songs are not shadowed by test tones.

On September 18 the owner played "Nothing Else Matters" and heard "ultrasound" —
precisely the audio used for phone verification runs. Indeed: with a live catalog
the fixture "Metallica — Nothing Else Matters" appeared first in the results,
`collapse_tracks` dropped the real MusicBrainz recording, and on Play the local
index served ninety seconds of generated tone. For "Duality" — four
seconds. The second path for the same substitution was in the resolver: the fixture source
matched the track by name and duration, and the real recording with the same
title also received the tone.

What is proven here: with a live catalog, the real recording appears in search results, and a tone
is never matched to it either via search results or via resolver. Tones remain for
phone checks, but under their own names that match no song.
And the contour without live catalog is unchanged: fixture tracks are found there as before.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from fastapi.testclient import TestClient

from app.main import create_app

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "contracts" / "fixtures"
CATALOG = json.loads((FIXTURES / "catalog.json").read_text())["tracks"]
REAL_NEM = {
    "id": "5b11f4ce-a62d-471e-81fc-a69a8278c7da",
    "title": "Nothing Else Matters",
    "artist": "Metallica",
    "duration_ms": 388000,
    "artwork_url": "",
}


class _Catalog:
    def __init__(self, tracks: list[dict[str, Any]]) -> None:
        self.tracks = tracks

    async def search(self, query: str, limit: int) -> list[dict[str, Any]]:
        return [dict(track) for track in self.tracks]


def test_live_search_shows_the_real_song_and_no_fixture_namesake() -> None:
    app = create_app(catalog=CATALOG, catalog_port=_Catalog([REAL_NEM]))
    with TestClient(app) as client:
        tracks = client.get(
            "/v1/search", params={"q": "metallica nothing else matters"}
        ).json()["tracks"]

    assert [track["id"] for track in tracks] == [REAL_NEM["id"]]


def test_the_real_song_never_gets_the_tone(tmp_path: Path) -> None:
    """Even when there are no sources at all — reject, but never serve a tone."""
    app = create_app(catalog=CATALOG, catalog_port=_Catalog([REAL_NEM]))
    with TestClient(app) as client:
        client.get("/v1/search", params={"q": "metallica nothing else matters"})
        played = client.post("/v1/playback", json={"track_id": REAL_NEM["id"]})

    assert played.status_code == 409, played.text
    assert app.state.sessions == {}


def test_tone_names_collide_with_no_catalog_song() -> None:
    """Tone name collides with no fixture song, and therefore with no real one."""
    tones = {(t["artist"], t["title"]) for t in CATALOG if t.get("test_tone")}
    songs = {(t["artist"], t["title"]) for t in CATALOG if not t.get("test_tone")}
    assert tones == {("Flowtune", "Test Tone Long"), ("Flowtune", "Test Tone Short")}
    assert not {title for _, title in tones} & {title for _, title in songs}


def test_fixture_contour_without_live_catalog_is_unchanged() -> None:
    app = create_app(catalog=CATALOG)
    with TestClient(app) as client:
        tracks = client.get("/v1/search", params={"q": "nothing else matters"}).json()["tracks"]

    assert tracks[0]["id"] == "11111111-1111-1111-1111-111111111111"
