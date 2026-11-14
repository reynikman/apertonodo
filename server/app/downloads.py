"""Owner-scoped durable downloads; acquisition and encoding are shared with Play."""

from __future__ import annotations

import asyncio
import logging
import re
import time
from collections.abc import AsyncIterator, Awaitable, Callable
from concurrent.futures import Future
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any
from uuid import UUID

import asyncpg
from fastapi import FastAPI, Request
from fastapi.responses import FileResponse, JSONResponse, Response
from pydantic import BaseModel, Field

from app import failures
from app.library import Unavailable, _owner
from app.store import token_hash
from app.variants import VariantFailed

logger = logging.getLogger("apertonodo")
REPIN_S = 600.0  # retry pins in extensions: once on startup, then every ten minutes
MEDIA_TYPES = {"mp3": "audio/mpeg", "opus": "audio/ogg", "flac": "audio/flac", "m4a": "audio/mp4"}
_FILE_PATH = re.compile(r"^(/v1/downloads/)[^/?]+(/file)(?=[/?]|$)")


class DownloadFailed(Exception):
    """A fixed, private log reason, never an upstream exception message."""


class DownloadAccessFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        # The new file route carries a track ID; redact even rejected requests.
        if isinstance(record.args, tuple) and len(record.args) == 5:
            client, method, path, version, status = record.args
            record.args = (client, method, _FILE_PATH.sub(r"\1…\2", str(path)), version, status)
        return True


class DownloadsIn(BaseModel):
    track_ids: list[UUID] = Field(min_length=1, max_length=500)


def _public(row: Any) -> dict[str, Any]:
    ready = row["state"] == "ready"
    return {
        "track_id": str(row["track_id"]), "state": row["state"],
        "format": row["format"] if ready else None,
        "bytes": row["bytes"] if ready else None,
    }


class Downloads:
    def __init__(
        self, database_url: str | None, *, poll_s: float,
        acquire: Callable[[str, str], Awaitable[dict[str, Any]]],
        prepare: Callable[[dict[str, Any]], Awaitable[tuple[Path, str] | Future[Path | None] | None]],
        pin: Callable[[str, bool], Awaitable[None]] | None = None,
    ) -> None:
        self.pin = pin
        self.database_url = database_url
        self.poll_s = poll_s
        self.acquire = acquire
        self.prepare = prepare
        self.encoding: dict[int, Future[Path | None]] = {}

    @asynccontextmanager
    async def connect(self) -> AsyncIterator[Any]:
        if not self.database_url:
            raise Unavailable
        conn = None
        try:
            conn = await asyncpg.connect(self.database_url)
            yield conn
        except Exception as exc:
            logger.warning("downloads: database failed: %s", type(exc).__name__)
            raise Unavailable from None
        finally:
            if conn is not None:
                await conn.close()

    async def pin_extension(self, asset: str, pinned: bool, ref: str) -> None:
        """Pinning in extension: error is a log line, not sent to the phone."""
        if self.pin is None:
            return
        try:
            await self.pin(asset, pinned)
        except Exception as exc:  # noqa: BLE001
            name = asset.partition(":")[0]
            logger.warning(
                "%s: extension %s %s failed: %s", ref, name, "pin" if pinned else "unpin", type(exc).__name__
            )

    async def start(self, row: dict[str, Any], source: dict[str, Any]) -> dict[str, Any] | None:
        async with self.connect() as conn, conn.transaction():
            # Serialize pin changes with remove, without holding a lock during I/O.
            await conn.fetchval("SELECT id FROM users WHERE id = $1 FOR UPDATE", row["user_id"])
            updated = await conn.fetchrow(
                """UPDATE downloads SET state = 'preparing', media_path = $2, asset = $3
                   WHERE id = $1 AND state = 'queued' RETURNING *""",
                row["id"], source.get("media_path"), source.get("asset"),
            )
            if updated is None:
                return None  # Removed, possibly re-enqueued with a different job ID.
        if updated["asset"]:
            ref = "download " + token_hash(f"{row['user_id']}:{row['track_id']}")[:8]
            await self.pin_extension(updated["asset"], True, ref)
        return dict(updated)

    async def finish(self, row: dict[str, Any], path: Path, format_: str) -> None:
        size = await asyncio.to_thread(lambda: path.stat().st_size)
        async with self.connect() as conn:
            await conn.execute(
                """UPDATE downloads SET state = 'ready', media_path = $2, format = $3, bytes = $4
                   WHERE id = $1 AND state = 'preparing'""",
                row["id"], str(path), format_, size,
            )

    async def fail(self, row: dict[str, Any], reason: str) -> None:
        async with self.connect() as conn:
            changed = await conn.fetchval(
                """UPDATE downloads SET state = 'failed', format = NULL, bytes = NULL
                   WHERE id = $1 AND state IN ('queued', 'preparing') RETURNING id""",
                row["id"],
            )
        if changed is None:
            return
        ref = "download " + token_hash(f"{row['user_id']}:{row['track_id']}")[:8]
        logger.warning("%s: failed: %s", ref, reason)
        await failures.note(
            self.database_url, kind="download_failed", user_id=row["user_id"],
            track_id=str(row["track_id"]), ref=ref,
        )

    async def step(self, row: dict[str, Any]) -> None:
        try:
            if row["state"] == "queued":
                ref = "download " + token_hash(f"{row['user_id']}:{row['track_id']}")[:8]
                source = await self.acquire(str(row["track_id"]), ref)
                updated = await self.start(row, source)
                if updated is None:
                    return
                row = updated
            job = self.encoding.get(row["id"])
            if job is None:
                result = await self.prepare(row)
                if result is None:
                    return  # The source is not ready yet.
                if isinstance(result, Future):
                    self.encoding[row["id"]] = result
                    return  # Do not stall acquisition or polling behind Opus compression.
                path, format_ = result
            else:
                if not job.done():
                    return
                converted = job.result()
                if converted is None:
                    raise DownloadFailed("conversion failed")
                path = converted
                format_ = path.suffix.lstrip(".")
            await self.finish(row, path, format_)
            self.encoding.pop(row["id"], None)
        except Unavailable:
            raise  # Database failure leaves durable work retryable.
        except Exception as exc:
            self.encoding.pop(row["id"], None)
            reason = str(exc) if isinstance(exc, (DownloadFailed, VariantFailed)) else type(exc).__name__
            await self.fail(row, reason)

    async def repin(self) -> None:
        """Retry pins for live downloads: extension could have lost them (new db, failed call)."""
        if self.pin is None:
            return
        async with self.connect() as conn:
            assets = await conn.fetch(
                "SELECT DISTINCT asset FROM downloads WHERE asset IS NOT NULL AND state IN ('preparing', 'ready')"
            )
        for row in assets:
            await self.pin_extension(row["asset"], True, "repin")

    async def run(self) -> None:
        repinned_at: float | None = None
        while True:
            try:
                now = time.monotonic()
                if repinned_at is None or now - repinned_at >= REPIN_S:
                    repinned_at = now
                    await self.repin()
                async with self.connect() as conn:
                    rows = await conn.fetch(
                        """SELECT * FROM downloads WHERE state IN ('queued', 'preparing')
                           ORDER BY (state = 'queued'), id"""
                    )
                active = {row["id"] for row in rows}
                self.encoding = {key: job for key, job in self.encoding.items() if key in active}
                for row in rows:
                    await self.step(dict(row))
            except Exception as exc:
                logger.warning("downloads: worker failed: %s", type(exc).__name__)
            await asyncio.sleep(self.poll_s)


def install_downloads(
    app: FastAPI, *, database_url: str | None, poll_s: float,
    acquire: Callable[[str, str], Awaitable[dict[str, Any]]],
    prepare: Callable[[dict[str, Any]], Awaitable[tuple[Path, str] | Future[Path | None] | None]],
    pin: Callable[[str, bool], Awaitable[None]] | None = None,
) -> Downloads:
    downloads = Downloads(database_url, poll_s=poll_s, acquire=acquire, prepare=prepare, pin=pin)
    access = logging.getLogger("uvicorn.access")
    if not any(isinstance(item, DownloadAccessFilter) for item in access.filters):
        access.addFilter(DownloadAccessFilter())

    @app.post("/v1/downloads", status_code=202)
    async def enqueue(body: DownloadsIn, request: Request) -> Any:
        owner, ids = _owner(request), list(dict.fromkeys(body.track_ids))
        try:
            async with downloads.connect() as conn, conn.transaction():
                await conn.execute(
                    """INSERT INTO downloads (user_id, track_id)
                       SELECT $1, id FROM unnest($2::uuid[]) AS ids(id)
                       ON CONFLICT (user_id, track_id) DO NOTHING""", owner, ids,
                )
                rows = await conn.fetch(
                    """SELECT * FROM downloads WHERE user_id = $1 AND track_id = ANY($2::uuid[])
                       ORDER BY array_position($2::uuid[], track_id)""", owner, ids,
                )
                return {"items": [_public(row) for row in rows]}
        except Unavailable:
            return JSONResponse({"status": "downloads_unavailable"}, status_code=503)

    @app.get("/v1/downloads")
    async def listing(request: Request) -> Any:
        try:
            async with downloads.connect() as conn:
                rows = await conn.fetch(
                    "SELECT * FROM downloads WHERE user_id = $1 ORDER BY created_at, id", _owner(request),
                )
                return {"items": [_public(row) for row in rows]}
        except Unavailable:
            return JSONResponse({"status": "downloads_unavailable"}, status_code=503)

    @app.api_route("/v1/downloads/{track_id}/file", methods=["GET", "HEAD"])
    async def file(track_id: UUID, request: Request) -> Response:
        try:
            async with downloads.connect() as conn:
                row = await conn.fetchrow(
                    "SELECT * FROM downloads WHERE user_id = $1 AND track_id = $2",
                    _owner(request), track_id,
                )
            if row is None:
                return JSONResponse({"status": "not_found"}, status_code=404)
            if row["state"] != "ready":
                return JSONResponse({"state": row["state"]}, status_code=409)
            path = Path(row["media_path"])
            stat = await asyncio.to_thread(path.stat)
            return FileResponse(path, media_type=MEDIA_TYPES[row["format"]], stat_result=stat)
        except Unavailable:
            return JSONResponse({"status": "downloads_unavailable"}, status_code=503)
        except OSError:
            return JSONResponse({"status": "file_unavailable"}, status_code=503)

    @app.post("/v1/downloads/remove", status_code=204)
    async def remove(body: DownloadsIn, request: Request) -> Response:
        owner = _owner(request)
        try:
            async with downloads.connect() as conn, conn.transaction():
                await conn.fetchval("SELECT id FROM users WHERE id = $1 FOR UPDATE", owner)
                removed = await conn.fetch(
                    "DELETE FROM downloads WHERE user_id = $1 AND track_id = ANY($2::uuid[]) RETURNING asset, track_id",
                    owner, list(dict.fromkeys(body.track_ids)),
                )
                released = []
                for asset in {row["asset"] for row in removed if row["asset"]}:
                    # Extension id is shared: unpin only when no user download holds it.
                    remaining = await conn.fetchval("SELECT 1 FROM downloads WHERE asset = $1 LIMIT 1", asset)
                    if not remaining:
                        track_id = next(row["track_id"] for row in removed if row["asset"] == asset)
                        released.append((asset, "download " + token_hash(f"{owner}:{track_id}")[:8]))
            for asset, ref in released:
                await downloads.pin_extension(asset, False, ref)
            return Response(status_code=204)
        except Unavailable:
            return JSONResponse({"status": "downloads_unavailable"}, status_code=503)

    return downloads
