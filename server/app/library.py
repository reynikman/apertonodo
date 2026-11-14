""" "My Music": favorites, custom playlists, listening history.

Boundaries maintained here:

- Only what the user created themselves. No "curated" service playlists here.
- GET and POST only: NPM in front of production server returns 405 on PUT, PATCH,
  and DELETE on its own, they never reach the server (verified 20.09 after deployment).
- Track ID does not appear in URL path: access log records full path, which would
  reveal what the user is listening to. Track ID is sent in request body; URL path
  contains only the playlist ID. Playlist name is also only in the body.
- Log lines from here report only database error types: no titles, playlist names,
  or IDs.
- History is strictly private: written by the app, read only by the app, server
  never exports it or shares it externally (docs/PLAN.md).
- Track identity is tracked via `canonical_key` (see migrations/010_library.sql).
  A track currently unplayable remains in the list with `playable: false`.
"""

from __future__ import annotations

import logging
import uuid
from datetime import UTC, datetime
from itertools import groupby
from typing import Any
from uuid import UUID

import asyncpg
from fastapi import APIRouter, FastAPI, Query, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from app import catalog, images
from app.canonical import canonical_key
from app.names import norm
from app.store import load_track, persist_tracks

logger = logging.getLogger("apertonodo")

# Counted listen threshold: 30s, as counted by Spotify and streaming
# industry reports — within this time the user decided to listen rather
# than skip. Songs under a minute count after half: otherwise short songs
# would never count.
LISTEN_MIN_MS = 30_000
# Listen reports longer than a day indicate clock or counting errors, not a listen (FT-639).
DAY_MS = 86_400_000
# How many history records are kept. 1000 tracks at ~4 min each is ~65 hours,
# at 2 hours a day that covers a month: "recently played" screen needs no more.
# The less data stored on the server, the less leaks if compromised.
HISTORY_MAX = 1000
NAME_MAX = 100
PAGE_MAX = 500
# Request limit for "new order" only, not playlist limit: playlists never exceed this.
PLAYLIST_MAX = 20_000

UNAVAILABLE = {"status": "library_unavailable"}
NOT_FOUND = {"status": "not_found"}
BAD_REQUEST = {"status": "bad_request"}

class Unavailable(Exception):
    """Database unavailable."""


class TrackIn(BaseModel):
    track_id: UUID


class FavoriteIn(BaseModel):
    track_id: UUID
    artwork_url: str | None = None


class TracksIn(BaseModel):
    track_ids: list[UUID] = Field(max_length=PAGE_MAX)


class OrderIn(BaseModel):
    track_ids: list[UUID] = Field(max_length=PLAYLIST_MAX)


class NameIn(BaseModel):
    name: str


class ListenIn(BaseModel):
    track_id: UUID
    listened_ms: int = Field(ge=0)
    artwork_url: str | None = None
    # D1: listen ID and start timestamp according to phone clock. Without ID —
    # history only, not forwarded externally (legacy client).
    listen_id: UUID | None = None
    started_at: datetime | None = None


def _cover_path(raw: str | None) -> str:
    """Only internal cover path is stored. External URLs are silently discarded."""
    if isinstance(raw, str) and raw.startswith("/v1/covers/"):
        return raw
    return ""


def listen_counts(listened_ms: int, duration_ms: int) -> bool:
    need = LISTEN_MIN_MS
    if duration_ms > 0:
        need = min(need, duration_ms // 2)
    return listened_ms >= need


def _name(raw: str) -> str | None:
    name = " ".join(raw.split())
    return name if 0 < len(name) <= NAME_MAX else None


class Library:
    def __init__(self, app: FastAPI, *, database_url: str | None) -> None:
        self.app = app
        self.database_url = database_url

    async def connect(self) -> asyncpg.Connection:
        if not self.database_url:
            raise Unavailable
        try:
            return await asyncpg.connect(self.database_url)
        except Exception as exc:  # noqa: BLE001
            logger.warning("library: database failed: %s", type(exc).__name__)
            raise Unavailable from None

    async def track(self, track_id: UUID) -> dict[str, Any] | None:
        """A track that the server displayed: fixture, memory, or `tracks` table.

        Only displayed tracks can be added — just like playback. Writing to `tracks`
        is repeated here: if database write failed during display, after restart
        Play would return 404 for it.
        """
        key = str(track_id)
        state = self.app.state
        if key in state.fixture_tracks:
            return dict(state.fixture_tracks[key])
        track = state.tracks.get(key)
        if track is None:
            return await load_track(str(self.database_url), key)
        await persist_tracks(str(self.database_url), [track])
        return dict(track)

    async def public(self, conn: asyncpg.Connection, rows: list[Any]) -> list[dict[str, Any]]:
        """Database rows -> tracks for app, each flagged with whether currently playable."""
        tracks = [
            {
                "id": str(row["track_id"]),
                "title": row["title"],
                "artist": row["artist"],
                "duration_ms": int(row["duration_ms"]),
                "artwork_url": (row["artwork_url"] if "artwork_url" in row else "") or "",
            }
            for row in rows
        ]
        for track, row in zip(tracks, rows, strict=True):
            if "missing" in row:
                track["missing"] = bool(row["missing"])
        without_cover = [
            track for track in tracks if not track["artwork_url"] and not track.get("missing", False)
        ]
        covers = await images.song_covers_of(conn, [track["id"] for track in without_cover])
        for track in without_cover:
            track["artwork_url"] = covers.get(track["id"], "")
        fixture = self.app.state.fixture_tracks
        # Single query per artist, matching catalog pages.
        pending = sorted(
            (norm(t["artist"]), i) for i, t in enumerate(tracks)
            if not t.get("missing", False) and t["id"] not in fixture
        )
        plays = {
            i: t["id"] in fixture and not t.get("missing", False)
            for i, t in enumerate(tracks)
        }
        # "Playable" follows catalog page rule (`catalog.playable`).
        for artist, group in groupby(pending, key=lambda item: item[0]):
            indexes = [i for _artist, i in group]
            titles = [tracks[i]["title"] for i in indexes]
            plays.update(zip(indexes, await catalog.playable(conn, artist, titles), strict=True))
        for i, track in enumerate(tracks):
            track["playable"] = plays[i]
        return tracks


router = APIRouter()


def _library(request: Request) -> Library:
    return request.app.state.library

def _owner(request: Request) -> UUID:
    return UUID(request.state.user["id"])


async def _open(request: Request) -> tuple[Library, asyncpg.Connection]:
    library = _library(request)
    return library, await library.connect()


def _unavailable() -> JSONResponse:
    return JSONResponse(UNAVAILABLE, status_code=503)


# --- favorites -------------------------------------------------------------


@router.get("/v1/favorites")
async def favorites(request: Request) -> Any:
    try:
        library, conn = await _open(request)
    except Unavailable:
        return _unavailable()
    try:
        rows = await conn.fetch(
            """
            SELECT f.track_id, f.title, f.artist, f.duration_ms,
                   coalesce(nullif(f.artwork_url, ''), latest.artwork_url, '') AS artwork_url
            FROM favorites f
            LEFT JOIN LATERAL (
                SELECT l.artwork_url FROM listens l
                WHERE l.user_id = f.user_id AND l.canonical_key = f.canonical_key
                  AND l.artwork_url <> ''
                ORDER BY l.played_at DESC, l.id DESC LIMIT 1
            ) latest ON true
            WHERE f.user_id = $1 ORDER BY f.added_at DESC, f.canonical_key
            """,
            _owner(request),
        )
        return {"tracks": await library.public(conn, rows)}
    finally:
        await conn.close()


@router.post("/v1/favorites")
async def favorite_add(request: Request, body: FavoriteIn) -> Any:
    try:
        library, conn = await _open(request)
    except Unavailable:
        return _unavailable()
    try:
        track = await library.track(body.track_id)
        if track is None:
            return JSONResponse(NOT_FOUND, status_code=404)
        user_id = _owner(request)
        # The same track already exists under another ID — keep existing ID;
        # only update artwork_url if it was previously missing.
        await conn.execute(
            """
            INSERT INTO favorites
                (user_id, canonical_key, track_id, title, artist, duration_ms, artwork_url)
            VALUES ($1, $2, $3, $4, $5, $6, $7)
            ON CONFLICT (user_id, canonical_key) DO UPDATE
            SET artwork_url = EXCLUDED.artwork_url
            WHERE favorites.artwork_url = '' AND EXCLUDED.artwork_url <> ''
            """,
            user_id,
            canonical_key(track["artist"], track["title"]),
            body.track_id,
            track["title"],
            track["artist"],
            int(track.get("duration_ms") or 0),
            _cover_path(body.artwork_url),
        )
        return {"status": "ok"}
    finally:
        await conn.close()


async def _keys(library: Library, conn: asyncpg.Connection, track_ids: list[UUID]) -> dict[str, str]:
    """id -> canonical_key for tracks known to the server."""
    keys: dict[str, str] = {}
    fixture = library.app.state.fixture_tracks
    memory = library.app.state.tracks
    rest = []
    for track_id in track_ids:
        track = fixture.get(str(track_id)) or memory.get(str(track_id))
        if track is None:
            rest.append(track_id)
        else:
            keys[str(track_id)] = canonical_key(track["artist"], track["title"])
    if rest:
        rows = await conn.fetch(
            "SELECT id, canonical_key FROM tracks WHERE id = ANY($1::uuid[])", rest
        )
        keys.update({str(row["id"]): row["canonical_key"] for row in rows})
    return keys


@router.post("/v1/favorites/remove")
async def favorite_remove(request: Request, body: TrackIn) -> Any:
    try:
        library, conn = await _open(request)
    except Unavailable:
        return _unavailable()
    try:
        keys = await _keys(library, conn, [body.track_id])
        await conn.execute(
            "DELETE FROM favorites WHERE user_id = $1 AND (track_id = $2 OR canonical_key = $3)",
            _owner(request),
            body.track_id,
            keys.get(str(body.track_id), ""),
        )
        return {"status": "ok"}
    finally:
        await conn.close()


@router.post("/v1/favorites/contains")
async def favorite_contains(request: Request, body: TracksIn) -> Any:
    """Which of the displayed tracks are already in favorites — for heart icons in UI.

    Cannot compare IDs on the phone: the same track from search and from
    album page has different IDs.
    """
    try:
        library, conn = await _open(request)
    except Unavailable:
        return _unavailable()
    try:
        keys = await _keys(library, conn, body.track_ids)
        rows = await conn.fetch(
            "SELECT track_id, canonical_key FROM favorites"
            " WHERE user_id = $1 AND (canonical_key = ANY($2::text[]) OR track_id = ANY($3::uuid[]))",
            _owner(request),
            list(keys.values()),
            body.track_ids,
        )
        liked_keys = {row["canonical_key"] for row in rows}
        liked_ids = {str(row["track_id"]) for row in rows}
        hits = [
            str(track_id)
            for track_id in body.track_ids
            if str(track_id) in liked_ids or keys.get(str(track_id)) in liked_keys
        ]
        return {"track_ids": hits}
    finally:
        await conn.close()


# --- custom playlists ------------------------------------------------------


async def _playlist(conn: asyncpg.Connection, playlist_id: UUID, owner: UUID) -> Any:
    return await conn.fetchrow(
        "SELECT id, name FROM playlists WHERE id = $1 AND user_id = $2", playlist_id, owner
    )


async def append_items(
    conn: asyncpg.Connection, playlist_id: UUID, items: list[dict[str, Any]]
) -> int:
    """Append import items in a single query. Owner is validated by caller."""
    rows: list[tuple[str, UUID, str, str, int, str, bool]] = []
    seen: set[str] = set()
    for item in items:
        key = canonical_key(item["artist"], item["title"])
        if key in seen:
            continue
        seen.add(key)
        track_id = item["track_id"]
        missing = track_id is None
        rows.append((
            key,
            uuid.uuid4() if missing else UUID(str(track_id)),
            item["title"],
            item["artist"],
            int(item.get("duration_ms") or 0),
            "" if missing else _cover_path(item.get("artwork_url")),
            missing,
        ))
    if not rows:
        return 0
    done = await conn.execute(
        """
        INSERT INTO playlist_items
            (playlist_id, canonical_key, position, track_id, title, artist,
             duration_ms, artwork_url, missing)
        SELECT $1, batch.canonical_key,
               coalesce((SELECT max(position) + 1 FROM playlist_items WHERE playlist_id = $1), 0)
                 + row_number() OVER (ORDER BY batch.ord) - 1,
               batch.track_id, batch.title, batch.artist, batch.duration_ms,
               batch.artwork_url, batch.missing
        FROM unnest($2::text[], $3::uuid[], $4::text[], $5::text[],
                    $6::integer[], $7::text[], $8::boolean[])
             WITH ORDINALITY AS batch(canonical_key, track_id, title, artist,
                                      duration_ms, artwork_url, missing, ord)
        WHERE NOT EXISTS (
            SELECT 1 FROM playlist_items i
            WHERE i.playlist_id = $1 AND i.canonical_key = batch.canonical_key
        )
        ON CONFLICT (playlist_id, canonical_key) DO NOTHING
        """,
        playlist_id,
        *zip(*rows, strict=True),
    )
    return int(done.rsplit(" ", 1)[1])


@router.get("/v1/playlists")
async def playlists(request: Request) -> Any:
    try:
        _lib, conn = await _open(request)
    except Unavailable:
        return _unavailable()
    try:
        rows = await conn.fetch(
            """
            SELECT p.id, p.name, count(i.canonical_key) AS tracks
            FROM playlists p LEFT JOIN playlist_items i ON i.playlist_id = p.id
            WHERE p.user_id = $1 GROUP BY p.id ORDER BY p.created_at, p.id
            """,
            _owner(request),
        )
        return {
            "playlists": [
                {"id": str(row["id"]), "name": row["name"], "tracks": int(row["tracks"])}
                for row in rows
            ]
        }
    finally:
        await conn.close()


@router.post("/v1/playlists", status_code=201)
async def playlist_create(request: Request, body: NameIn) -> Any:
    name = _name(body.name)
    if name is None:
        return JSONResponse(BAD_REQUEST, status_code=422)
    try:
        _lib, conn = await _open(request)
    except Unavailable:
        return _unavailable()
    try:
        playlist_id = uuid.uuid4()
        user_id = _owner(request)
        await conn.execute(
            "INSERT INTO playlists (id, name, user_id) VALUES ($1, $2, $3)",
            playlist_id,
            name,
            user_id,
        )
        return {"id": str(playlist_id), "name": name, "tracks": 0}
    finally:
        await conn.close()


@router.get("/v1/playlists/{playlist_id}")
async def playlist_content(request: Request, playlist_id: UUID) -> Any:
    try:
        library, conn = await _open(request)
    except Unavailable:
        return _unavailable()
    try:
        found = await _playlist(conn, playlist_id, _owner(request))
        if found is None:
            return JSONResponse(NOT_FOUND, status_code=404)
        rows = await conn.fetch(
            """
            SELECT i.track_id, i.title, i.artist, i.duration_ms, i.missing,
                   CASE WHEN i.missing THEN ''
                        ELSE coalesce(nullif(i.artwork_url, ''), latest.artwork_url, '') END AS artwork_url
            FROM playlist_items i JOIN playlists p ON p.id = i.playlist_id
            LEFT JOIN LATERAL (
                SELECT l.artwork_url FROM listens l
                WHERE l.user_id = p.user_id AND l.canonical_key = i.canonical_key
                  AND l.artwork_url <> ''
                ORDER BY l.played_at DESC, l.id DESC LIMIT 1
            ) latest ON NOT i.missing
            WHERE p.id = $1 AND p.user_id = $2 ORDER BY i.position, i.canonical_key
            """,
            playlist_id,
            _owner(request),
        )
        return {
            "id": str(found["id"]),
            "name": found["name"],
            "tracks": await library.public(conn, rows),
        }
    finally:
        await conn.close()


@router.post("/v1/playlists/{playlist_id}/rename")
async def playlist_rename(request: Request, playlist_id: UUID, body: NameIn) -> Any:
    name = _name(body.name)
    if name is None:
        return JSONResponse(BAD_REQUEST, status_code=422)
    try:
        _lib, conn = await _open(request)
    except Unavailable:
        return _unavailable()
    try:
        done = await conn.execute(
            "UPDATE playlists SET name = $2 WHERE id = $1 AND user_id = $3",
            playlist_id, name, _owner(request),
        )
        if done.endswith(" 0"):
            return JSONResponse(NOT_FOUND, status_code=404)
        return {"status": "ok"}
    finally:
        await conn.close()


@router.post("/v1/playlists/{playlist_id}/delete")
async def playlist_delete(request: Request, playlist_id: UUID) -> Any:
    try:
        _lib, conn = await _open(request)
    except Unavailable:
        return _unavailable()
    try:
        done = await conn.execute(
            "DELETE FROM playlists WHERE id = $1 AND user_id = $2", playlist_id, _owner(request)
        )
        if done.endswith(" 0"):
            return JSONResponse(NOT_FOUND, status_code=404)
        return {"status": "ok"}
    finally:
        await conn.close()


@router.post("/v1/playlists/{playlist_id}/tracks")
async def playlist_add(request: Request, playlist_id: UUID, body: FavoriteIn) -> Any:
    """Track appended to end or replaces a missing row. True duplicate is not moved."""
    try:
        library, conn = await _open(request)
    except Unavailable:
        return _unavailable()
    try:
        if await _playlist(conn, playlist_id, _owner(request)) is None:
            return JSONResponse(NOT_FOUND, status_code=404)
        track = await library.track(body.track_id)
        if track is None:
            return JSONResponse(NOT_FOUND, status_code=404)
        await conn.execute(
            """
            INSERT INTO playlist_items
                (playlist_id, canonical_key, position, track_id, title, artist, duration_ms, artwork_url)
            SELECT p.id, $2,
                   coalesce((SELECT max(position) + 1 FROM playlist_items i WHERE i.playlist_id = p.id), 0),
                   $3, $4, $5, $6, $8 FROM playlists p WHERE p.id = $1 AND p.user_id = $7
            ON CONFLICT (playlist_id, canonical_key) DO UPDATE
            SET track_id = CASE WHEN playlist_items.missing THEN EXCLUDED.track_id ELSE playlist_items.track_id END,
                title = CASE WHEN playlist_items.missing THEN EXCLUDED.title ELSE playlist_items.title END,
                artist = CASE WHEN playlist_items.missing THEN EXCLUDED.artist ELSE playlist_items.artist END,
                duration_ms = CASE WHEN playlist_items.missing THEN EXCLUDED.duration_ms ELSE playlist_items.duration_ms END,
                artwork_url = EXCLUDED.artwork_url,
                missing = false
            WHERE playlist_items.missing
               OR (playlist_items.artwork_url = '' AND EXCLUDED.artwork_url <> '')
            """,
            playlist_id,
            canonical_key(track["artist"], track["title"]),
            body.track_id,
            track["title"],
            track["artist"],
            int(track.get("duration_ms") or 0),
            _owner(request),
            _cover_path(body.artwork_url),
        )
        return {"status": "ok"}
    finally:
        await conn.close()


@router.post("/v1/playlists/{playlist_id}/tracks/remove")
async def playlist_remove(request: Request, playlist_id: UUID, body: TrackIn) -> Any:
    try:
        library, conn = await _open(request)
    except Unavailable:
        return _unavailable()
    try:
        if await _playlist(conn, playlist_id, _owner(request)) is None:
            return JSONResponse(NOT_FOUND, status_code=404)
        keys = await _keys(library, conn, [body.track_id])
        await conn.execute(
            "DELETE FROM playlist_items i USING playlists p WHERE i.playlist_id = p.id"
            " AND p.id = $1 AND p.user_id = $4"
            " AND (i.track_id = $2 OR i.canonical_key = $3)",
            playlist_id,
            body.track_id,
            keys.get(str(body.track_id), ""),
            _owner(request),
        )
        return {"status": "ok"}
    finally:
        await conn.close()


@router.post("/v1/playlists/{playlist_id}/order")
async def playlist_order(request: Request, playlist_id: UUID, body: OrderIn) -> Any:
    """Entire new order: identical tracks (IDs from playlist items), exactly once each.

    Entire order rather than "move one": repeating the same request breaks
    nothing, while an outdated UI receives 409 instead of silent shuffle.
    """
    try:
        _lib, conn = await _open(request)
    except Unavailable:
        return _unavailable()
    try:
        async with conn.transaction():
            if await _playlist(conn, playlist_id, _owner(request)) is None:
                return JSONResponse(NOT_FOUND, status_code=404)
            rows = await conn.fetch(
                "SELECT i.track_id FROM playlist_items i JOIN playlists p ON p.id = i.playlist_id"
                " WHERE p.id = $1 AND p.user_id = $2 FOR UPDATE OF i",
                playlist_id,
                _owner(request),
            )
            current = sorted(str(row["track_id"]) for row in rows)
            wanted = [str(track_id) for track_id in body.track_ids]
            if sorted(wanted) != current:
                return JSONResponse({"status": "conflict"}, status_code=409)
            await conn.executemany(
                "UPDATE playlist_items i SET position = $3 FROM playlists p"
                " WHERE i.playlist_id = p.id AND p.id = $1 AND p.user_id = $4 AND i.track_id = $2",
                [(playlist_id, UUID(track_id), n, _owner(request)) for n, track_id in enumerate(wanted)],
            )
        return {"status": "ok"}
    finally:
        await conn.close()


# --- history ---------------------------------------------------------------


@router.post("/v1/history")
async def history_add(request: Request, body: ListenIn) -> Any:
    """Client reports actual playback duration; server verifies and records.

    Consecutive repeat of same track updates timestamp of existing record.
    Entries older than HISTORY_MAX are purged.
    """
    try:
        library, conn = await _open(request)
    except Unavailable:
        return _unavailable()
    try:
        track = await library.track(body.track_id)
        if track is None:
            return JSONResponse(NOT_FOUND, status_code=404)
        duration = min(int(track.get("duration_ms") or 0), DAY_MS)
        # Recording pause (FT-630): imported here — history_control imports Library itself.
        from app.history_control import history_paused
        from app.play_reports import report

        paused = await history_paused(conn, _owner(request))
        if body.listen_id is not None:
            # Custom threshold for external services (D1 item 5): reports before history threshold.
            await report(
                conn,
                _owner(request),
                listen_id=body.listen_id,
                track_id=str(body.track_id),
                started_at=body.started_at or datetime.now(UTC),
                listened_ms=min(body.listened_ms, DAY_MS),
                duration_ms=duration,
                paused=paused,
            )
        if paused or not listen_counts(body.listened_ms, duration):
            return {"recorded": False}
        key = canonical_key(track["artist"], track["title"])
        cover = _cover_path(body.artwork_url)
        async with conn.transaction():
            # One writer at a time: two concurrent requests for the same track
            # would otherwise both see "different last track" and insert twice.
            await conn.execute("LOCK TABLE listens IN SHARE ROW EXCLUSIVE MODE")
            last = await conn.fetchrow(
                "SELECT id, canonical_key FROM listens WHERE user_id = $1"
                " ORDER BY played_at DESC, id DESC LIMIT 1",
                _owner(request),
            )
            if last is not None and last["canonical_key"] == key:
                await conn.execute(
                    "UPDATE listens SET played_at = now(),"
                    " artwork_url = CASE WHEN $2 = '' THEN artwork_url ELSE $2 END"
                    " WHERE id = $1 AND user_id = $3",
                    last["id"],
                    cover,
                    _owner(request),
                )
            else:
                user_id = _owner(request)
                await conn.execute(
                    """
                    INSERT INTO listens
                        (user_id, canonical_key, track_id, title, artist, duration_ms, artwork_url)
                    VALUES ($1, $2, $3, $4, $5, $6, $7)
                    """,
                    user_id,
                    key,
                    body.track_id,
                    track["title"],
                    track["artist"],
                    duration,
                    cover,
                )
                await conn.execute(
                    """
                    DELETE FROM listens WHERE user_id = $1 AND id NOT IN (
                        SELECT id FROM listens WHERE user_id = $1
                        ORDER BY played_at DESC, id DESC LIMIT $2
                    )
                    """,
                    _owner(request),
                    HISTORY_MAX,
                )
        return {"recorded": True}
    finally:
        await conn.close()


@router.get("/v1/history")
async def history(
    request: Request,
    offset: int = Query(default=0, ge=0),
    limit: int = Query(default=100, ge=1, le=PAGE_MAX),
) -> Any:
    try:
        library, conn = await _open(request)
    except Unavailable:
        return _unavailable()
    try:
        rows = await conn.fetch(
            "SELECT * FROM listens WHERE user_id = $1"
            " ORDER BY played_at DESC, id DESC OFFSET $2 LIMIT $3",
            _owner(request),
            offset,
            limit,
        )
        tracks = await library.public(conn, rows)
        pages = getattr(request.app.state, "catalog_pages", None)
        names = [track["artist"] for track in tracks]
        photos = await pages.listed(conn, names) if pages is not None else []
        fixture = library.app.state.fixture_tracks
        for i, (track, row) in enumerate(zip(tracks, rows, strict=True)):
            track["played_at"] = row["played_at"].isoformat()
            track["artist_photo"] = photos[i]["photo"] if i < len(photos) else None
            stored = fixture.get(track["id"])
            if stored and stored.get("test_tone"):
                track["test_tone"] = True
        total = await conn.fetchval("SELECT count(*) FROM listens WHERE user_id = $1", _owner(request))
        return {"tracks": tracks, "total": int(total)}
    finally:
        await conn.close()


def install_library(app: FastAPI, **kwargs: Any) -> None:
    """Attach "My Music" to the application. One line in main.py."""
    app.state.library = Library(app, **kwargs)
    app.include_router(router)
