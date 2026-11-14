from __future__ import annotations

import hashlib
import json
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any

import asyncpg

from app.canonical import canonical_key


def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


async def persist_tracks(database_url: str, tracks: list[dict[str, Any]]) -> None:
    """Store displayed tracks in the database.

    Only tracks previously displayed can be played, but displayed tracks used to live only
    in process memory. Deployments restart the process — and every track from an open
    search result returned 404 on Play, where "retry" did not help: only a new
    search did. Table `tracks` existed for this since the first migration, but was
    previously unused.
    """
    rows = [
        (
            uuid.UUID(str(track["id"])),
            str(track["title"]),
            str(track["artist"]),
            int(track.get("duration_ms") or 0),
            str(track.get("artwork_url") or ""),
            canonical_key(str(track["artist"]), str(track["title"])),
        )
        for track in tracks
    ]
    if not rows:
        return
    conn = await asyncpg.connect(database_url)
    try:
        await conn.executemany(
            """
            INSERT INTO tracks (id, title, artist, duration_ms, artwork_url, canonical_key)
            VALUES ($1, $2, $3, $4, $5, $6)
            ON CONFLICT (id) DO UPDATE SET
                title = EXCLUDED.title,
                artist = EXCLUDED.artist,
                duration_ms = EXCLUDED.duration_ms,
                artwork_url = EXCLUDED.artwork_url,
                canonical_key = EXCLUDED.canonical_key
            """,
            rows,
        )
    finally:
        await conn.close()


async def load_track(database_url: str, track_id: str) -> dict[str, Any] | None:
    conn = await asyncpg.connect(database_url)
    try:
        row = await conn.fetchrow(
            "SELECT id, title, artist, duration_ms, artwork_url FROM tracks WHERE id = $1",
            uuid.UUID(str(track_id)),
        )
    finally:
        await conn.close()
    if row is None:
        return None
    return {
        "id": str(row["id"]),
        "title": row["title"],
        "artist": row["artist"],
        "duration_ms": int(row["duration_ms"]),
        "artwork_url": row["artwork_url"] or "",
    }


async def purge_sessions(database_url: str) -> None:
    """Purge sessions whose tokens expired more than 24 hours ago."""
    conn = await asyncpg.connect(database_url)
    try:
        await conn.execute(
            "DELETE FROM playback_sessions WHERE expires_at < now() - interval '1 day'"
        )
    finally:
        await conn.close()


async def persist_session(
    database_url: str,
    *,
    user_id: str | uuid.UUID | None = None,
    token: str,
    track_id: str,
    candidate_id: str | None,
    state: str,
    expires_at: datetime | None = None,
    media_path: str = "",
    track: dict[str, Any] | None = None,
    asset: str | None = None,
) -> None:
    conn = await asyncpg.connect(database_url)
    try:
        if user_id is not None:
            resolved_user_id = uuid.UUID(str(user_id))
        else:
            from app.users import ensure_owner_id

            resolved_user_id = await ensure_owner_id(conn)
        await conn.execute(
            """
            INSERT INTO playback_sessions (
                token_hash, track_id, candidate_id, state, expires_at,
                media_path, track, user_id, asset
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
            ON CONFLICT (token_hash) DO UPDATE SET
                state = EXCLUDED.state,
                media_path = EXCLUDED.media_path,
                track = EXCLUDED.track,
                user_id = EXCLUDED.user_id,
                asset = EXCLUDED.asset
            """,
            token_hash(token),
            uuid.UUID(str(track_id)),
            uuid.UUID(candidate_id) if candidate_id else None,
            state,
            expires_at or datetime.now(timezone.utc) + timedelta(hours=1),
            media_path,
            json.dumps(track or {}),
            resolved_user_id,
            asset,
        )
    finally:
        await conn.close()


async def load_session(database_url: str, key: str) -> dict[str, Any] | None:
    """Restore session from DB following process restart.

    Sessions live in memory, and container restart terminated every issued
    token: user pressed Play, music was playing, deploy happened — and silence. DB
    persists mapping from token to extension playback details.
    """
    conn = await asyncpg.connect(database_url)
    try:
        row = await conn.fetchrow(
            """
            SELECT state, expires_at, media_path, track, user_id, asset
            FROM playback_sessions
            WHERE token_hash = $1
            """,
            key,
        )
    finally:
        await conn.close()
    if row is None:
        return None
    raw_track = row["track"]
    track = json.loads(raw_track) if isinstance(raw_track, str) else (raw_track or {})
    session: dict[str, Any] = {
        "state": row["state"],
        "track": track,
        "buffered_ms": 0,
        "media_path": row["media_path"] or "",
        "expires_at": row["expires_at"],
        "user_id": str(row["user_id"]) if row["user_id"] is not None else None,
    }
    if row["asset"]:
        session["asset"] = row["asset"]
    return session
