"""Client catalog API: genres, countries, artists A–Z, artist, album, cover art.

Boundaries enforced here:

- Response bodies contain no words about releases. "Is playable" is the `playable` field, order
  in genre is by popularity, raw counts are never exposed.
- Only core functions: genre, letter, artist, album. No curated playlists from the service.
- URL paths contain only IDs (MusicBrainz UUID, genre code). Artist name goes into
  query string: access log strips it (`app/access_log.py`), while writing the path
  in full. Log lines from here never contain names or titles.
- Artist and album pages read the published local MusicBrainz copy
  (app/catalog_browse.py); without it 503 not_ready is returned.
- Cover art and artist photos — `app/images.py`: first Cover Art Archive,
  if not found — fallback cover from extensions. Images themselves are disk files, with only paths in the DB.
  The page does not wait: it enqueues everything it displayed, and returns what is already on disk.
"""

from __future__ import annotations

import asyncio
import logging
import time
from collections.abc import Callable
from typing import Any
from uuid import UUID

import asyncpg
from fastapi import APIRouter, FastAPI, Query, Request
from fastapi.responses import FileResponse, JSONResponse

from app import catalog, catalog_browse as browse, images, lastfm, mbcopy, failures
from app.catalog_genres import OUR_SLUGS
from app.names import norm
from app.store import persist_tracks

logger = logging.getLogger("apertonodo")

BROWSE_LIMIT_MAX = 500
# Catalog is rebuilt when robot updates popularity; check at most this often.
BUILD_CHECK_INTERVAL_S = 3600.0
PICTURE_PATH_CACHE_MAX = 50_000

UNAVAILABLE = {"status": "catalog_unavailable"}
NOT_FOUND = {"status": "not_found"}


class CatalogUnavailable(Exception):
    """No database or MusicBrainz did not respond, and no cached answer in own store."""


class Catalog:
    def __init__(
        self,
        app: FastAPI,
        *,
        database_url: str | None,
        remember: Callable[[dict[str, Any]], None],
        pictures: Any = None,
    ) -> None:
        self.app = app
        self.database_url = database_url
        self.remember = remember
        # Pictures (app/images.py). No catalog on disk — no pictures:
        # screen stays on letter squares, everything else works.
        self.pictures = pictures
        self.picture_paths: dict[tuple[str, UUID], str] = {}
        if pictures is not None:
            pictures.from_release = self.release_cover
        self.last_build_check = float("-inf")
        self.build_task: asyncio.Task[Any] | None = None

    async def connect(self) -> asyncpg.Connection:
        if not self.database_url:
            raise CatalogUnavailable
        try:
            return await asyncpg.connect(self.database_url)
        except Exception as exc:  # noqa: BLE001
            logger.warning("catalog: database failed: %s", type(exc).__name__)
            raise CatalogUnavailable from None

    # --- own list: genres and letters -----------------------------------

    def build_soon(self) -> None:
        """Rebuild catalog in background if popularity updated after build."""
        # The same catalog browsing wakes the Last.fm robot — but not the artist
        # page: opening it produces no requests to Last.fm.
        # And the pictures robot: it fetches popular covers ahead of time so
        # the genre grid opens with them ready.
        lastfm.wake(self.app)
        mbcopy.wake(self.app)
        if self.pictures is not None:
            self.pictures.soon()
        if time.monotonic() - self.last_build_check < BUILD_CHECK_INTERVAL_S:
            return
        self.last_build_check = time.monotonic()
        # In its own thread: build is a 17 s Python loop over a million rows, which
        # in the server event loop would freeze all requests, audio included.
        self.build_task = asyncio.get_running_loop().create_task(
            asyncio.to_thread(asyncio.run, self._build_if_stale())
        )

    async def _build_if_stale(self) -> None:
        extensions = getattr(self.app.state, "extensions", None)
        if not extensions:
            return  # without extensions there is nothing to build catalog from
        try:
            conn = await self.connect()
            try:
                stale = await catalog.needs_build_from_extensions(conn)
            finally:
                await conn.close()
            if stale:
                # Catalog from extension exports, rebuilt by age.
                summary = await catalog.build_from_extensions(str(self.database_url), dict(extensions.urls))
                logger.info("catalog: built from extensions: %s", summary.get("catalog", "fresh"))
        except Exception as exc:  # noqa: BLE001
            logger.warning("catalog: build failed: %s", type(exc).__name__)

    # --- pictures -------------------------------------------------------

    async def covers_soon(
        self, conn: asyncpg.Connection, artist: str, albums: list[tuple[str, str, bool]]
    ) -> None:
        """Request covers for all displayed albums at once.

        This is where "one at a time" is fixed. Previously exactly one
        background task was created and all subsequent requests were dropped until
        it finished: a grid of twenty albums filled up one cover per page opening.
        Now the whole grid is requested, and the queue (`app/images.py`)
        processes it at one request per second.

        The page waits for nothing: opening it now returns what is already cached.
        """
        if self.pictures is None or not albums:
            return
        skip = await images.tried(conn, [album_id for album_id, _title, _playable in albums])
        for album_id, title, playable in albums:
            if album_id not in skip:
                self.pictures.want(("cover", album_id, artist, title), playable=playable)

    async def photo_soon(self, conn: asyncpg.Connection, artist_key: str, mbid: str) -> None:
        """Request artist photo if not searched yet."""
        if self.pictures is None:
            return
        seen = await conn.fetchval(
            "SELECT 1 FROM artist_photos WHERE artist_key = $1 AND tried_at > now() - $2::interval",
            artist_key,
            images.RETRY,
        )
        if not seen:
            self.pictures.want(("photo", artist_key, mbid, ""))

    async def listed(self, conn: asyncpg.Connection, names: list[str]) -> list[dict[str, Any]]:
        """Artist list rows: name and photo if already stored locally.

        Single database query for the entire list. Never go external: no photo -> `null`,
        and displayed artists without a recent attempt are queued.
        """
        keys = [norm(name) for name in names]
        known: dict[str, Any] = {}
        if keys:
            rows = await conn.fetch(
                "SELECT artist_key, mbid, path, author, license, "
                "tried_at > now() - $2::interval AS recent "
                "FROM artist_photos WHERE artist_key = ANY($1::text[])",
                keys,
                images.RETRY,
            )
            known = {row["artist_key"]: row for row in rows}
        out: list[dict[str, Any]] = []
        for name in names:
            key = norm(name)
            row = known.get(key)
            photo = None
            if (
                row is not None
                and row["path"]
                and row["author"]
                and row["license"]
                and row["mbid"] is not None
            ):
                photo = f"/v1/photos/{row['mbid']}"
            out.append({"name": name, "photo": photo})
            if self.pictures is None:
                continue
            if row is not None and row["recent"]:
                continue
            mbid = str(row["mbid"]) if row is not None and row["mbid"] is not None else ""
            self.pictures.want(("photo", key, mbid, name))
        return out

    def release_cover(self, artist: str, title: str) -> bytes | None:
        """Fallback cover: from extensions (FT-769); absent without them."""
        extensions = getattr(self.app.state, "extensions", None)
        return extensions.cover(artist, title) if extensions else None


router = APIRouter()


def _catalog(request: Request) -> Catalog:
    return request.app.state.catalog_pages


@router.get("/v1/genres")
async def genres(request: Request, country: str = Query(default="")) -> Any:
    pages = _catalog(request)
    try:
        conn = await pages.connect()
    except CatalogUnavailable:
        return JSONResponse(UNAVAILABLE, status_code=503)
    try:
        if not await browse.is_published(conn):
            return JSONResponse({"status": "not_ready"}, status_code=503)
        lastfm.wake(request.app)
        return {"genres": await browse.get_genres(conn, country=country)}
    finally:
        await conn.close()


@router.get("/v1/countries")
async def countries(request: Request) -> Any:
    pages = _catalog(request)
    try:
        conn = await pages.connect()
    except CatalogUnavailable:
        return JSONResponse(UNAVAILABLE, status_code=503)
    try:
        if not await browse.is_published(conn):
            return JSONResponse({"status": "not_ready"}, status_code=503)
        return {"countries": await browse.get_countries(conn)}
    finally:
        await conn.close()


@router.get("/v1/letters")
async def letters(request: Request, genre: str = Query(default="")) -> Any:
    pages = _catalog(request)
    try:
        conn = await pages.connect()
    except CatalogUnavailable:
        return JSONResponse(UNAVAILABLE, status_code=503)
    try:
        pages.build_soon()
        if genre:
            if genre in OUR_SLUGS and await browse.is_published(conn):
                names, _ = await browse.genre_artists(conn, genre, 0, None)
            else:
                names, _ = await catalog.genre_artists(conn, genre, 0, None)
            return {"letters": catalog.genre_letters(names)}
        return {"letters": await catalog.letters(conn)}
    finally:
        await conn.close()


@router.get("/v1/artists")
async def artists(
    request: Request,
    genre: str = Query(default=""),
    letter: str = Query(default=""),
    offset: int = Query(default=0, ge=0),
    limit: int = Query(default=100, ge=1, le=BROWSE_LIMIT_MAX),
) -> Any:
    """Artists of a genre or for a letter — alphabetically (P-A54).

    Without either — start of overall alphabetical list: this is how Search opens.
    """
    if genre and letter:
        return JSONResponse({"status": "bad_request"}, status_code=422)
    pages = _catalog(request)
    try:
        conn = await pages.connect()
    except CatalogUnavailable:
        return JSONResponse(UNAVAILABLE, status_code=503)
    try:
        pages.build_soon()
        if genre in OUR_SLUGS and await browse.is_published(conn):
            # /v1/genres returns copy genres — and genre artists are taken from there as well:
            # old catalog lacks "rock" entirely, and genre screen would be empty.
            names, total = await browse.genre_artists(conn, genre, offset, limit)
        elif genre:
            names, total = await catalog.genre_artists(conn, genre, offset, limit)
        elif letter:
            # accented letters and special characters map to the same letter as during build.
            names, total = await catalog.letter_artists(conn, catalog.letter_of(norm(letter)), offset, limit)
        else:
            names, total = await catalog.alphabet_artists(conn, offset, limit)
        artists = await pages.listed(conn, names)
    finally:
        await conn.close()
    return {"artists": artists, "total": total}


async def _enrich_and_persist_top_tracks(
    pages: Catalog,
    conn: asyncpg.Connection,
    tracks: list[dict[str, Any]],
    default_artist: str,
) -> None:
    without_cover = [
        track for track in tracks
        if track.get("id") and not track.get("artwork_url")
    ]
    if without_cover:
        song_covers = await images.song_covers_of(conn, [track["id"] for track in without_cover])
        for track in without_cover:
            track["artwork_url"] = song_covers.get(track["id"], "")
    kept = [
        {
            "id": row["id"],
            "title": row["title"],
            "artist": row.get("artist") or default_artist,
            "duration_ms": int(row.get("duration_ms") or 0),
            "artwork_url": row.get("artwork_url") or "",
        }
        for row in tracks
        if row.get("id")
    ]
    for track in kept:
        pages.remember(track)
    if kept and pages.database_url:
        try:
            await persist_tracks(pages.database_url, kept)
        except Exception as exc:  # noqa: BLE001
            logger.warning("tracks persist failed: %s", type(exc).__name__)


@router.get("/v1/artist/songs")
async def artist_songs(request: Request, name: str = Query(default="")) -> Any:
    """All popular songs of an artist in Last.fm order (FT-553)."""
    if getattr(request.app.state, "lastfm", None) is None or not norm(name):
        return {"tracks": []}
    pages = _catalog(request)
    try:
        conn = await pages.connect()
    except CatalogUnavailable:
        return JSONResponse(UNAVAILABLE, status_code=503)
    try:
        tracks = await lastfm.songs(conn, name)
        await _enrich_and_persist_top_tracks(pages, conn, tracks, name)
    finally:
        await conn.close()
    return {"tracks": tracks}


@router.get("/v1/artist")
async def artist_page(
    request: Request, name: str = Query(default=""), id: str | None = Query(default=None)
) -> Any:
    """Artist: albums by year, each with playable status and cover."""
    pages = _catalog(request)
    try:
        conn = await pages.connect()
    except CatalogUnavailable:
        return JSONResponse(UNAVAILABLE, status_code=503)
    try:
        if not await browse.is_published(conn):
            return JSONResponse({"status": "not_ready"}, status_code=503)
        if not id and not norm(name):
            return JSONResponse({"status": "bad_request"}, status_code=422)
        found, aliases, groups, discs = await browse.get_artist(conn, name=name, artist_id=id)
        if found is None:
            user = getattr(request.state, "user", None)
            req_user_id = user["id"] if isinstance(user, dict) and "id" in user else None
            await failures.record(conn, kind="artist_not_found", user_id=req_user_id, artist=name or str(id))
            return JSONResponse(NOT_FOUND, status_code=404)
        titles = [str(group["title"] or "") for group in groups]
        plays = await catalog.playable(conn, found["name"], titles)
        # Covers are requested for the whole grid at once, not one per page open.
        # MBID is sufficient for archive; only fallback search in release needs playable.
        await pages.covers_soon(
            conn,
            str(found["name"]),
            [
                (str(group["id"]), title, play)
                for group, title, play in zip(groups, titles, plays, strict=True)
            ],
        )
        covers = await images.covers_of(conn, [str(group["id"]) for group in groups])
        await pages.photo_soon(conn, norm(str(found["name"])), str(found["id"]))
        photo = await images.photo_of(conn, norm(str(found["name"])))
        # Top tracks, similar, bio — from own table; page does not call Last.fm or MusicBrainz.
        # Track number was populated by robot ahead of time.
        extras = await lastfm.blocks(conn, found["name"]) if getattr(request.app.state, "lastfm", None) is not None else {}
        top_tracks = extras.get("top_tracks") or []
        await _enrich_and_persist_top_tracks(pages, conn, top_tracks, found["name"])
        # Similar artists — same rows as genre list: with photo if stored locally,
        # missing ones are queued (finding 30.09).
        if extras.get("similar"):
            extras["similar"] = await pages.listed(conn, [item["name"] for item in extras["similar"]])
    finally:
        await conn.close()
    return {
        # Photo — only with author and license attribution: displaying
        # Wikimedia Commons image without it is forbidden (app/images.py).
        "artist": {**found, "photo": photo[0] if photo else None, "photo_credit": photo[1] if photo else None, "aliases": aliases},
        "albums": [
            {
                "id": str(group["id"]),
                "title": str(group["title"] or ""),
                "year": browse.norm_date(group.get("first_date"))[1],
                "date": browse.norm_date(group.get("first_date"))[0],
                "kind": group["kind"],
                "editions": group.get("editions", []),
                "playable": play,
                "disc": discs.get(str(group["id"])),
                "cover": covers.get(str(group["id"])),
            }
            for group, play in zip(groups, plays, strict=True)
        ],
        **extras,
    }


@router.get("/v1/albums/{album_id}")
async def album_page(request: Request, album_id: UUID) -> Any:
    """Album: tracklist; each song with playable status. Songs can be played immediately."""
    pages = _catalog(request)
    try:
        conn = await pages.connect()
    except CatalogUnavailable:
        return JSONResponse(UNAVAILABLE, status_code=503)
    try:
        if not await browse.is_published(conn):
            return JSONResponse({"status": "not_ready"}, status_code=503)
        group, disc, track_rows = await browse.get_album(conn, album_id)
        if group is None:
            return JSONResponse(NOT_FOUND, status_code=404)
        artist = group["artist"]
        date, year = browse.norm_date(group["first_date"])
        plays = await catalog.playable(conn, artist, [str(r["title"] or "") for r in track_rows])
        # Song without duration is not checked against release — same as in search.
        plays = [play and int(r["duration_ms"]) > 0 for play, r in zip(plays, track_rows, strict=True)]
        playable = any(plays)
        await pages.covers_soon(
            conn, artist, [(str(album_id), str(group.get("title") or ""), playable)]
        )
        covers = await images.covers_of(conn, [str(album_id)])
    finally:
        await conn.close()
    tracks = [
        {
            "id": r["id"],
            "title": r["title"],
            "artist": artist,
            "duration_ms": r["duration_ms"],
            "artwork_url": "",
            "position": r["position"],
            "playable": play,
        }
        for r, play in zip(track_rows, plays, strict=True)
    ]
    # Only displayed tracks can be played: /v1/playback looks up track in memory and DB.
    for track in tracks:
        pages.remember(track)
    if tracks and pages.database_url:
        try:
            await persist_tracks(pages.database_url, tracks)
        except Exception as exc:  # noqa: BLE001
            logger.warning("tracks persist failed: %s", type(exc).__name__)
    return {
        "album": {
            "id": str(album_id),
            "title": str(group.get("title") or ""),
            "artist": artist,
            "year": year,
            "date": date,
            "playable": playable,
            "disc": disc,
            "cover": covers.get(str(album_id)),
        },
        "tracks": tracks,
    }


@router.get("/v1/tracks/{track_id}/album")
async def track_album(request: Request, track_id: UUID) -> Any:
    """Album of displayed song according to MusicBrainz (FT-562)."""
    pages = _catalog(request)
    try:
        conn = await pages.connect()
    except CatalogUnavailable:
        return JSONResponse(UNAVAILABLE, status_code=503)
    try:
        if not await browse.is_published(conn):
            return JSONResponse({"status": "not_ready"}, status_code=503)
        album = await browse.get_track_album(conn, track_id)
        if album is None:
            return JSONResponse(NOT_FOUND, status_code=404)
        return {"album": album}
    finally:
        await conn.close()


@router.get("/v1/covers/{album_id}")
async def cover(request: Request, album_id: UUID) -> Any:
    return await _picture(request, "cover", images.cover_file, album_id)


@router.get("/v1/photos/{artist_id}")
async def photo(request: Request, artist_id: UUID) -> Any:
    """Artist photo. MBID in path, not name: path goes to access log."""
    return await _picture(request, "photo", images.photo_file, artist_id)


async def _picture(request: Request, namespace: str, find: Any, key: UUID) -> Any:
    """Serve image file from disk. Database stores only path."""
    pages = _catalog(request)
    if pages.pictures is None:
        return JSONResponse(NOT_FOUND, status_code=404)

    cache_key = (namespace, key)
    relative = pages.picture_paths.get(cache_key)
    path = pages.pictures.store.open(relative) if relative is not None else None
    if relative is not None and path is None:
        pages.picture_paths.pop(cache_key, None)

    if path is None:
        try:
            conn = await pages.connect()
        except CatalogUnavailable:
            return JSONResponse(UNAVAILABLE, status_code=503)
        try:
            relative = await find(conn, key)
        finally:
            await conn.close()
        path = pages.pictures.store.open(relative) if relative is not None else None
        if relative is not None and path is not None:
            if cache_key not in pages.picture_paths:
                if len(pages.picture_paths) >= PICTURE_PATH_CACHE_MAX:
                    pages.picture_paths.pop(next(iter(pages.picture_paths)))
            pages.picture_paths[cache_key] = relative

    if path is None:
        return JSONResponse(NOT_FOUND, status_code=404)
    return FileResponse(
        path,
        media_type=images.CONTENT_TYPE[path.suffix.lstrip(".")],
        headers={"cache-control": "private, max-age=604800"},
    )


def install_catalog(app: FastAPI, **kwargs: Any) -> None:
    """Install catalog on the application. In main.py — a single line."""
    app.state.catalog_pages = Catalog(app, **kwargs)
    app.include_router(router)
