from __future__ import annotations

from app.canonical import canonical_key, collapse_tracks


def test_remaster_shares_canonical_key() -> None:
    original = canonical_key("Metallica", "Nothing Else Matters")
    remaster = canonical_key("Metallica", "Nothing Else Matters (Remastered 2021)")
    assert original == remaster


def test_collapse_drops_release_duplicates() -> None:
    tracks = [
        {
            "id": "1",
            "title": "Nothing Else Matters",
            "artist": "Metallica",
            "duration_ms": 388000,
            "artwork_url": "a",
        },
        {
            "id": "2",
            "title": "Nothing Else Matters (Remastered 2021)",
            "artist": "Metallica",
            "duration_ms": 388000,
            "artwork_url": "b",
        },
        {
            "id": "3",
            "title": "Duality",
            "artist": "Slipknot",
            "duration_ms": 252000,
            "artwork_url": "c",
        },
    ]
    collapsed = collapse_tracks(tracks)
    titles = sorted(track["title"] for track in collapsed)
    assert titles == ["Duality", "Nothing Else Matters"]
