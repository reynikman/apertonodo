"""FT-022: edition preference and legacy link compatibility.

The permanent song id is song_identity.song_id (uuid); song.id (the V3 row id)
is renumbered by every catalog rebuild. The `song_id: int` arguments are V3
row ids at call time, translated through song_identity.v3_song_id; everything
stored is keyed by the permanent uuid. Old favorites and playlist items keep
historical ids and canonical keys and resolve through song_alias.

resolve_edition returns exactly fallback/edition_id/version/quality: a
preference changes the edition, never the kind, and a missing requested_kind
is never substituted by another one. get_preference returns text ids because
its dict is JSON-logged as is.
"""

from __future__ import annotations

import uuid
from typing import Any

import asyncpg

from .owner import ensure_owner_id


async def _identity_uuid(conn: asyncpg.Connection, song_id: int) -> uuid.UUID | None:
    return await conn.fetchval("SELECT song_id FROM song_identity WHERE v3_song_id = $1", song_id)


async def _ensure_identity(conn: asyncpg.Connection, song_id: int) -> uuid.UUID:
    found = await _identity_uuid(conn, song_id)
    if found is not None:
        return found
    from app.mbcopy import _assign_song_identities

    await _assign_song_identities(conn, only_song_id=song_id)
    found = await _identity_uuid(conn, song_id)
    if found is None:
        raise LookupError(f"song {song_id} is not in the catalog")
    return found


async def record_alias(
    conn: asyncpg.Connection, old_track_id: uuid.UUID | None = None,
    old_canonical_key: str | None = None, song_id: int | None = None,
) -> None:
    """Map one historical identifier to the permanent id of the V3 song."""
    if old_track_id is None and old_canonical_key is None:
        raise ValueError("old_track_id or old_canonical_key is required")
    if song_id is None:
        raise ValueError("song_id is required")
    async with conn.transaction():
        identity = await _ensure_identity(conn, song_id)
        for column, value in (("old_track_id", old_track_id), ("old_canonical_key", old_canonical_key)):
            if value is None:
                continue
            await conn.execute(
                f"INSERT INTO song_alias ({column}, song_id) VALUES ($1, $2) "
                f"ON CONFLICT ({column}) WHERE {column} IS NOT NULL "
                "DO UPDATE SET song_id = EXCLUDED.song_id",
                value, identity,
            )


async def resolve_alias(
    conn: asyncpg.Connection, old_track_id: uuid.UUID | None = None,
    old_canonical_key: str | None = None,
) -> int:
    """Current V3 row id of the song the historical identifier points at."""
    if old_track_id is None and old_canonical_key is None:
        raise ValueError("old_track_id or old_canonical_key is required")
    v3_song_id = await conn.fetchval(
        """
        SELECT identity.v3_song_id FROM song_alias alias
        JOIN song_identity identity ON identity.song_id = alias.song_id
        WHERE alias.old_track_id = $1 OR alias.old_canonical_key = $2
        ORDER BY (alias.old_track_id = $1) DESC NULLS LAST, identity.song_id LIMIT 1
        """,
        old_track_id, old_canonical_key,
    )
    if v3_song_id is None:
        raise LookupError("alias does not resolve to a current song")
    return int(v3_song_id)


async def can_play_alias(
    conn: asyncpg.Connection, old_track_id: uuid.UUID | None = None,
    old_canonical_key: str | None = None,
) -> bool:
    """The alias resolves and the song has a recording on some edition."""
    try:
        v3_song_id = await resolve_alias(conn, old_track_id, old_canonical_key)
    except LookupError:
        return False
    playable = await conn.fetchval(
        """
        SELECT EXISTS (SELECT 1 FROM song_version version
            JOIN mb_track track ON track.recording_mbid = version.recording_mbid
            JOIN mb_medium medium ON medium.id = track.medium_id
            WHERE version.song_id = $1)
        """,
        v3_song_id,
    )
    return bool(playable)


async def _edition_recording(
    conn: asyncpg.Connection, song_id: int, edition_id: uuid.UUID, kind: str | None = None
) -> tuple[Any, Any] | None:
    """(version, quality) of this song's recording on the edition, if any."""
    row = await conn.fetchrow(
        """
        SELECT version.kind AS version, lower(medium.format) AS quality
        FROM song_version version
        JOIN mb_track track ON track.recording_mbid = version.recording_mbid
        JOIN mb_medium medium ON medium.id = track.medium_id
        WHERE version.song_id = $1 AND medium.release_mbid = $2
          AND ($3::text IS NULL OR version.kind = $3)
        ORDER BY (version.recording_mbid =
                 (SELECT original_recording_mbid FROM song WHERE id = $1)) DESC NULLS LAST,
                 version.recording_mbid, medium.id LIMIT 1
        """,
        song_id, edition_id, kind,
    )
    return None if row is None else (row["version"], row["quality"])


async def get_preference(
    conn: asyncpg.Connection, song_id: int,
    album_id: uuid.UUID | None = None, user_id: uuid.UUID | None = None,
) -> dict | None:
    """Stored preference keyed by the permanent song id, so a rebuild keeps it."""
    # No account given: the owner's preferences (users.id since the P3 migration).
    if user_id is None:
        user_id = await ensure_owner_id(conn)
    identity = await _identity_uuid(conn, song_id)
    if identity is None:
        return None
    row = await conn.fetchrow(
        """
        SELECT preference.song_id, preference.album_id, preference.edition_id,
               release.title AS edition
        FROM edition_preference preference
        JOIN mb_release release ON release.mbid = preference.edition_id
        WHERE preference.user_id = $1 AND preference.song_id = $2
          AND preference.album_id IS NOT DISTINCT FROM $3
        """,
        user_id, identity, album_id,
    )
    if row is None:
        return None
    found = await _edition_recording(conn, song_id, row["edition_id"])
    # Text ids on purpose: this dict is JSON-logged and uuid.UUID objects do
    # not survive json.dumps. The value is still the permanent song id, so the
    # dict is equal before and after a catalog rebuild.
    return {
        "song_id": str(row["song_id"]),
        "album_id": str(row["album_id"]) if row["album_id"] is not None else None,
        "edition_id": str(row["edition_id"]),
        "version": found[0] if found else None,
        "edition": row["edition"],
    }


async def set_preference(
    conn: asyncpg.Connection, song_id: int, edition_id: uuid.UUID,
    album_id: uuid.UUID | None = None, user_id: uuid.UUID | None = None,
) -> dict:
    """Store the preferred edition of the song; returns the get_preference dict."""
    if user_id is None:
        user_id = await ensure_owner_id(conn)
    async with conn.transaction():
        identity = await _ensure_identity(conn, song_id)
        album = await conn.fetchval("SELECT group_mbid FROM mb_release WHERE mbid = $1", edition_id)
        if album is None or (album_id is not None and album != album_id):
            raise ValueError("edition does not belong to the given album")
        if await _edition_recording(conn, song_id, edition_id) is None:
            raise ValueError("edition does not carry a recording of this song")
        await conn.execute(
            """
            INSERT INTO edition_preference (user_id, song_id, album_id, edition_id)
            VALUES ($1, $2, $3, $4)
            ON CONFLICT (user_id, song_id, album_id)
            DO UPDATE SET edition_id = EXCLUDED.edition_id
            """,
            user_id, identity, album_id, edition_id,
        )
    stored = await get_preference(conn, song_id=song_id, album_id=album_id, user_id=user_id)
    assert stored is not None
    return stored


async def _fallback_edition(
    conn: asyncpg.Connection, song_id: int, original_recording_mbid: uuid.UUID | None,
    available_editions: set[uuid.UUID] | None, requested_kind: str,
) -> dict:
    rows = await conn.fetch(
        """
        SELECT medium.release_mbid AS edition_id,
               COALESCE(bool_or(track.recording_mbid = $2), false) AS carries_original,
               min(COALESCE(NULLIF(release.date, ''), NULLIF(album.first_date, ''))) AS released
        FROM song_version version
        JOIN mb_track track ON track.recording_mbid = version.recording_mbid
        JOIN mb_medium medium ON medium.id = track.medium_id
        JOIN mb_release release ON release.mbid = medium.release_mbid
        LEFT JOIN mb_release_group album ON album.mbid = release.group_mbid
        WHERE version.song_id = $1 AND version.kind = $3
        GROUP BY medium.release_mbid
        """,
        song_id, original_recording_mbid, requested_kind,
    )
    candidates = [r for r in rows if available_editions is None or r["edition_id"] in available_editions]
    if not candidates:
        raise LookupError(f"no {requested_kind} edition of the song is available")
    candidates.sort(key=lambda r: (not r["carries_original"], r["released"] is None, r["released"] or "", r["edition_id"]))
    found = await _edition_recording(conn, song_id, candidates[0]["edition_id"], requested_kind)
    if found is None:
        raise LookupError(f"no {requested_kind} recording of the song on the edition")
    return {"fallback": True, "edition_id": candidates[0]["edition_id"], "version": found[0], "quality": found[1]}


async def resolve_edition(
    conn: asyncpg.Connection, song_id: int, album_id: uuid.UUID | None = None, user_id: uuid.UUID | None = None,
    preferred_edition_id: uuid.UUID | None = None, available_editions: set[uuid.UUID] | None = None,
    requested_kind: str = "original",
) -> dict:
    """Edition to play: the preferred one, or an explicit fallback.

    The preferred edition (argument, else the stored preference) plays when it
    is available and carries the song, reporting the real kind of its
    recording. Otherwise the fallback picks among available editions carrying
    a recording of requested_kind: the one with song.original_recording_mbid,
    then the earliest release date, then edition id. No available edition of
    requested_kind raises LookupError — never another kind in its place.
    """
    row = await conn.fetchrow("SELECT original_recording_mbid FROM song WHERE id = $1", song_id)
    if row is None:
        raise LookupError("song is not in the catalog")
    preferred = preferred_edition_id
    if preferred is None:
        stored = await get_preference(conn, song_id=song_id, album_id=album_id, user_id=user_id)
        if stored is not None:
            # stored ids are text for JSON clients; compare as uuid here
            preferred = uuid.UUID(stored["edition_id"])
    if preferred is not None and (available_editions is None or preferred in available_editions):
        found = await _edition_recording(conn, song_id, preferred)
        if found is not None:
            return {"fallback": False, "edition_id": preferred, "version": found[0], "quality": found[1]}
    return await _fallback_edition(conn, song_id, row["original_recording_mbid"], available_editions, requested_kind)
