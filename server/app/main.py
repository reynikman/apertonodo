from __future__ import annotations

import asyncio
import json
import logging
import os
import secrets
import shutil
import tempfile
import threading
import time
from collections import OrderedDict
from collections.abc import AsyncIterator, Callable
from concurrent.futures import FIRST_COMPLETED, Future, ThreadPoolExecutor
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from uuid import UUID, uuid5

from fastapi import FastAPI, Query, Request
from fastapi.responses import JSONResponse, Response
import httpx
from pydantic import BaseModel

from app.admin import install_admin
from app.admin_web import install_admin_web
from app.app_reports import install_app_reports
from app.auth import install_auth
from app.cache import StreamCache
from app import search as own_search
from app.catalog import playable_pairs, use_extensions
from app.playable_from_extensions import Playable
from app.canonical import canonical_key, collapse_tracks
from app.catalog_api import install_catalog
from app.catalog_snapshot import install_catalog_snapshot
from app.downloads import DownloadFailed, MEDIA_TYPES, install_downloads
from app.error_reports import configure_error_reports
from app import books
from app.book_api import install_books
from app.book_extension import BookExtension
from app.extensions import Extensions, parse_extensions
from app.env_names import env
from app.guard import ApiKeyGuard, UserGuard, require_api_key
from app.images import images_from_env
from app.imports import install_imports
from app.lastfm import lastfm_from_env
from app.mbcopy import mbcopy_from_env
from app.news import install_news
from app.history_control import install_history_control
from app.library import install_library
from app.problems import install_problems
from app.play_worker import install_scrobbling
from app.ratings import install_ratings
from app.podcast_wiring import install_podcast_suite, live_from_env
from app.lyrics_proxy import install_lyrics
from app import failures
from app import play_timing
from app import loudness
from app.play_audio import audio_block, normalize_prefer
from app.matching import CONFIDENCE_THRESHOLD, SEARCH_STOPWORDS, fold_query
from app.musicbrainz import MusicBrainzCatalog, catalog_from_env
from app.media import StreamAborted, audio_response
from app.store import (
    load_session,
    load_track,
    persist_session,
    persist_tracks,
    purge_sessions,
    token_hash,
)
from app.track_by_mbid import load_recording
from app.variants import VariantFailed, asset_stem, asset_variant_path, make_opus, needs_opus

logger = logging.getLogger("apertonodo")


class AcquireFailed(Exception):
    """No byte retrieval path succeeded — client receives unresolved."""


class NoSource(AcquireFailed):
    """No extension returned a confident candidate."""


class LowConfidence(NoSource):
    """Candidates existed, but all fell below confidence threshold."""


# Consecutive failures required before catalog is considered down rather than
# a single unlucky request. Two, not one: cooldown penalty is 1 minute without search.
CATALOG_FAILURES_BEFORE_COOLDOWN = 2

TRACK_FIELDS = ("id", "title", "artist", "duration_ms", "artwork_url")
# Own track ID. MusicBrainz provides recordings with MBID; track from local
# list has no external identifier, so it is deterministically derived from
# artist name and title across searches. Otherwise after server restart,
# search results open on phone would return `404` on Play.
TRACK_NAMESPACE = UUID("6f1b4b8e-2f6a-5f2a-9a3b-1c0d8e7f4a21")
ROOT = Path(__file__).resolve().parents[2]
# Frequency of loudness measurement for played tracks (FT-635): one file takes ffmpeg seconds.
LOUDNESS_INTERVAL_S = 60.0
# Number of displayed tracks kept in memory; remainder persisted in database.
TRACK_MEMORY_MAX = 5000
# Expired sessions purged at most once every 10 minutes: triggered on Play.
SWEEP_INTERVAL_S = 600.0
PLAY_TIMING_BYTES = 256 * 1024
# At most two concurrent prepare requests (FT-570): preparing the next track in
# queue must not block Play or overwhelm extensions. Excess requests return 409 immediately.
MAX_CONCURRENT_PREPARES = 2



class PlaybackIn(BaseModel):
    track_id: UUID
    # Pre-fetching next track in queue while current track is playing. If failed, 409,
    # and track will be requested normally when queue reaches it.
    prepare: bool = False
    # Phone on metered network requests compressed Opus copy (FT-524), prefer lossless
    # mode is `lossless` (FT-633). Unknown value is not an error: legacy client does not break.
    prefer: object = None


class PlaybackFailedIn(BaseModel):
    # Stream token that phone failed to play. Resolves active session the same
    # way as `GET /v1/stream/{token}`.
    token: str


class RevocableResponse(Response):
    """Stop file or extension delivery on local or cross-process revocation."""

    def __init__(self, inner: Response, database_url: str, digest: str,
                 owner: str, events: dict[str, set[asyncio.Event]]) -> None:
        super().__init__(status_code=inner.status_code, headers=dict(inner.headers))
        self.inner, self.database_url = inner, database_url
        self.digest, self.owner, self.events = digest, owner, events

    async def __call__(self, scope: Any, receive: Any, send: Any) -> None:
        import asyncpg

        event = asyncio.Event()
        self.events.setdefault(self.digest, set()).add(event)

        async def watch() -> None:
            while True:
                try:
                    await asyncio.wait_for(event.wait(), timeout=2.0)
                except asyncio.TimeoutError:
                    pass
                if event.is_set():
                    return

                async def check() -> bool:
                    conn = await asyncpg.connect(self.database_url)
                    try:
                        return bool(await conn.fetchval(
                            """SELECT 1 FROM user_tokens AS t
                               JOIN users AS u ON u.id = t.user_id
                               WHERE t.token_hash = $1 AND t.user_id = $2
                                 AND t.expires_at > now() AND u.is_active""",
                            self.digest, UUID(self.owner),
                        ))
                    finally:
                        await conn.close()

                try:
                    if not await asyncio.wait_for(check(), timeout=2.0):
                        return
                except Exception:
                    return  # A failed recheck must never release more bytes.

        sending = asyncio.create_task(self.inner(scope, receive, send))
        checking = asyncio.create_task(watch())
        try:
            done, _ = await asyncio.wait((sending, checking), return_when=FIRST_COMPLETED)
            if checking in done:
                raise StreamAborted("authorization revoked")
            await sending
        finally:
            for task in (sending, checking):
                if not task.done():
                    task.cancel()
            await asyncio.gather(sending, checking, return_exceptions=True)
            active = self.events[self.digest]
            active.discard(event)
            if not active:
                self.events.pop(self.digest, None)


def _public_track(track: dict[str, Any]) -> dict[str, Any]:
    return {field: track[field] for field in TRACK_FIELDS}


def _found_track(track: dict[str, Any]) -> dict[str, Any]:
    """Search result row: same as track, plus `playable` flag.

    `playable: false` means "might not play": track absent from local release list.
    Phone renders it dimmed, matching catalog and "My music", instead of regular row.
    """
    return {**_public_track(track), "playable": bool(track.get("playable", True))}


def _own_track(row: dict[str, Any]) -> dict[str, Any]:
    """Local list entry -> search result track.

    Local tracks lack duration: not available in release metadata. Zero
    is an honest "unknown", scored the same as candidates without duration (`matching._duration_score`).
    """
    return {
        "id": str(uuid5(TRACK_NAMESPACE, canonical_key(row["artist"], row["title"]))),
        "title": row["title"],
        "artist": row["artist"],
        "duration_ms": 0,
        "artwork_url": "",
        "playable": True,
    }


def _matches(track: dict[str, Any], query: str) -> bool:
    needle = {token for token in fold_query(query).split() if token and token not in SEARCH_STOPWORDS}
    if not needle:
        return True
    haystack = set(fold_query(f"{track['artist']} {track['title']}").split())
    return needle <= haystack


def _ms(since: float) -> int:
    return int((time.monotonic() - since) * 1000)


def env_float(name: str, default: float) -> float:
    """Float from environment where unset and empty string are equivalent.

    Docker Compose passes unset variables as empty strings (`${X:-}`), and
    `float("")` raises ValueError. Server previously crashed during import and went into
    restart loop — deployment failed with "Connection refused" with no readable cause.
    `os.environ.get(name, "60")` does not protect against empty string.
    """
    raw = str(os.environ.get(name, "")).strip()
    if not raw:
        return default
    try:
        return float(raw)
    except ValueError:
        logger.warning("bad %s, using default", name)
        return default


def load_fixture_catalog() -> list[dict[str, Any]]:
    path = ROOT / "contracts" / "fixtures" / "catalog.json"
    return list(json.loads(path.read_text())["tracks"])


def create_app(
    *,
    database_url: str | None = None,
    catalog: list[dict[str, Any]] | None = None,
    catalog_port: Any = None,
    now: Callable[[], datetime] | None = None,
    token_ttl: timedelta = timedelta(hours=1),
    cache_dir: Path | None = None,
    cache_quota_bytes: int | None = None,
    variant_dir: Path | None = None,
    download_poll_s: float = 2.0,
    playback_budget_s: float | None = None,
    api_key: str | None = None,
    pictures: Any = None,
    extensions: dict[str, str] | None = None,
    book_extensions: dict[str, str] | None = None,
) -> FastAPI:
    configure_error_reports()

    @asynccontextmanager
    async def lifespan(application: FastAPI) -> AsyncIterator[None]:
        worker = asyncio.create_task(downloads.run()) if database_url else None
        # External scrobbles (D1): only enabled with PLAY_SENDER=1 (app/play_worker.py).
        plays = application.state.play_sender
        sending = asyncio.create_task(plays.run()) if plays is not None else None
        measurer = asyncio.create_task(_loudness_loop()) if database_url else None
        application.state.loudness_task = measurer
        # P8 (FT-758): single client for application lifecycle — extension caches its `/v1/info`.
        has_client = httpx.AsyncClient() if application.state.extensions else None
        if has_client is not None:
            use_extensions(Playable(application.state.extensions.urls, client=has_client))
        try:
            yield
        finally:
            if has_client is not None:
                use_extensions(None)
                await has_client.aclose()
            tasks = [task for task in (worker, sending, measurer) if task is not None]
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            if plays is not None:
                await plays.close()
            if application.state.lastfm_client is not None:
                await application.state.lastfm_client.aclose()
            await asyncio.to_thread(application.state.variant_executor.shutdown, wait=True)

    app = FastAPI(title="music-stream", lifespan=lifespan)
    app.state.variant_dir = variant_dir if variant_dir is not None else Path(
        os.environ.get("VARIANT_DIR")
        or (cache_dir / "variants" if cache_dir is not None else Path(tempfile.gettempdir()) / "apertonodo-variants")
    )
    app.state.variant_executor = ThreadPoolExecutor(max_workers=1)
    app.state.variant_pending = set()
    app.state.variant_jobs = {}
    app.state.variant_lock = threading.Lock()
    # Guard installed only if API key is provided. `None` means unguarded:
    # used by tests verifying search, streaming, and extensions rather than auth.
    # In production key comes from require_api_key; process will not start without it,
    # keeping public perimeter secure. Empty string locks everything except /v1/health.
    app.add_middleware(UserGuard, database_url=database_url, api_key=api_key)
    if api_key is not None:
        app.add_middleware(ApiKeyGuard, key=api_key)
    app.state.database_url = database_url
    app.state.catalog = list(catalog if catalog is not None else load_fixture_catalog())
    # With live catalog, fixture only provides test tones. Other fixture tracks
    # are named like real songs and would collide with live catalog: e.g. "Nothing Else Matters"
    # from fixture sorted first, preempting real MusicBrainz entry with 90s test tone.
    app.state.test_tones = [track for track in app.state.catalog if track.get("test_tone")]
    app.state.sessions = {}
    # Extensions per contracts/extension-api.md. Empty means no audio sources:
    # Play returns 409 unresolved. Invalid EXTENSIONS fails app initialization.
    app.state.extensions = Extensions(
        extensions if extensions is not None else parse_extensions(os.environ.get("EXTENSIONS", ""))
    )
    # Audiobooks (FT-772) use dedicated variable: can be enabled in production before music switch (FT-598).
    app.state.book_extensions = Extensions(
        book_extensions
        if book_extensions is not None
        else parse_extensions(os.environ.get("BOOK_EXTENSIONS", ""))
    )
    app.state.revocation_events = {}
    app.state.running_prepares = 0
    app.state.prepare_lock = threading.Lock()
    # Only previously displayed tracks can be played. Fixture catalog is present
    # at startup; displayed live tracks stored in memory and DB: after deployment
    # memory is empty, and without DB existing search results returned 404.
    app.state.fixture_tracks = {str(track["id"]): track for track in app.state.catalog}
    app.state.tracks = OrderedDict()
    app.state.catalog_port = catalog_port if catalog_port is not None else catalog_from_env(dict(os.environ))
    # Live catalog is external service; cannot wait indefinitely: search must
    # respond from fixture even when MusicBrainz is unreachable. In production
    # provider blocked TLS to musicbrainz.org via SNI filtering, hanging searches
    # for 12-22s before falling back. Timeout caps wait budget; cooldown prevents
    # paying timeout on every subsequent request.
    app.state.catalog_timeout_s = env_float("CATALOG_TIMEOUT_S", 4.0)
    app.state.catalog_cooldown_s = env_float("CATALOG_COOLDOWN_S", 60.0)
    app.state.catalog_skip_until = 0.0
    # Cooldown activates only after consecutive failures. A single slow request
    # is not a down catalog, and a 1-minute cooldown leaves users with no results.
    # In 18.09.2026 measurement, one `TimeoutError` silenced catalog for 60s.
    # Consecutive failures count; isolated ones reset on success.
    app.state.catalog_failures = 0
    # Overall Play budget. Common reverse proxies default to a 60s timeout,
    # CDNs to 100s or more. Previously worst-case was ~210s, triggering proxy timeout
    # and presenting network error to phone instead of clean failure. When budget
    # expires, abort further candidates and return 409.
    app.state.playback_budget_s = (
        playback_budget_s
        if playback_budget_s is not None
        else env_float("PLAYBACK_BUDGET_S", 50.0)
    )
    app.state.last_sweep = time.monotonic()
    app.state.timing_tasks = set()
    app.state.asset_formats = {}
    app.state.sweep_task = None
    clock = now or (lambda: datetime.now(timezone.utc))
    cache = (
        StreamCache(cache_dir, quota_bytes=cache_quota_bytes) if cache_dir is not None else None
    )

    _EXT_TYPES = {"audio/mpeg": "mp3", "audio/mp4": "m4a", "audio/ogg": "opus", "audio/flac": "flac"}

    def _make_asset_variant(asset: str, *, keep_lossy: bool = False) -> Path | None:
        """Full extension file -> Opus copy (FLAC/WAV). `keep_lossy` for downloads: MP3 etc. kept as-is."""
        vid = token_hash(asset)[:8]
        began = time.monotonic()
        tmp: Path | None = None
        key = (f"ext:{asset}", 0)
        try:
            stem = asset_stem(app.state.variant_dir, asset)
            target = asset_variant_path(app.state.variant_dir, asset)
            if target.is_file():
                return target
            name, _, file_id = asset.partition(":")
            stem.parent.mkdir(parents=True, exist_ok=True)
            tmp = stem.with_name(f"{stem.name}.{secrets.token_hex(4)}.src")
            ctype = app.state.extensions.fetch_file(name, file_id, tmp)
            if needs_opus(tmp):
                size = tmp.stat().st_size
                make_opus(tmp, target)
                logger.info(
                    "variant %s: ready in %d ms, %d → %d KB",
                    vid, _ms(began), size // 1024, target.stat().st_size // 1024,
                )
                return target
            fmt = _EXT_TYPES.get(ctype.split(";")[0].strip().casefold())
            if keep_lossy and fmt in MEDIA_TYPES:
                kept = stem.with_suffix(f".{fmt}")
                os.replace(tmp, kept)
                logger.info("variant %s: kept as is in %d ms", vid, _ms(began))
                return kept
        except VariantFailed as exc:
            logger.warning("variant %s: failed: %s", vid, exc)
        except Exception as exc:  # noqa: BLE001
            logger.warning("variant %s: failed: %s", vid, type(exc).__name__)
        finally:
            if tmp is not None:
                tmp.unlink(missing_ok=True)
            if not keep_lossy:
                with app.state.variant_lock:
                    app.state.variant_pending.discard(key)
                    app.state.variant_jobs.pop(key, None)
        return None

    def _queue_variant(session: dict[str, Any]) -> Future[Path | None] | None:
        asset = str(session.get("asset") or "")
        if not asset:
            return None
        key = (f"ext:{asset}", 0)
        with app.state.variant_lock:
            if key in app.state.variant_pending:
                return app.state.variant_jobs[key]
            app.state.variant_pending.add(key)
            try:
                job = app.state.variant_executor.submit(_make_asset_variant, asset)
                app.state.variant_jobs[key] = job
                return job
            except RuntimeError:  # Application shutdown no longer accepts jobs.
                app.state.variant_pending.discard(key)
        return None

    def _remember(track: dict[str, Any]) -> None:
        key = str(track["id"])
        if key in app.state.fixture_tracks:
            return
        app.state.tracks[key] = track
        app.state.tracks.move_to_end(key)
        while len(app.state.tracks) > TRACK_MEMORY_MAX:
            app.state.tracks.popitem(last=False)

    async def _find_track(track_id: str) -> dict[str, Any] | None:
        track = app.state.fixture_tracks.get(track_id) or app.state.tracks.get(track_id)
        if track is not None or not database_url:
            return track
        try:
            track = await load_track(database_url, track_id)
            if track is None:
                track = await load_recording(database_url, track_id)
        except Exception as exc:  # noqa: BLE001
            logger.warning("track lookup failed: %s", type(exc).__name__)
            return None
        if track is not None:
            _remember(track)
        return track

    def _sweep() -> None:
        """Cleanup: purge expired sessions in memory and database."""
        purge_expired()
        if database_url:
            asyncio.run(purge_sessions(database_url))
            asyncio.run(_purge_timing())

    async def _purge_timing() -> None:
        import asyncpg

        conn = await asyncpg.connect(database_url)
        try:
            await play_timing.purge(conn, timedelta(days=play_timing.PLAY_TIMING_KEEP_DAYS))
        finally:
            await conn.close()

    def _timing_task(coro: Any) -> asyncio.Task:
        """Timing recorded in background task after response: neither token nor first bytes wait for it."""
        task = asyncio.get_running_loop().create_task(coro)
        app.state.timing_tasks.add(task)
        task.add_done_callback(app.state.timing_tasks.discard)
        return task

    def _sweep_safely() -> None:
        try:
            _sweep()
        except Exception as exc:  # noqa: BLE001
            logger.warning("sweep failed: %s", type(exc).__name__)

    def _sweep_soon() -> None:
        if time.monotonic() - app.state.last_sweep < SWEEP_INTERVAL_S:
            return
        app.state.last_sweep = time.monotonic()
        app.state.sweep_task = asyncio.get_running_loop().create_task(
            asyncio.to_thread(_sweep_safely)
        )

    # Build SHA of this image (FT-009). The deploy smoke compares it with the
    # commit it just shipped, so a healthy server of another build fails. The
    # body stays exactly {"status":"ok"}: the public smoke and old clients read it.
    revision = (env("REVISION", "") or "").strip()

    @app.get("/v1/health")
    def health(response: Response) -> dict[str, str]:
        if revision:
            response.headers["X-Apertonodo-Revision"] = revision
            response.headers["X-Flowtune-Revision"] = revision  # old name, accepted until clients are moved
        return {"status": "ok"}

    @app.get("/v1/features")
    def features() -> dict[str, bool]:
        # What this server has set up, as two flags: no names, no addresses.
        return {
            "books": bool(app.state.book_extensions.urls),
            "podcasts": live_from_env(os.environ),
        }

    @app.get("/v1/ready")
    async def ready() -> JSONResponse:
        if not database_url:
            return JSONResponse({"status": "not_ready"}, status_code=503)
        import asyncpg

        try:
            conn = await asyncpg.connect(database_url)
            try:
                published = await conn.fetchval("SELECT EXISTS (SELECT 1 FROM mb_loads)")
                if not published:
                    return JSONResponse({"status": "not_ready"}, status_code=503)
            finally:
                await conn.close()
        except Exception:
            logger.info("ready failed")
            return JSONResponse({"status": "not_ready"}, status_code=503)
        return JSONResponse({"status": "ready"})

    async def _own(query: str) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
        """Local release index: artists and songs. No network calls."""
        if not database_url or not query.strip():
            return [], []
        import asyncpg

        conn = await asyncpg.connect(database_url)
        try:
            found_artists = await own_search.artists(conn, query)
            pages = getattr(app.state, "catalog_pages", None)
            if pages is not None:
                found_artists = await pages.listed(conn, [row["name"] for row in found_artists])
            else:
                found_artists = [{**row, "photo": None} for row in found_artists]
            found_tracks = await own_search.tracks(conn, query)
        finally:
            await conn.close()
        return found_artists, [_own_track(row) for row in found_tracks]

    async def _mark(tracks: list[dict[str, Any]]) -> None:
        """Set `playable` flag on tracks originating outside local index."""
        unknown = [track for track in tracks if "playable" not in track]
        if not unknown:
            return
        pairs = [(track["artist"], track["title"]) for track in unknown]
        # Extensions respond over network; without them nothing can play -> "no".
        for track, mark in zip(unknown, await playable_pairs(None, pairs), strict=True):
            track["playable"] = mark

    @app.get("/v1/search")
    async def search(
        q: str = Query(default=""),
        limit: int = Query(default=20, ge=1, le=50),
    ) -> Any:
        # Query text is intentionally omitted from logs: neither this line,
        # nor access log (`app/access_log.py`), nor outbound calls log it.
        # Recent search history is kept on device.
        logger.info("search")
        port = app.state.catalog_port
        # Fixture tracks come first: guaranteed to play. With live catalog these
        # are only test tones, named uniquely to prevent collapse_tracks from replacing real songs.
        local = app.state.catalog if port is None else app.state.test_tones
        # Fixture files are on disk and always play — no need to check release list.
        # Shallow copy ensures playable mark is not retained in app catalog.
        hits = [{**track, "playable": True} for track in local if _matches(track, q)]
        catalog_down = False
        # Query local index and MusicBrainz concurrently: local tracks take precedence,
        # no need to wait for external catalog before starting local search.
        own = asyncio.ensure_future(_own(q))
        try:
            if port is not None and q.strip() and time.monotonic() < app.state.catalog_skip_until:
                catalog_down = True
            elif port is not None and q.strip():
                try:
                    hits.extend(
                        await asyncio.wait_for(
                            port.search(q, limit), timeout=app.state.catalog_timeout_s
                        )
                    )
                except Exception as exc:  # noqa: BLE001
                    # Catalog unreachable or timed out — return local results.
                    # Log only error class name: empty results are indistinguishable
                    # from "no matches", while query text must never be logged.
                    import asyncpg

                    # Our own statement_timeout means "this query is heavy", not "catalog is down".
                    if not isinstance(exc, asyncpg.QueryCanceledError):
                        app.state.catalog_failures += 1
                    if app.state.catalog_failures >= CATALOG_FAILURES_BEFORE_COOLDOWN:
                        app.state.catalog_skip_until = (
                            time.monotonic() + app.state.catalog_cooldown_s
                        )
                        app.state.catalog_failures = 0
                    logger.warning(
                        "catalog search failed: %s (in a row %d)",
                        type(exc).__name__,
                        app.state.catalog_failures,
                    )
                    catalog_down = True
                else:
                    app.state.catalog_failures = 0
            try:
                own_artists, own_tracks = await own
            except Exception as exc:  # noqa: BLE001
                # Local database failed — rely on MusicBrainz results.
                logger.warning("search: own index failed: %s", type(exc).__name__)
                own_artists, own_tracks = [], []
        finally:
            own.cancel()
        # Local tracks first: collapse_tracks retains first occurrence of song,
        # naturally dropping duplicate MusicBrainz entries.
        collapsed = collapse_tracks(own_tracks + hits)[:limit]
        await _mark(collapsed)
        # Unplayable tracks excluded while playable results exist. If no playable
        # results exist, show unplayable items marked accordingly.
        playing = [track for track in collapsed if track.get("playable", True)]
        shown_tracks = playing or collapsed
        if catalog_down and not shown_tracks and not own_artists:
            # Catalog failed and no local results for query. Returning empty results
            # would be misleading: app would show "not found" when catalog was unreachable.
            return JSONResponse({"status": "catalog_unavailable"}, status_code=503)
        shown = [
            track for track in shown_tracks if str(track["id"]) not in app.state.fixture_tracks
        ]
        for track in shown:
            _remember(track)
        if database_url and shown:
            try:
                await persist_tracks(database_url, [_public_track(track) for track in shown])
            except Exception as exc:  # noqa: BLE001
                # Does not fail search: track remains in memory until restart.
                logger.warning("tracks persist failed: %s", type(exc).__name__)
        # No source preheating needed: Play queries extensions anew.
        return {
            "artists": own_artists,
            "tracks": [_found_track(track) for track in shown_tracks],
        }

    @app.get("/v1/suggest")
    async def suggest(
        q: str = Query(default=""),
        limit: int = Query(default=10, ge=1, le=20),
    ) -> Any:
        """Typeahead suggestions from local database only.

        Search keystrokes are never sent to Apple, Deezer, Last.fm, or MusicBrainz.
        No network calls made; query text never logged.
        """
        logger.info("suggest")
        if not database_url or not q.strip():
            return {"suggestions": []}
        import asyncpg

        try:
            conn = await asyncpg.connect(database_url)
            try:
                found = await own_search.suggest(conn, q, limit)
            finally:
                await conn.close()
        except Exception as exc:  # noqa: BLE001
            # Suggestion is a convenience, not a requirement. Silence is better than
            # error: user will simply finish typing and search.
            logger.warning("suggest failed: %s", type(exc).__name__)
            return {"suggestions": []}
        return {"suggestions": found}

    async def _acquire_download(track_id: str, ref: str) -> dict[str, Any]:
        track = await _find_track(track_id)
        if track is None:
            raise DownloadFailed("track not found")
        started = time.monotonic()
        try:
            asset = await _select_extension(
                track, started, started + app.state.playback_budget_s, ref
            )
        except NoSource:
            raise DownloadFailed("no source") from None
        except AcquireFailed:
            raise DownloadFailed("unresolved") from None
        return {"asset": asset, "media_path": None}

    async def _pin_extension(asset: str, pinned: bool) -> None:
        name, _, file_id = asset.partition(":")
        if name in app.state.extensions.urls:
            await app.state.extensions.pin(name, file_id, pinned)

    async def _prepare_download(
        row: dict[str, Any],
    ) -> tuple[Path, str] | Future[Path | None] | None:
        if not row.get("asset"):
            raise DownloadFailed("source unavailable")
        asset = str(row["asset"])
        target = asset_variant_path(app.state.variant_dir, asset)
        if await asyncio.to_thread(target.is_file):
            return target, "opus"
        return app.state.variant_executor.submit(_make_asset_variant, asset, keep_lossy=True)

    @app.post("/v1/playback")
    async def playback(body: PlaybackIn, request: Request) -> JSONResponse:
        # Short play token links log lines for a single Play request.
        # Random hex string, unlinked to user identity or query.
        play = secrets.token_hex(3)
        prefer = normalize_prefer(body.prefer)
        started = time.monotonic()
        timer = play_timing.Timer(str(body.track_id), bool(body.prepare), clock=time.monotonic)
        deadline = started + app.state.playback_budget_s
        logger.info("playback %s: %s", play, "prepare" if body.prepare else "start")
        prepared_slot_taken = False
        if body.prepare:
            with app.state.prepare_lock:
                if app.state.running_prepares >= MAX_CONCURRENT_PREPARES:
                    logger.info(
                        "playback %s: prepare skipped, %d running",
                        play,
                        app.state.running_prepares,
                    )
                    return JSONResponse({"state": "unresolved"}, status_code=409)
                app.state.running_prepares += 1
                prepared_slot_taken = True
        try:
            user = getattr(request.state, "user", None)
            req_user_id = UUID(str(user["id"])) if isinstance(user, dict) and "id" in user else None
            track = await _find_track(str(body.track_id))
            if track is None:
                logger.info("playback %s: track not found", play)
                await failures.note(database_url, kind="track_not_found", user_id=req_user_id, track_id=str(body.track_id), ref=f"playback {play}")
                return JSONResponse({"status": "not_found"}, status_code=404)
            _sweep_soon()
            try:
                asset = await _select_extension(
                    track, started, deadline, f"playback {play}", timer, prefer=prefer
                )
            except AcquireFailed as exc:
                timer.mark("token")
                _timing_task(play_timing.write(database_url, timer.row(
                    "low_confidence" if isinstance(exc, LowConfidence)
                    else "no_source" if isinstance(exc, NoSource) else "not_ready"
                )))
                kind = "no_source" if isinstance(exc, NoSource) else "unresolved"
                await failures.note(database_url, kind=kind, user_id=req_user_id, track_id=str(track["id"]), artist=track["artist"], title=track["title"], ref=f"playback {play}")
                return JSONResponse({"state": "unresolved"}, status_code=409)
            state = "ready"
            token = secrets.token_urlsafe(24)
            user = getattr(request.state, "user", None)
            session_user_id = (
                str(user["id"]) if isinstance(user, dict) and "id" in user else None
            )
            if session_user_id is None and database_url:
                try:
                    session_user_id = await _resolve_owner_id()
                except Exception as exc:  # noqa: BLE001
                    # No owner means the stream answers 404: fail closed, cache nothing.
                    logger.warning(
                        "playback %s: owner resolve failed: %s", play, type(exc).__name__
                    )
            session: dict[str, Any] = {
                "state": state,
                "track": _public_track(track),
                "buffered_ms": 0,
                "media_path": "",
                "expires_at": clock() + token_ttl,
                "user_id": session_user_id,
                # Preferred format is ephemeral: after restart original plays (FT-524).
                "prefer": prefer,
                # Made in this process by the key holder with no bearer: the same
                # principal may stream it even while the database is down.
                "legacy_owner": user is None,
                "asset": asset,
            }
            timer.mark("token")
            # Timing and Timer instance live in session memory only: not sent to client.
            session["timing"] = (timer, _timing_task(play_timing.write(database_url, timer.row("waiting"))))
            app.state.sessions[token_hash(token)] = session
            if database_url:
                try:
                    await persist_session(
                        database_url,
                        user_id=session_user_id,
                        token=token,
                        track_id=str(track["id"]),
                        candidate_id=None,
                        state=state,
                        expires_at=session["expires_at"],
                        media_path=session["media_path"],
                        track=session["track"],
                        asset=asset,
                    )
                except Exception as exc:  # noqa: BLE001
                    # Source is already ready and streaming bytes — do not fail on DB error.
                    # Without persistence token simply won't survive restart.
                    logger.warning(
                        "playback %s: session persist failed: %s", play, type(exc).__name__
                    )
            # Stream ID is token hash prefix, matching `stream <id>` log entries:
            # tracks outcome of this specific Play request.
            logger.info(
                "playback %s: token after %d ms, stream %s", play, _ms(started), token_hash(token)[:8]
            )
            answer: dict[str, Any] = {"token": token, "state": state, "track": _public_track(track)}
            if audio := _audio_of(session):
                answer["audio"] = audio
            return JSONResponse(answer)
        finally:
            if prepared_slot_taken:
                with app.state.prepare_lock:
                    app.state.running_prepares -= 1

    async def _select_extension(
        track: dict[str, Any], started: float, deadline: float, ref: str,
        timer: play_timing.Timer | None = None,
        prefer: str | None = None,
    ) -> str:
        """Query extensions and prepare best candidate file: `<name>:<file_id>`.

        No extensions or no confident candidates raises `NoSource`; candidates existed
        but none ready raises `AcquireFailed`: both result in 409 unresolved to client.
        """
        exts = app.state.extensions
        if not exts:
            logger.info("%s: no extensions", ref)
            raise NoSource
        names = list(exts.urls)
        answers = await asyncio.gather(
            *(exts.find(name, track) for name in names), return_exceptions=True
        )
        if timer:
            timer.mark("find")
        named = False
        found: list[tuple[float, str, str, bool]] = []
        for name, answer in zip(names, answers, strict=True):
            if isinstance(answer, BaseException):
                logger.info("%s: extension %s did not answer: %s", ref, name, type(answer).__name__)
                continue
            for item in answer:
                named = True
                try:
                    confidence = float(item.get("confidence") or 0)
                except (TypeError, ValueError):
                    continue
                if confidence >= CONFIDENCE_THRESHOLD:
                    quality = str(item.get("quality") or "").lower()
                    is_lossless = quality in ("lossless", "hires")
                    found.append((confidence, name, str(item["id"]), is_lossless))
        if prefer == "lossless":
            lossless = [item for item in found if item[3]]
            rest = [item for item in found if not item[3]]
            lossless.sort(key=lambda item: -item[0])
            rest.sort(key=lambda item: -item[0])
            found = lossless + rest
            logger.info(
                "%s: extensions: %d answered, %d above threshold, %d lossless, %d ms",
                ref,
                sum(not isinstance(a, BaseException) for a in answers),
                len(found),
                len(lossless),
                _ms(started),
            )
        else:
            found.sort(key=lambda item: -item[0])
            logger.info(
                "%s: extensions: %d answered, %d above threshold, %d ms",
                ref,
                sum(not isinstance(a, BaseException) for a in answers),
                len(found),
                _ms(started),
            )
        if not found:
            logger.info("%s: no candidate above threshold", ref)
            raise LowConfidence if named else NoSource
        if timer:
            timer.source = found[0][1]
        for confidence, name, file_id, _ in found[:3]:
            began = time.monotonic()
            try:
                ready = await exts.prepare(name, file_id, deadline)
            except Exception as exc:  # noqa: BLE001
                logger.info("%s: extension %s prepare failed: %s", ref, name, type(exc).__name__)
                continue
            if ready:
                logger.info(
                    "%s: extension %s (%.2f): ready in %d ms", ref, name, confidence, _ms(began)
                )
                if timer:
                    timer.source = name
                    timer.mark("prepare")
                    timer.swarm(ready.get("stats"))
                # The extension names the format for the player badge: there is no file on the core's disk.
                if isinstance(ready.get("format"), str):
                    app.state.asset_formats[f"{name}:{file_id}"] = ready["format"]
                return f"{name}:{file_id}"
            logger.info("%s: extension %s (%.2f): not ready", ref, name, confidence)
        logger.info("%s: unresolved after %d ms", ref, _ms(started))
        raise AcquireFailed

    app.state.owner_id = None

    async def _resolve_owner_id() -> str | None:
        if getattr(app.state, "owner_id", None) is not None:
            return str(app.state.owner_id)
        if not database_url:
            return None
        import asyncpg
        from app.users import ensure_owner_id

        conn = await asyncpg.connect(database_url)
        try:
            owner_uuid = await ensure_owner_id(conn)
            app.state.owner_id = str(owner_uuid)
            return app.state.owner_id
        finally:
            await conn.close()

    async def _live_session(token: str) -> dict[str, Any] | None:
        key = token_hash(token)
        session = app.state.sessions.get(key)
        if session is None and database_url:
            # Process was restarted — session missing from memory, but DB maps
            # token to release and file.
            try:
                session = await load_session(database_url, key)
            except Exception as exc:  # noqa: BLE001
                logger.warning("session restore failed: %s", type(exc).__name__)
                session = None
            if session is not None:
                app.state.sessions[key] = session
        if session is None:
            return None
        if session["expires_at"] <= clock():
            app.state.sessions.pop(key, None)
            return None
        return session

    def _audio_of(session: dict[str, Any]) -> dict[str, Any] | None:
        """Audio block (FT-684): actual file format for player badge.

        Extension only — file name reveals track title and is not exposed.
        File not yet selected (source extension, no file list) returns `None`.
        """
        name = Path(str(session["media_path"])).name if session.get("media_path") else ""
        if not name and (fmt := app.state.asset_formats.get(str(session.get("asset") or ""))):
            name = f"file.{fmt}"
        gain = app.state.gains.get(str(session.get("media_path") or ""))
        return audio_block(name, gain_db=gain)

    # Loudness (FT-635, D2): `gain_db` offset known for files fully played from disk.
    # Measured in background one file at a time; Play uses cached memory value without DB wait.
    app.state.gains = {}

    async def _loudness_pass(measure: Any = loudness.measure) -> None:
        paths = sorted(
            {
                Path(str(session["media_path"]))
                for session in list(app.state.sessions.values())
                if session.get("media_path")
            }
        )
        if not paths or not database_url:
            return
        import asyncpg

        conn = await asyncpg.connect(database_url)
        try:
            await loudness.measure_pending(conn, paths, measure=measure)
            for path in paths:
                gain = await loudness.gain_for(conn, path)
                if gain is not None:
                    app.state.gains[str(path)] = gain
        finally:
            await conn.close()

    app.state.loudness_pass = _loudness_pass

    async def _loudness_loop() -> None:
        while True:
            await asyncio.sleep(LOUDNESS_INTERVAL_S)
            try:
                await app.state.loudness_pass()
            except Exception as exc:  # noqa: BLE001
                logger.warning("loudness pass failed: %s", type(exc).__name__)

    def _public_session(session: dict[str, Any]) -> dict[str, Any]:
        public = {
            "state": session["state"],
            "track": session["track"],
            "buffered_ms": session.get("buffered_ms", 0),
        }
        if audio := _audio_of(session):
            public["audio"] = audio
        return public

    @app.get("/v1/playback/{token}/status")
    async def playback_status(token: str) -> JSONResponse:
        session = await _live_session(token)
        if session is None:
            return JSONResponse({"status": "not_found"}, status_code=404)
        return JSONResponse(_public_session(session))

    @app.post("/v1/playback/failed")
    async def playback_failed(body: PlaybackFailedIn, request: Request) -> Response:
        """Phone failed to play stream: notify extension.

        Files cannot be fully verified before streaming — audio streams while downloading,
        so only client detects failure and reports it here. Extension deprioritizes file ID
        so Retry selects a different candidate instead of failing again.
        """
        session = await _live_session(body.token)
        if session is None:
            return Response(status_code=404)
        try:
            if not await _caller_owns(body.token, session, request):
                return Response(status_code=404)
        except Exception:
            return Response(status_code=503)
        # Stream ID is token hash prefix, matching `stream <id>` lines.
        # Neither token nor track title appears in logs.
        sid = token_hash(body.token)[:8]
        logger.info("playback failed: reported by the phone, stream %s", sid)
        track_info = session.get("track", {})
        track_id = str(track_info.get("id", ""))
        if session.get("asset"):
            name, _, file_id = str(session["asset"]).partition(":")
            try:
                # Audiobooks served by book extension — report error there.
                own = app.state.book_extensions if session.get("book_file") is not None else app.state.extensions
                await own.failed(name, file_id, "bad_audio")
            except Exception as exc:  # noqa: BLE001
                # Extension error ignored: return 204 to phone as usual.
                logger.info("playback failed: extension %s did not take it: %s", name, type(exc).__name__)
        req_user_id = UUID(str(session["user_id"])) if session.get("user_id") else None
        await failures.note(
            database_url,
            kind="player_error",
            user_id=req_user_id,
            track_id=track_id,
            artist=track_info.get("artist", ""),
            title=track_info.get("title", ""),
            ref=f"stream {sid}",
        )
        return Response(status_code=204)

    async def _caller_owns(token: str, session: dict[str, Any], request: Request) -> bool:
        """Verify session ownership.

        Shared check for streaming and failure reporting: both operate on user's token.
        Session `user_id` loaded from DB if missing from memory after restart.
        DB errors propagate to return 503 instead of pretending token does not exist.
        """
        if not database_url:
            return True
        user = getattr(request.state, "user", None)
        # Session created by key holder without login — caller owns the audio.
        if user is None and session.get("user_id") is None and session.get("legacy_owner") is True:
            return True
        session_user_id = session.get("user_id")
        if session_user_id is None:
            import asyncpg

            conn = await asyncpg.connect(database_url)
            try:
                db_user_id = await conn.fetchval(
                    "SELECT user_id::text FROM playback_sessions WHERE token_hash = $1",
                    token_hash(token),
                )
                if db_user_id:
                    session_user_id = str(db_user_id)
                    session["user_id"] = session_user_id
            finally:
                await conn.close()
        caller_id: str | None = str(user["id"]) if isinstance(user, dict) and "id" in user else None
        if caller_id is None:
            caller_id = await _resolve_owner_id()
        return bool(session_user_id and caller_id and str(session_user_id) == str(caller_id))

    @app.api_route("/v1/stream/{token}", methods=["GET", "HEAD"])
    async def stream(token: str, request: Request) -> Response:
        session = await _live_session(token)
        if session is None:
            return JSONResponse({"status": "not_found"}, status_code=404)
        try:
            if not await _caller_owns(token, session, request):
                return Response(status_code=404)
        except Exception:
            return Response(status_code=503)
        # Stream ID in log is token hash prefix: correlates requests for same song
        # without logging the actual token.
        sid = token_hash(token)[:8]

        def guarded(response: Response) -> Response:
            digest = getattr(request.state, "bearer_hash", None)
            user = getattr(request.state, "user", None)
            if digest and database_url and isinstance(user, dict):
                return RevocableResponse(response, database_url, digest, str(user["id"]),
                                         app.state.revocation_events)
            return response

        if session.get("asset"):
            name, _, file_id = str(session["asset"]).partition(":")
            began = time.monotonic()
            logger.info(
                "stream %s: open %s range=%s",
                sid,
                request.method,
                "present" if request.headers.get("range") else "-",
            )

            # Opus copy only for FLAC/WAV: avoid fetching MP3 from extension twice.
            lossless = {"yes": False}

            def note_stream_failure(kind: str) -> None:
                # Beta failure tracking (FT-520): stream drop logged to database as well as journal.
                info = session.get("track", {})
                coro = failures.note(
                    database_url,
                    kind=kind,
                    user_id=UUID(str(session["user_id"])) if session.get("user_id") else None,
                    track_id=str(info.get("id", "")),
                    artist=info.get("artist", ""),
                    title=info.get("title", ""),
                    ref=f"stream {sid}",
                )
                try:
                    asyncio.get_running_loop().create_task(coro)
                except RuntimeError:
                    asyncio.run(coro)

            # Audio timing (FT-786): GET on extension only, not book; HEAD and post-restart session without Timer skipped.
            timing = session.get("timing") if request.method == "GET" and "book_file" not in session else None
            timing_done = {"yes": False}

            def finish_timing(outcome: str) -> None:
                if timing is None or timing_done["yes"]:
                    return
                timing_done["yes"] = True
                timer, written = timing

                async def update() -> None:
                    row_id = await written
                    await play_timing.stream_done(
                        database_url, row_id,
                        first_byte_ms=timer.get("first_byte"), first_256k_ms=timer.get("first_256k"), outcome=outcome,
                    )

                _timing_task(update())

            def on_progress(sent: int) -> None:
                if timing is None:
                    return
                if sent > 0:
                    timing[0].mark("first_byte")
                if sent >= PLAY_TIMING_BYTES:
                    timing[0].mark("first_256k")
                    finish_timing("played")

            def on_end_ext(sent: int, reason: str) -> None:
                logger.info("stream %s: %s after %d bytes, %d ms", sid, reason, sent, _ms(began))
                if reason in ("extension stalled", "extension error"):
                    note_stream_failure("stream_stalled" if reason == "extension stalled" else "stream_error")
                if reason == "complete":
                    finish_timing("played")
                elif reason == "extension stalled":
                    finish_timing("stalled")
                elif reason == "extension error":
                    finish_timing("error")
                if reason == "complete" and request.method != "HEAD" and lossless["yes"]:
                    _queue_variant(session)

            if session.get("prefer") == "opus":
                try:
                    copy = asset_variant_path(app.state.variant_dir, str(session["asset"]))
                except VariantFailed:
                    copy = None
                if copy is not None and await asyncio.to_thread(copy.is_file):
                    logger.info(
                        "stream %s: opus copy %s range=%s",
                        sid, request.method, "present" if request.headers.get("range") else "-",
                    )
                    return guarded(audio_response(copy, request.headers.get("range")))

            book_file = session.get("book_file")
            try:
                result = await (
                    app.state.book_extensions if book_file is not None else app.state.extensions
                ).proxy_stream(
                    name,
                    file_id,
                    path=f"/v1/books/file/{file_id}/{book_file}" if book_file is not None else None,
                    method=request.method,
                    range_header=request.headers.get("range"),
                    aborted=StreamAborted,
                    on_end=on_end_ext,
                    on_progress=on_progress,
                )
                kind = result.headers.get("content-type", "").split(";")[0].strip().casefold()
                lossless["yes"] = kind in ("audio/flac", "audio/x-flac", "audio/wav", "audio/x-wav")
                return guarded(result)
            except Exception as exc:  # noqa: BLE001
                logger.info("stream %s: extension did not answer: %s", sid, type(exc).__name__)
                finish_timing("stalled" if isinstance(exc, httpx.TimeoutException) else "error")
                if isinstance(exc, httpx.TimeoutException):
                    note_stream_failure("stream_stalled")
                return JSONResponse({"status": "unavailable"}, status_code=503)
        path = Path(session.get("media_path") or "")
        if not await asyncio.to_thread(path.is_file):
            return JSONResponse({"status": "not_found"}, status_code=404)
        return guarded(audio_response(path, request.headers.get("range")))

    def purge_expired() -> None:
        now_ts = clock()
        live: dict[str, dict[str, Any]] = {}
        keep: set[Path] = set()
        for key, session in list(app.state.sessions.items()):
            if session["expires_at"] <= now_ts:
                continue
            live[key] = session
            path = Path(session.get("media_path") or "")
            if path:
                keep.add(path)
        app.state.sessions = live
        if cache is not None:
            cache.purge_unused(keep)

    app.state.purge_expired = purge_expired
    # Images: album covers and artist photos (app/images.py). Files on disk,
    # database stores relative paths. Missing `IMAGE_DIR` disables images;
    # UI displays placeholder initials.
    app.state.images = (
        pictures if pictures is not None else images_from_env(os.environ, database_url)
    )
    # Catalog: genres, artists, albums (app/catalog_api.py).
    install_catalog(
        app,
        database_url=database_url,
        remember=_remember,
        pictures=app.state.images,
    )
    # Last.fm for artist page: only with API key in environment (app/lastfm.py).
    app.state.lastfm = lastfm_from_env(os.environ, database_url)
    app.state.mbcopy = mbcopy_from_env(os.environ, database_url)
    # R-A63: online MusicBrainz is the default; say so once, without query or addresses.
    if isinstance(app.state.catalog_port, MusicBrainzCatalog) and app.state.mbcopy is None:
        logger.info("catalog: no local MusicBrainz copy, using online MusicBrainz")
    # "My music": favorites, playlists, history (app/library.py).
    install_library(app, database_url=database_url)
    # History: delete row, clear all, pause recording (app/history_control.py).
    install_history_control(app, database_url=database_url)
    # Star ratings and thumbs down (app/ratings.py).
    install_ratings(app, database_url=database_url)
    # ListenBrainz and Last.fm: connect and scrobble plays (app/play_worker.py).
    install_scrobbling(app, database_url=database_url, env=os.environ)
    # "Report a problem": submit and list for admin (app/problems.py).
    install_problems(app, database_url=database_url, api_key=api_key)
    # Lyrics: core queries lyrics extension (app/lyrics_proxy.py).
    install_lyrics(app, database_url=database_url)
    # News: artist subscriptions and custom channels (app/news.py).
    install_news(app, database_url=database_url, env=os.environ)
    install_imports(app, remember=_remember)

    book_clients = {
        name: BookExtension(name, url) for name, url in app.state.book_extensions.urls.items()
    }

    async def _book_search(query: str, limit: int) -> list[Any]:
        if not book_clients:
            raise RuntimeError("no book extension")
        found: list[Any] = []
        for client in book_clients.values():
            found.extend(await client.search(query, limit))
        return found[:limit]

    async def _book_files(asset: str, hint: str) -> Any:
        client = book_clients.get(asset.partition(":")[0])
        return await client.files(asset, hint) if client is not None else None

    async def _book_play(
        conn: Any, user_id: UUID, book_id: UUID, part: int
    ) -> tuple[str, str] | None:
        source = await books.book_source(conn, book_id)
        if source is None or source.asset.partition(":")[0] not in book_clients:
            return None
        index = next(
            (p.file_index for p in await books.book_parts(conn, book_id) if p.number == part),
            None,
        )
        if index is None:
            return None
        token = secrets.token_urlsafe(24)
        # Book part session kept in memory: after restart phone simply taps Play again.
        app.state.sessions[token_hash(token)] = {
            "state": "ready",
            "track": {"id": str(book_id)},
            "buffered_ms": 0,
            "media_path": "",
            "expires_at": clock() + token_ttl,
            "user_id": str(user_id),
            "prefer": None,
            "legacy_owner": False,
            "asset": source.asset,
            "book_file": index,
        }
        return token, "ready"

    install_books(
        app,
        database_url=database_url,
        search=_book_search,
        files=_book_files,
        play=_book_play,
    )
    install_auth(app, database_url, now=now)
    downloads = install_downloads(
        app, database_url=database_url, poll_s=download_poll_s,
        acquire=_acquire_download, prepare=_prepare_download, pin=_pin_extension,
    )
    # Catalog snapshot for mobile app (app/catalog_snapshot.py).
    install_catalog_snapshot(app, database_url=database_url)
    install_app_reports(app, api_key=api_key)

    def _admin_space() -> dict[str, int]:
        assert cache is not None
        usage = shutil.disk_usage(cache.root)
        used = sum(path.stat().st_size for path in cache.root.iterdir() if path.is_file())
        return {"total_bytes": usage.total, "free_bytes": usage.free, "cache_bytes": used}

    # Admin: /v1/admin endpoints (app/admin.py) and /admin web UI (app/admin_web.py).
    install_admin(
        app,
        database_url=database_url,
        api_key=api_key,
        storage=_admin_space if cache is not None else None,
    )
    install_admin_web(app)
    # Podcasts: endpoints, directory client, feed crawler (app/podcast_wiring.py).
    install_podcast_suite(app, database_url=database_url, env=os.environ)
    return app


def _production_app() -> FastAPI:
    return create_app(
        database_url=os.environ.get("DATABASE_URL"),
        # Missing key raises during app creation: uvicorn will not start,
        # container exits with clear reason, public smoke check fails.
        api_key=require_api_key(os.environ),
    )


def __getattr__(name: str) -> Any:
    if name == "app":
        built = _production_app()
        globals()["app"] = built
        return built
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
