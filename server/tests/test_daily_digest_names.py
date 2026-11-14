"""FT-872 (return 1): the slow list names the song, not the number, when the catalog knows it."""

from __future__ import annotations

import asyncio
from datetime import date

from app import daily_digest

ID_KNOWN = "9e60b81a-0000-4000-8000-000000000001"
ID_UNKNOWN = "9e60b81a-0000-4000-8000-000000000002"


def _digest() -> dict:
    row = {
        "source": "ext-a",
        "via": "link",
        "peers": 1,
        "speed_bps": 1,
        "first_byte_ms": 9000,
    }
    return {
        "day": date(2026, 10, 14),
        "plays": {
            "total": 2,
            "played": 2,
            "by_outcome": {"played": 2},
            "cache": daily_digest._group([]),
            "new": daily_digest._group([]),
            "slowest": [{**row, "track_id": ID_KNOWN}, {**row, "track_id": ID_UNKNOWN}],
        },
        "failures": {"total": 0, "by_kind": {}, "artists": []},
        "reports": [],
        "listens": {"total": 0, "people": 0},
    }


def test_known_track_is_shown_as_artist_dash_title_and_unknown_keeps_its_number(
    monkeypatch,
):
    async def fake_load(url: str, track_id: str):
        return {"artist": "Bach", "title": "Air"} if track_id == ID_KNOWN else None

    monkeypatch.setattr(daily_digest, "load_track", fake_load)
    digest = _digest()
    asyncio.run(daily_digest.name_slowest("postgres://x", digest))
    page = daily_digest.render(digest)
    assert "Bach — Air" in page
    assert ID_KNOWN not in page
    assert ID_UNKNOWN in page
