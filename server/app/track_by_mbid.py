"""Look up a MusicBrainz recording by its number in the local MusicBrainz copy."""

from __future__ import annotations

import uuid
from typing import Any

import asyncpg


async def load_recording(database_url: str, track_id: str) -> dict[str, Any] | None:
    """Return the track dict for a recording MBID, or None if it cannot be played.

    One primary-key lookup in `mb_recording`, joined to `mb_artist` for the name.
    A recording without an artist name is not playable, so it returns None.
    """
    try:
        mbid = uuid.UUID(str(track_id))
    except ValueError:
        return None
    conn = await asyncpg.connect(database_url)
    try:
        row = await conn.fetchrow(
            "SELECT r.mbid, r.title, r.length_ms, a.name"
            " FROM mb_recording r JOIN mb_artist a ON a.mbid = r.artist_mbid"
            " WHERE r.mbid = $1",
            mbid,
        )
    except asyncpg.UndefinedTableError:
        # No MusicBrainz copy on this server: an unknown number, not a fault.
        return None
    finally:
        await conn.close()
    if row is None:
        return None
    artist = (row["name"] or "").strip()
    if not artist:
        return None
    return {
        "id": str(row["mbid"]),
        "title": row["title"],
        "artist": row["name"],
        "duration_ms": int(row["length_ms"] or 0),
        "artwork_url": "",
    }
