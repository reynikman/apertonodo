from __future__ import annotations

import logging
from typing import Any
from uuid import UUID

import asyncpg
from fastapi import APIRouter, FastAPI, Query, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field, model_validator

from app.canonical import canonical_key
from app.library import Library, Unavailable, _keys

logger = logging.getLogger("apertonodo")

UNAVAILABLE = {"status": "library_unavailable"}
NOT_FOUND = {"status": "not_found"}


class RatingIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    track_id: UUID
    stars: int | None = Field(default=None, ge=0, le=5, strict=True)
    disliked: bool | None = Field(default=None, strict=True)

    @model_validator(mode="before")
    @classmethod
    def check_inputs(cls, data: Any) -> Any:
        if isinstance(data, dict):
            if "stars" in data and data["stars"] is None:
                raise ValueError("stars cannot be None")
            if "disliked" in data and data["disliked"] is None:
                raise ValueError("disliked cannot be None")
            if "stars" not in data and "disliked" not in data:
                raise ValueError("either stars or disliked must be provided")
        return data

    @model_validator(mode="after")
    def check_semantics(self) -> RatingIn:
        if self.stars is not None and self.stars >= 1 and self.disliked is True:
            raise ValueError("stars >= 1 and disliked cannot both be true")
        return self


class RatingsOfIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    track_ids: list[UUID] = Field(default_factory=list, max_length=500)


class Ratings:
    def __init__(self, app: FastAPI, *, database_url: str | None) -> None:
        self.app = app
        self.database_url = database_url
        if database_url is not None:
            self.library = Library(app, database_url=database_url)
        else:
            self.library = getattr(app.state, "library", None) or Library(
                app, database_url=None
            )

    async def connect(self) -> asyncpg.Connection:
        if not self.database_url:
            raise Unavailable
        try:
            return await asyncpg.connect(self.database_url)
        except Exception as exc:  # noqa: BLE001
            logger.warning("ratings: database failed: %s", type(exc).__name__)
            raise Unavailable from None


router = APIRouter()


def _ratings(request: Request) -> Ratings:
    return request.app.state.ratings


def _owner(request: Request) -> UUID:
    return UUID(str(request.state.user["id"]))


async def _open(request: Request) -> tuple[Ratings, asyncpg.Connection]:
    ratings = _ratings(request)
    return ratings, await ratings.connect()


def _unavailable() -> JSONResponse:
    return JSONResponse(UNAVAILABLE, status_code=503)


@router.post("/v1/ratings")
async def rate(request: Request, body: RatingIn) -> Any:
    try:
        ratings, conn = await _open(request)
    except Unavailable:
        return _unavailable()
    try:
        track = await ratings.library.track(body.track_id)
        if track is None:
            return JSONResponse(NOT_FOUND, status_code=404)

        user_id = _owner(request)
        c_key = canonical_key(track["artist"], track["title"])

        if body.disliked is True:
            new_stars = 0
            new_disliked = True
        elif body.stars is not None and body.stars >= 1:
            new_stars = body.stars
            new_disliked = False
        else:
            await conn.execute(
                "DELETE FROM ratings WHERE user_id = $1 AND canonical_key = $2",
                user_id,
                c_key,
            )
            return {"stars": 0, "disliked": False}

        await conn.execute(
            """
            INSERT INTO ratings (
                user_id, canonical_key, track_id, title, artist, duration_ms, stars, disliked, rated_at
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, now())
            ON CONFLICT (user_id, canonical_key) DO UPDATE
            SET track_id = EXCLUDED.track_id,
                title = EXCLUDED.title,
                artist = EXCLUDED.artist,
                duration_ms = EXCLUDED.duration_ms,
                stars = EXCLUDED.stars,
                disliked = EXCLUDED.disliked,
                rated_at = now()
            """,
            user_id,
            c_key,
            body.track_id,
            track["title"],
            track["artist"],
            int(track.get("duration_ms") or 0),
            new_stars,
            new_disliked,
        )
        return {"stars": new_stars, "disliked": new_disliked}
    finally:
        await conn.close()


@router.post("/v1/ratings/of")
async def ratings_of(request: Request, body: RatingsOfIn) -> Any:
    try:
        ratings, conn = await _open(request)
    except Unavailable:
        return _unavailable()
    try:
        if not body.track_ids:
            return {"ratings": {}}

        user_id = _owner(request)
        keys = await _keys(ratings.library, conn, body.track_ids)
        canonical_keys = list({k for k in keys.values() if k})

        rows = await conn.fetch(
            """
            SELECT canonical_key, track_id, stars, disliked
            FROM ratings
            WHERE user_id = $1 AND (canonical_key = ANY($2::text[]) OR track_id = ANY($3::uuid[]))
            """,
            user_id,
            canonical_keys,
            body.track_ids,
        )

        by_key = {
            row["canonical_key"]: {
                "stars": int(row["stars"]),
                "disliked": bool(row["disliked"]),
            }
            for row in rows
        }
        by_track_id = {
            str(row["track_id"]): {
                "stars": int(row["stars"]),
                "disliked": bool(row["disliked"]),
            }
            for row in rows
        }

        result: dict[str, dict[str, Any]] = {}
        for track_id in body.track_ids:
            str_id = str(track_id)
            c_key = keys.get(str_id)
            if c_key and c_key in by_key:
                result[str_id] = by_key[c_key]
            elif str_id in by_track_id:
                result[str_id] = by_track_id[str_id]

        return {"ratings": result}
    finally:
        await conn.close()


@router.get("/v1/ratings")
async def list_ratings(
    request: Request,
    min_stars: int = Query(default=1, ge=1, le=5),
    disliked: bool = Query(default=False),
    limit: int = Query(default=100, ge=1, le=500),
    offset: int = Query(default=0, ge=0),
) -> Any:
    try:
        ratings, conn = await _open(request)
    except Unavailable:
        return _unavailable()
    try:
        user_id = _owner(request)
        if disliked:
            where_clause = "user_id = $1 AND disliked = true"
            count_args: list[Any] = [user_id]
            rows_args: list[Any] = [user_id, offset, limit]
            fetch_query = f"""
                SELECT * FROM ratings
                WHERE {where_clause}
                ORDER BY rated_at DESC, canonical_key
                OFFSET $2 LIMIT $3
            """
        else:
            where_clause = "user_id = $1 AND disliked = false AND stars >= $2"
            count_args = [user_id, min_stars]
            rows_args = [user_id, min_stars, offset, limit]
            fetch_query = f"""
                SELECT * FROM ratings
                WHERE {where_clause}
                ORDER BY stars DESC, rated_at DESC, canonical_key
                OFFSET $3 LIMIT $4
            """

        total = await conn.fetchval(
            f"SELECT count(*) FROM ratings WHERE {where_clause}",
            *count_args,
        )

        rows = await conn.fetch(fetch_query, *rows_args)
        tracks = await ratings.library.public(conn, rows)
        for track, row in zip(tracks, rows, strict=True):
            track["stars"] = int(row["stars"])
            track["disliked"] = bool(row["disliked"])

        return {"tracks": tracks, "total": int(total)}
    finally:
        await conn.close()


def install_ratings(app: FastAPI, *, database_url: str | None = None) -> None:
    db_url = (
        database_url
        if database_url is not None
        else getattr(getattr(app.state, "library", None), "database_url", None)
    )
    app.state.ratings = Ratings(app, database_url=db_url)
    app.include_router(router)
