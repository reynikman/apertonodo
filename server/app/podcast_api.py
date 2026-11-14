"""FT-661 (Р-A93, block B-5): podcast endpoints (search, subscriptions, episodes, position sync)."""

from __future__ import annotations

import json
from collections.abc import Callable
from datetime import UTC, datetime
from typing import Any
from uuid import UUID

import asyncpg
import httpx
from fastapi import APIRouter, FastAPI, Request
from fastapi.responses import JSONResponse

from app import (
    podcast_continue,
    podcast_new,
    podcast_progress,
    podcast_search,
    podcasts,
)
from app.library import Library, Unavailable, UNAVAILABLE
from app.podcast_search import PodcastSearchUnavailable

MAX_SMALL_BODY: int = 8 * 1024
MAX_PROGRESS_BODY: int = 2 * 1024 * 1024

MAX_PARAM_INT: int = 1 << 62

INVALID_REQUEST = {"status": "invalid_request"}
PODCAST_SEARCH_UNAVAILABLE = {"status": "podcast_search_unavailable"}
NOT_SUBSCRIBED = {"status": "not_subscribed"}
BAD_URL = {"status": "bad_url"}
LIMIT = {"status": "limit"}

router = APIRouter()


def _format_dt(dt: datetime | None) -> str | None:
    if dt is None:
        return None
    if dt.tzinfo is not None:
        dt_utc = dt.astimezone(UTC)
    else:
        dt_utc = dt.replace(tzinfo=UTC)
    ms = dt_utc.microsecond // 1000
    return f"{dt_utc.strftime('%Y-%m-%dT%H:%M:%S')}.{ms:03d}Z"


def _parse_since(raw: str) -> datetime | None:
    """Timestamp with timezone (`…Z` or `+03:00`); without timezone it is invalid."""
    try:
        value = datetime.fromisoformat(raw)
    except ValueError:
        return None
    if value.tzinfo is None:
        return None
    return value


def _episode_wire(e: Any) -> dict[str, Any]:
    return {
        "guid": e.guid,
        "title": e.title,
        "description": e.description,
        "audio_url": e.audio_url,
        "audio_type": e.audio_type,
        "audio_bytes": e.audio_bytes,
        "duration_ms": e.duration_ms,
        "published": _format_dt(e.published),
        "image": e.image,
        "season": e.season,
        "number": e.number,
        "explicit": e.explicit,
    }


def _user_id(request: Request) -> UUID:
    return UUID(str(request.state.user["id"]))


async def _connect(request: Request) -> asyncpg.Connection:
    library: Library = request.app.state.podcast_library
    return await library.connect()


def _parse_uint(raw: str) -> int | None:
    if not (1 <= len(raw) <= 19 and raw.isascii() and raw.isdigit()):
        return None
    val = int(raw)
    return min(val, MAX_PARAM_INT)


def _get_uint_param(
    request: Request, name: str, default: int
) -> tuple[int, JSONResponse | None]:
    if name not in request.query_params:
        return default, None
    raw = request.query_params[name]
    parsed = _parse_uint(raw)
    if parsed is None:
        return 0, JSONResponse(INVALID_REQUEST, status_code=400)
    return parsed, None


async def _read_json_body(
    request: Request, limit: int
) -> tuple[Any, JSONResponse | None]:
    cl_header = request.headers.get("content-length")
    if cl_header is not None:
        raw_cl = cl_header.strip()
        if not (raw_cl.isascii() and raw_cl.isdigit()):
            return None, JSONResponse(INVALID_REQUEST, status_code=400)
        try:
            cl = int(raw_cl)
        except (ValueError, OverflowError):
            return None, JSONResponse(INVALID_REQUEST, status_code=400)
        if cl < 0 or cl > limit:
            return None, JSONResponse(INVALID_REQUEST, status_code=400)

    chunks: list[bytes] = []
    total = 0
    async for chunk in request.stream():
        total += len(chunk)
        chunks.append(chunk)
        if total > limit:
            return None, JSONResponse(INVALID_REQUEST, status_code=400)

    raw_body = b"".join(chunks)
    try:
        text = raw_body.decode("utf-8")
    except UnicodeDecodeError:
        return None, JSONResponse(INVALID_REQUEST, status_code=400)

    try:
        data = json.loads(text)
    except (ValueError, RecursionError):
        return None, JSONResponse(INVALID_REQUEST, status_code=400)

    return data, None


@router.get("/v1/podcasts/search")
async def search(request: Request) -> Any:
    limit, err = _get_uint_param(request, "limit", 20)
    if err is not None:
        return err

    client: httpx.AsyncClient | None = getattr(
        request.app.state, "podcast_client", None
    )
    if client is None:
        return JSONResponse(PODCAST_SEARCH_UNAVAILABLE, status_code=503)

    q = request.query_params.get("q", "")
    try:
        found = await podcast_search.search(q, client=client, limit=limit)
    except PodcastSearchUnavailable:
        return JSONResponse(PODCAST_SEARCH_UNAVAILABLE, status_code=503)

    return {
        "podcasts": [
            {
                "feed_url": p.feed_url,
                "title": p.title,
                "author": p.author,
                "image": p.image,
                "episodes": p.episodes,
            }
            for p in found
        ]
    }


@router.get("/v1/podcasts")
async def list_subscriptions(request: Request) -> Any:
    try:
        conn = await _connect(request)
    except Unavailable:
        return JSONResponse(UNAVAILABLE, status_code=503)

    try:
        user_id = _user_id(request)
        subs = await podcasts.subscriptions(conn, user_id)
        return {
            "podcasts": [
                {
                    "feed_url": s.feed_url,
                    "title": s.title,
                    "author": s.author,
                    "image": s.image,
                    "episodes": s.episodes,
                    "newest_at": _format_dt(s.newest_at),
                    "added_at": _format_dt(s.added_at),
                    "language": s.language,
                }
                for s in subs
            ]
        }
    except (asyncpg.PostgresError, asyncpg.InterfaceError, OSError):
        return JSONResponse(UNAVAILABLE, status_code=503)
    finally:
        await conn.close()


@router.post("/v1/podcasts/subscribe")
async def subscribe(request: Request) -> Any:
    data, err = await _read_json_body(request, MAX_SMALL_BODY)
    if err is not None:
        return err

    if not isinstance(data, dict):
        return JSONResponse(INVALID_REQUEST, status_code=400)

    feed_url = data.get("feed_url")
    if not isinstance(feed_url, str):
        return JSONResponse(INVALID_REQUEST, status_code=400)

    clean_url = podcasts.normalize_feed_url(feed_url)
    if clean_url is None:
        return JSONResponse(BAD_URL, status_code=422)

    try:
        conn = await _connect(request)
    except Unavailable:
        return JSONResponse(UNAVAILABLE, status_code=503)

    try:
        user_id = _user_id(request)
        res = await podcasts.subscribe(conn, user_id, clean_url)
        if res == "limit":
            return JSONResponse(LIMIT, status_code=409)
        if res == "bad_url":
            return JSONResponse(BAD_URL, status_code=422)
        if res == "ok":
            kick: Callable[[], None] | None = getattr(
                request.app.state, "podcast_kick", None
            )
            if kick is not None:
                try:
                    kick()
                except Exception:
                    pass
            return {"result": "new", "feed_url": clean_url}
        return {"result": "exists", "feed_url": clean_url}
    except (asyncpg.PostgresError, asyncpg.InterfaceError, OSError):
        return JSONResponse(UNAVAILABLE, status_code=503)
    finally:
        await conn.close()


@router.post("/v1/podcasts/unsubscribe")
async def unsubscribe(request: Request) -> Any:
    data, err = await _read_json_body(request, MAX_SMALL_BODY)
    if err is not None:
        return err

    if not isinstance(data, dict):
        return JSONResponse(INVALID_REQUEST, status_code=400)

    feed_url = data.get("feed_url")
    if not isinstance(feed_url, str):
        return JSONResponse(INVALID_REQUEST, status_code=400)

    try:
        conn = await _connect(request)
    except Unavailable:
        return JSONResponse(UNAVAILABLE, status_code=503)

    try:
        user_id = _user_id(request)
        removed = await podcasts.unsubscribe(conn, user_id, feed_url)
        return {"removed": bool(removed)}
    except (asyncpg.PostgresError, asyncpg.InterfaceError, OSError):
        return JSONResponse(UNAVAILABLE, status_code=503)
    finally:
        await conn.close()


@router.get("/v1/podcasts/episodes")
async def episodes(request: Request) -> Any:
    feed_url = request.query_params.get("feed_url")
    if not feed_url:
        return JSONResponse(INVALID_REQUEST, status_code=400)

    limit, err = _get_uint_param(request, "limit", 50)
    if err is not None:
        return err

    offset, err = _get_uint_param(request, "offset", 0)
    if err is not None:
        return err

    try:
        conn = await _connect(request)
    except Unavailable:
        return JSONResponse(UNAVAILABLE, status_code=503)

    try:
        user_id = _user_id(request)
        # FT-732: "from first episode"; unfamiliar order falls back to newest first.
        order = request.query_params.get("order")
        items = await podcast_new.episodes_ordered(
            conn,
            user_id,
            feed_url,
            order=order if order in podcast_new.ORDERS else "newest",
            limit=limit,
            offset=offset,
        )
        if items is None:
            return JSONResponse(NOT_SUBSCRIBED, status_code=404)
        return {"episodes": [_episode_wire(e) for e in items]}
    except (asyncpg.PostgresError, asyncpg.InterfaceError, OSError):
        return JSONResponse(UNAVAILABLE, status_code=503)
    finally:
        await conn.close()


@router.get("/v1/podcasts/new")
async def new_episodes(request: Request) -> Any:
    """FT-732: new episodes of all subscriptions — top of Podcasts section."""
    since: datetime | None = None
    raw = request.query_params.get("since")
    if raw is not None:
        since = _parse_since(raw)
        if since is None:
            return JSONResponse(INVALID_REQUEST, status_code=400)

    limit, err = _get_uint_param(request, "limit", 30)
    if err is not None:
        return err

    try:
        conn = await _connect(request)
    except Unavailable:
        return JSONResponse(UNAVAILABLE, status_code=503)

    try:
        items = await podcast_new.new_episodes(
            conn, _user_id(request), since=since, limit=limit
        )
        return {
            "episodes": [
                {"feed_url": e.feed_url, "feed_title": e.feed_title, **_episode_wire(e)}
                for e in items
            ]
        }
    except (asyncpg.PostgresError, asyncpg.InterfaceError, OSError):
        return JSONResponse(UNAVAILABLE, status_code=503)
    finally:
        await conn.close()


@router.get("/v1/podcasts/continue")
async def continue_episodes(request: Request) -> Any:
    """FT-755: started and unfinished podcast episodes with titles."""
    limit, err = _get_uint_param(request, "limit", 20)
    if err is not None:
        return err

    try:
        conn = await _connect(request)
    except Unavailable:
        return JSONResponse(UNAVAILABLE, status_code=503)

    try:
        items = await podcast_continue.continue_episodes(
            conn, _user_id(request), limit=limit
        )
        return {
            "episodes": [
                {
                    "feed_url": e.feed_url,
                    "feed_title": e.feed_title,
                    "position_ms": e.position_ms,
                    **_episode_wire(e),
                }
                for e in items
            ]
        }
    except (asyncpg.PostgresError, asyncpg.InterfaceError, OSError):
        return JSONResponse(UNAVAILABLE, status_code=503)
    finally:
        await conn.close()


@router.post("/v1/podcasts/progress")
async def progress_post(request: Request) -> Any:
    data, err = await _read_json_body(request, MAX_PROGRESS_BODY)
    if err is not None:
        return err

    entries = podcast_progress.from_wire(data)
    if entries is None:
        return JSONResponse(INVALID_REQUEST, status_code=400)
    if not entries:
        return {"items": []}

    try:
        conn = await _connect(request)
    except Unavailable:
        return JSONResponse(UNAVAILABLE, status_code=503)

    try:
        user_id = _user_id(request)
        saved = await podcast_progress.put(conn, user_id, entries)
        return podcast_progress.to_wire(saved)
    except (asyncpg.PostgresError, asyncpg.InterfaceError, OSError):
        return JSONResponse(UNAVAILABLE, status_code=503)
    finally:
        await conn.close()


@router.get("/v1/podcasts/progress")
async def progress_get(request: Request) -> Any:
    after, err = _get_uint_param(request, "after", 0)
    if err is not None:
        return err

    limit, err = _get_uint_param(request, "limit", 500)
    if err is not None:
        return err

    try:
        conn = await _connect(request)
    except Unavailable:
        return JSONResponse(UNAVAILABLE, status_code=503)

    try:
        user_id = _user_id(request)
        entries, mark = await podcast_progress.changes(
            conn, user_id, after=after, limit=limit
        )
        wire = podcast_progress.to_wire(entries)
        return {"items": wire["items"], "mark": mark}
    except (asyncpg.PostgresError, asyncpg.InterfaceError, OSError):
        return JSONResponse(UNAVAILABLE, status_code=503)
    finally:
        await conn.close()


def install_podcasts(
    app: FastAPI,
    *,
    database_url: str | None = None,
    client: httpx.AsyncClient | None = None,
    kick: Callable[[], None] | None = None,
) -> None:
    app.state.podcast_library = Library(app, database_url=database_url)
    app.state.podcast_client = client
    app.state.podcast_kick = kick
    app.include_router(router)
