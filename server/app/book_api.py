"""FT-725 (K2, P-A99, contract D5a): audiobook endpoints for the phone.

Connects existing parts: found items (`book_found`), passes for them (`book_refs`), shelving
(`book_shelving`), books and shelves (`books`), playback position (`book_position`).
Search, release files and part audio are supplied from outside (`install_books`).

Nothing about a book is written to the log: neither query, nor title, key, or hint.
`asset` and `hint` are not exposed externally.
"""

from __future__ import annotations

import json
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any
from uuid import UUID

import asyncpg
from fastapi import APIRouter, FastAPI, Request
from fastapi.responses import JSONResponse, Response

from app import book_position, books
from app.book_found import MAX_FOUND_BOOKS, FoundBook
from app.book_refs import BookRefs
from app.book_shelving import shelve_found
from app.library import UNAVAILABLE, Library, Unavailable

MAX_SMALL_BODY = 8 * 1024
MAX_POSITIONS_BODY = 2 * 1024 * 1024
MAX_QUERY = 200
MIN_QUERY = 2
DEFAULT_SEARCH_LIMIT = 20
MAX_PARAM_INT = 1 << 62

INVALID_REQUEST = {"status": "invalid_request"}
NOT_FOUND = {"status": "not_found"}
EXPIRED = {"status": "expired"}
SEARCH_UNAVAILABLE = {"status": "book_search_unavailable"}
FILES_UNAVAILABLE = {"status": "book_files_unavailable"}
PLAY_UNAVAILABLE = {"status": "book_play_unavailable"}

_DB_ERRORS = (asyncpg.PostgresError, asyncpg.InterfaceError, OSError)

SearchFn = Callable[[str, int], Awaitable[list[FoundBook]]]
FilesFn = Callable[[str, str], Awaitable[Any]]
PlayFn = Callable[
    [asyncpg.Connection, UUID, UUID, int], Awaitable["tuple[str, str] | None"]
]


@dataclass(frozen=True)
class _Hub:
    library: Library
    search: SearchFn
    files: FilesFn
    play: PlayFn
    refs: BookRefs[tuple[UUID, FoundBook]]
    space: int


router = APIRouter()


def _hub(request: Request) -> _Hub:
    return request.app.state.book_hub


def _user(request: Request) -> UUID:
    return UUID(str(request.state.user["id"]))


def _bad() -> JSONResponse:
    return JSONResponse(INVALID_REQUEST, status_code=400)


def _stamp(moment: datetime) -> str:
    utc = moment.astimezone(UTC) if moment.tzinfo else moment.replace(tzinfo=UTC)
    return f"{utc.strftime('%Y-%m-%dT%H:%M:%S')}.{utc.microsecond // 1000:03d}Z"


def _book_id(raw: str) -> UUID | None:
    if len(raw) != 36 or not raw.isascii():
        return None
    try:
        return UUID(raw)
    except ValueError:
        return None


def _uint(request: Request, name: str, default: int) -> int | None:
    if name not in request.query_params:
        return default
    raw = request.query_params[name]
    if not (1 <= len(raw) <= 19 and raw.isascii() and raw.isdigit()):
        return None
    return min(int(raw), MAX_PARAM_INT)


async def _body(request: Request, limit: int) -> Any:
    """Body is read as a stream with a limit; returns JSON or an error response."""
    declared = request.headers.get("content-length", "").strip()
    if declared:
        if not (declared.isascii() and declared.isdigit()):
            return _bad()
        if int(declared) > limit:
            return JSONResponse(INVALID_REQUEST, status_code=413)
    chunks: list[bytes] = []
    total = 0
    async for chunk in request.stream():
        total += len(chunk)
        if total > limit:
            return JSONResponse(INVALID_REQUEST, status_code=413)
        chunks.append(chunk)
    try:
        return json.loads(b"".join(chunks).decode("utf-8"))
    except (ValueError, RecursionError):
        return _bad()


async def _with_db(
    request: Request, work: Callable[[asyncpg.Connection], Awaitable[Any]]
) -> Any:
    try:
        conn = await _hub(request).library.connect()
    except Unavailable:
        return JSONResponse(UNAVAILABLE, status_code=503)
    try:
        return await work(conn)
    except _DB_ERRORS:
        return JSONResponse(UNAVAILABLE, status_code=503)
    finally:
        await conn.close()


def _book_wire(book: books.Book, shelved_at: datetime) -> dict[str, Any]:
    return {
        "id": str(book.id),
        "title": book.title,
        "author": book.author,
        "narrator": book.narrator,
        "year": book.year,
        "size_bytes": book.total_bytes,
        "parts": book.parts,
        "shelved_at": _stamp(shelved_at),
    }


async def _shelved(
    conn: asyncpg.Connection, user: UUID, book_id: UUID
) -> tuple[books.Book, datetime] | None:
    """A book from this user's shelf; another user's book and a non-existent one are indistinguishable."""
    row = await conn.fetchrow(
        "SELECT added_at FROM book_shelf WHERE user_id = $1 AND book_id = $2",
        user,
        book_id,
    )
    if row is None:
        return None
    book = await books.book(conn, book_id)
    return None if book is None else (book, row["added_at"])


# --- search ------------------------------------------------------------------


@router.get("/v1/books/search")
async def search(request: Request) -> Any:
    query = request.query_params.get("q", "").strip()
    if not (MIN_QUERY <= len(query) <= MAX_QUERY):
        return _bad()
    limit = _uint(request, "limit", DEFAULT_SEARCH_LIMIT)
    if limit is None or limit < 1:
        return _bad()
    limit = min(limit, MAX_FOUND_BOOKS)

    hub = _hub(request)
    try:
        found = await hub.search(query, limit)
        found = list(found)[:limit]
    except Exception:  # noqa: BLE001 - reason is not logged: it could contain the query
        return JSONResponse(SEARCH_UNAVAILABLE, status_code=503)

    user = _user(request)
    return {
        "books": [
            {
                "ref": hub.refs.put(f"{user}\x00{item.asset}", (user, item)),
                "title": item.title,
                "author": item.author,
                "narrator": item.narrator,
                "year": item.year,
                "size_bytes": item.size_bytes,
                "language": item.language,
            }
            for item in found
        ]
    }


# --- shelf -------------------------------------------------------------------


@router.get("/v1/books/shelf")
async def shelf_list(request: Request) -> Any:
    user = _user(request)

    async def work(conn: asyncpg.Connection) -> Any:
        rows = await books.shelf(conn, user)
        return {"books": [_book_wire(r.book, r.shelved_at) for r in rows]}

    return await _with_db(request, work)


@router.post("/v1/books/shelf")
async def shelf_add(request: Request) -> Any:
    data = await _body(request, MAX_SMALL_BODY)
    if isinstance(data, JSONResponse):
        return data
    ref = data.get("ref") if isinstance(data, dict) else None
    if not isinstance(ref, str):
        return _bad()

    hub = _hub(request)
    user = _user(request)
    entry = hub.refs.get(ref)
    if entry is None or entry[0] != user:
        return JSONResponse(EXPIRED, status_code=410)
    found = entry[1]

    async def work(conn: asyncpg.Connection) -> Any:
        outcome = await shelve_found(
            conn, user, found, files=hub.files, space=hub.space
        )
        if outcome.state in ("ok", "exists") and outcome.book is not None:
            got = await _shelved(conn, user, outcome.book.id)
            if got is not None:
                return {"state": outcome.state, "book": _book_wire(*got)}
            return JSONResponse(FILES_UNAVAILABLE, status_code=503)
        if outcome.state in ("no_space", "limit", "not_a_book"):
            return JSONResponse({"status": outcome.state}, status_code=409)
        return JSONResponse(FILES_UNAVAILABLE, status_code=503)

    return await _with_db(request, work)


@router.post("/v1/books/shelf/{book_id}/remove")
async def shelf_remove(request: Request, book_id: str) -> Any:
    parsed = _book_id(book_id)
    if parsed is None:
        return JSONResponse(NOT_FOUND, status_code=404)
    user = _user(request)

    async def work(conn: asyncpg.Connection) -> Any:
        if not await books.unshelve(conn, user, parsed):
            return JSONResponse(NOT_FOUND, status_code=404)
        return Response(status_code=204)

    return await _with_db(request, work)


# --- playback position (before "/v1/books/{id}" so routing does not treat it as an id) ---


@router.post("/v1/books/positions")
async def positions_put(request: Request) -> Any:
    data = await _body(request, MAX_POSITIONS_BODY)
    if isinstance(data, JSONResponse):
        return data
    entries = book_position.from_wire(data)
    if entries is None:
        return _bad()
    if not entries:
        return {"items": []}
    user = _user(request)

    async def work(conn: asyncpg.Connection) -> Any:
        return book_position.to_wire(await book_position.put(conn, user, entries))

    return await _with_db(request, work)


@router.get("/v1/books/positions")
async def positions_get(request: Request) -> Any:
    after = _uint(request, "after", 0)
    limit = _uint(request, "limit", book_position.MAX_BATCH)
    if after is None or limit is None or limit < 1:
        return _bad()
    limit = min(limit, book_position.MAX_BATCH)
    user = _user(request)

    async def work(conn: asyncpg.Connection) -> Any:
        entries, mark = await book_position.changes(
            conn, user, after=after, limit=limit
        )
        return {"items": book_position.to_wire(entries)["items"], "mark": mark}

    return await _with_db(request, work)


# --- book and audio ----------------------------------------------------------


@router.get("/v1/books/{book_id}")
async def details(request: Request, book_id: str) -> Any:
    parsed = _book_id(book_id)
    if parsed is None:
        return JSONResponse(NOT_FOUND, status_code=404)
    user = _user(request)

    async def work(conn: asyncpg.Connection) -> Any:
        got = await _shelved(conn, user, parsed)
        if got is None:
            return JSONResponse(NOT_FOUND, status_code=404)
        stored = await books.book_parts(conn, parsed)
        return {
            "book": _book_wire(*got),
            "parts": [
                {"number": p.number, "title": "", "start_ms": None, "end_ms": None}
                for p in stored
            ],
        }

    return await _with_db(request, work)


@router.post("/v1/books/{book_id}/play")
async def play_part(request: Request, book_id: str) -> Any:
    data = await _body(request, MAX_SMALL_BODY)
    if isinstance(data, JSONResponse):
        return data
    part = data.get("part") if isinstance(data, dict) else None
    if type(part) is not int:
        return _bad()
    parsed = _book_id(book_id)
    if parsed is None:
        return JSONResponse(NOT_FOUND, status_code=404)
    hub = _hub(request)
    user = _user(request)

    async def work(conn: asyncpg.Connection) -> Any:
        got = await _shelved(conn, user, parsed)
        if got is None or not 1 <= part <= got[0].parts:
            return JSONResponse(NOT_FOUND, status_code=404)
        try:
            played = await hub.play(conn, user, parsed, part)
        except _DB_ERRORS:
            raise
        except Exception:  # noqa: BLE001 - nothing about a book in logs
            played = None
        if played is None:
            return JSONResponse(PLAY_UNAVAILABLE, status_code=503)
        return {"token": played[0], "state": played[1]}

    return await _with_db(request, work)


def install_books(
    app: FastAPI,
    *,
    database_url: str | None,
    search: SearchFn,
    files: FilesFn,
    play: PlayFn,
    refs: BookRefs[tuple[UUID, FoundBook]] | None = None,
    space: int = books.DEFAULT_BOOK_SPACE,
) -> None:
    """Install book endpoints. In `main.py` — a single call."""
    app.state.book_hub = _Hub(
        library=Library(app, database_url=database_url),
        search=search,
        files=files,
        play=play,
        refs=refs if refs is not None else BookRefs(),
        space=space,
    )
    app.include_router(router)
