"""Private, day-lived import reports and atomic, replay-safe library saves."""

from __future__ import annotations

import base64
import binascii
import json
import logging
from collections.abc import Callable
from typing import Any
from uuid import UUID, uuid4

import asyncpg
from fastapi import APIRouter, FastAPI, Request
from fastapi.responses import JSONResponse

from app.canonical import canonical_key
from app.import_formats import MAX_BYTES, ImportFormatError, parse_import
from app.import_match import match_rows
from app.import_messages import localized
from app.library import BAD_REQUEST, NOT_FOUND, UNAVAILABLE, Unavailable, _name, _owner, append_items
from app.store import persist_tracks

logger = logging.getLogger("apertonodo")
router = APIRouter()
_FAVORITES_NAMES = {
    "liked songs", "мне нравится", "любимые песни", "favorite songs", "favourite songs",
}
_MAX_BASE64 = 4 * ((MAX_BYTES + 2) // 3)
MAX_BODY_BYTES = _MAX_BASE64 + 64 * 1024
MAX_SAVE_BYTES = 1024 * 1024


async def _body(request: Request, limit: int) -> dict[str, Any] | None:
    # The body is counted while it is read: a gigabyte must not reach memory before the first check.
    declared = request.headers.get("content-length", "")
    if declared.isdigit() and int(declared) > limit:
        raise ImportFormatError("too_large", "Файл больше 10 МиБ.")
    chunks: list[bytes] = []
    size = 0
    async for chunk in request.stream():
        size += len(chunk)
        if size > limit:
            raise ImportFormatError("too_large", "Файл больше 10 МиБ.")
        chunks.append(chunk)
    try:
        body = json.loads(b"".join(chunks))
    except (ValueError, UnicodeError):
        return None
    return body if isinstance(body, dict) else None


def _format_error(exc: ImportFormatError, accept_language: str | None = None) -> JSONResponse:
    logger.warning("import: %s", type(exc).__name__)
    return JSONResponse(
        {"status": exc.code, "message": localized(str(exc), accept_language)},
        status_code=413 if exc.code == "too_large" else 422,
    )


async def _load(
    conn: asyncpg.Connection, report_id: str, owner: UUID, *, lock: bool = False,
) -> Any:
    try:
        key = UUID(report_id)
    except ValueError:
        return None
    return await conn.fetchrow(
        "SELECT report, saved FROM imports WHERE id = $1 AND user_id = $2 "
        "AND created_at >= now() - interval '1 day'" + (" FOR UPDATE" if lock else ""),
        key, owner,
    )


@router.post("/v1/imports")
async def import_create(request: Request) -> Any:
    lang = request.headers.get("accept-language")
    try:
        body = await _body(request, MAX_BODY_BYTES)
    except ImportFormatError as exc:
        return _format_error(exc, lang)
    if body is None or not isinstance(body.get("data"), str) or (
        body.get("name") is not None and not isinstance(body["name"], str)
    ):
        return _format_error(ImportFormatError("bad_file", "Не удалось прочитать файл."), lang)
    try:
        if len(body["data"]) > _MAX_BASE64:
            raise ImportFormatError("too_large", "Файл больше 10 МиБ.")
        try:
            data = base64.b64decode(body["data"], validate=True)
        except (binascii.Error, ValueError):
            raise ImportFormatError("bad_file", "Не удалось прочитать base64 файла.") from None
        lists = parse_import(body.get("name"), data, accept_language=lang)
    except ImportFormatError as exc:
        return _format_error(exc, lang)

    library = request.app.state.library
    try:
        conn = await library.connect()
    except Unavailable:
        return JSONResponse(UNAVAILABLE, status_code=503)
    try:
        report_id = uuid4()
        report: dict[str, Any] = {"id": str(report_id), "lists": []}
        shown: dict[str, dict[str, Any]] = {}
        for index, playlist in enumerate(lists):
            matches = await match_rows(conn, playlist.rows)
            rows = []
            for n, (row, match) in enumerate(zip(playlist.rows, matches, strict=True)):
                rows.append({
                    "n": n, "artist": row.artist, "title": row.title,
                    "status": match.status, "track": match.track,
                    "candidates": match.candidates,
                })
                if match.track is not None:
                    shown[match.track["id"]] = match.track
                for track in match.candidates:
                    shown[track["id"]] = track
            report["lists"].append({
                "index": index, "name": playlist.name,
                "favorites_hint": playlist.name.casefold() in _FAVORITES_NAMES,
                "total": len(rows),
                "found": sum(match.status == "found" for match in matches),
                "doubtful": sum(match.status == "doubtful" for match in matches),
                "missing": sum(match.status == "missing" for match in matches),
                "rows": rows,
            })
        # Do not return a report whose cards would disappear after a restart.
        await persist_tracks(library.database_url, list(shown.values()))
        async with conn.transaction():
            await conn.execute("DELETE FROM imports WHERE created_at < now() - interval '1 day'")
            await conn.execute(
                "INSERT INTO imports (id, user_id, report) VALUES ($1, $2, $3::jsonb)",
                report_id, _owner(request), json.dumps(report, ensure_ascii=False),
            )
        for track in shown.values():
            request.app.state.import_remember(track)
        return report
    except Exception as exc:
        logger.warning("import: %s", type(exc).__name__)
        return JSONResponse(UNAVAILABLE, status_code=503)
    finally:
        await conn.close()


@router.get("/v1/imports/{report_id}")
async def import_get(request: Request, report_id: str) -> Any:
    try:
        conn = await request.app.state.library.connect()
    except Unavailable:
        return JSONResponse(UNAVAILABLE, status_code=503)
    try:
        row = await _load(conn, report_id, _owner(request))
        if row is None:
            return JSONResponse(NOT_FOUND, status_code=404)
        return json.loads(row["report"])
    except Exception as exc:
        logger.warning("import: %s", type(exc).__name__)
        return JSONResponse(UNAVAILABLE, status_code=503)
    finally:
        await conn.close()


def _items(rows: list[dict[str, Any]], choices: dict[str, Any]) -> list[dict[str, Any]] | None:
    doubtful = {str(row["n"]): row for row in rows if row["status"] == "doubtful"}
    for key, choice in choices.items():
        if key not in doubtful or (choice is not None and (
            type(choice) is not int or not 0 <= choice < len(doubtful[key]["candidates"])
        )):
            return None
    items = []
    for row in rows:
        track = row["track"]
        if row["status"] == "doubtful":
            choice = choices.get(str(row["n"]), 0)
            track = None if choice is None else row["candidates"][choice]
        items.append(
            {**track, "track_id": track["id"]} if track is not None else
            {"track_id": None, "artist": row["artist"], "title": row["title"]}
        )
    return items


@router.post("/v1/imports/{report_id}/save")
async def import_save(request: Request, report_id: str) -> Any:
    lang = request.headers.get("accept-language")
    try:
        body = await _body(request, MAX_SAVE_BYTES)
    except ImportFormatError as exc:
        return _format_error(exc, lang)
    try:
        conn = await request.app.state.library.connect()
    except Unavailable:
        return JSONResponse(UNAVAILABLE, status_code=503)
    try:
        async with conn.transaction():
            owner = _owner(request)
            # The row lock serializes simultaneous retries, not just sequential ones.
            stored = await _load(conn, report_id, owner, lock=True)
            if stored is None:
                return JSONResponse(NOT_FOUND, status_code=404)
            if body is None:
                return JSONResponse(BAD_REQUEST, status_code=422)
            index, target, choices = body.get("list"), body.get("target"), body.get("choices", {})
            report = json.loads(stored["report"])
            if type(index) is not int or not 0 <= index < len(report["lists"]) or (
                target not in ("playlist", "favorites") or not isinstance(choices, dict)
            ):
                return JSONResponse(BAD_REQUEST, status_code=422)
            playlist = report["lists"][index]
            items = _items(playlist["rows"], choices)
            if items is None:
                return JSONResponse(BAD_REQUEST, status_code=422)
            saved = json.loads(stored["saved"])
            save_key = f"{index}:{target}"
            if save_key in saved:
                return saved[save_key]

            if target == "playlist":
                name = _name(playlist["name"])
                if name is None:
                    return JSONResponse(BAD_REQUEST, status_code=422)
                playlist_id = uuid4()
                await conn.execute(
                    "INSERT INTO playlists (id, name, user_id) VALUES ($1, $2, $3)",
                    playlist_id, name, owner,
                )
                await append_items(conn, playlist_id, items)
                counts = await conn.fetchrow(
                    "SELECT count(*) FILTER (WHERE NOT missing) AS added, "
                    "count(*) FILTER (WHERE missing) AS missing "
                    "FROM playlist_items WHERE playlist_id = $1", playlist_id,
                )
                answer = {
                    "target": target, "playlist_id": str(playlist_id), "name": name,
                    "added": counts["added"], "missing": counts["missing"],
                }
            else:
                tracks = [item for item in items if item["track_id"] is not None]
                # Import cards have no cover. As in favorite_add, a canonical
                # duplicate retains the old recording; only new favorites count.
                rows = [
                    (canonical_key(t["artist"], t["title"]), UUID(t["track_id"]),
                     t["title"], t["artist"], int(t.get("duration_ms") or 0))
                    for t in tracks
                ]
                added = 0
                if rows:
                    done = await conn.execute(
                        """
                        INSERT INTO favorites
                            (user_id, canonical_key, track_id, title, artist, duration_ms)
                        SELECT $1, batch.*
                        FROM unnest($2::text[], $3::uuid[], $4::text[], $5::text[], $6::int[])
                            AS batch(canonical_key, track_id, title, artist, duration_ms)
                        ON CONFLICT (user_id, canonical_key) DO NOTHING
                        """,
                        owner, *zip(*rows, strict=True),
                    )
                    added = int(done.rsplit(" ", 1)[1])
                answer = {
                    "target": target,
                    "added": added,
                    "missing": len(items) - len(tracks),
                }
            saved[save_key] = answer
            await conn.execute(
                "UPDATE imports SET saved = $2::jsonb WHERE id = $1",
                UUID(report_id), json.dumps(saved, ensure_ascii=False),
            )
            return answer
    except Exception as exc:
        logger.warning("import: %s", type(exc).__name__)
        return JSONResponse(UNAVAILABLE, status_code=503)
    finally:
        await conn.close()


def install_imports(app: FastAPI, *, remember: Callable[[dict[str, Any]], None]) -> None:
    app.state.import_remember = remember
    app.include_router(router)
