from __future__ import annotations

import argparse
import asyncio
import base64
import gzip
import json
import secrets
from datetime import datetime, timezone

import asyncpg
from fastapi import FastAPI, Query, Request
from fastapi.responses import JSONResponse, Response

PAGE_LIMIT = 10000
MAX_PAGE_BYTES = 64 * 1024 * 1024

SCHEMA_SQL = (
    "CREATE TABLE IF NOT EXISTS catalog_snapshot_generation (generation text PRIMARY KEY, published_at timestamptz NOT NULL DEFAULT now(), retired_at timestamptz);"
    "CREATE TABLE IF NOT EXISTS catalog_snapshot_artist (generation text NOT NULL, seq bigint NOT NULL, artist_id uuid NOT NULL, name text NOT NULL, country text, genre text, image text, PRIMARY KEY (generation, seq));"
    "CREATE TABLE IF NOT EXISTS catalog_snapshot_genre (generation text NOT NULL, slug text NOT NULL, name_en text NOT NULL, name_ru text NOT NULL, sort integer NOT NULL, PRIMARY KEY (generation, slug));"
)

INSERT_ARTISTS_SQL = """INSERT INTO catalog_snapshot_artist (generation, seq, artist_id, name, country, genre, image)
SELECT $1, row_number() OVER (ORDER BY a.name, a.mbid), a.mbid, a.name, c.iso, g.slug,
       CASE WHEN p.path IS NOT NULL AND coalesce(p.author, '') <> '' AND coalesce(p.license, '') <> '' THEN '/v1/photos/' || a.mbid::text END
FROM mb_artist a
LEFT JOIN artist_country c ON c.artist_mbid = a.mbid
LEFT JOIN artist_genre g ON g.artist_mbid = a.mbid AND g.is_primary
LEFT JOIN artist_photos p ON p.mbid = a.mbid
ORDER BY a.name, a.mbid"""

INSERT_GENRES_SQL = """INSERT INTO catalog_snapshot_genre (generation, slug, name_en, name_ru, sort)
SELECT $1, slug, name_en, name_ru, sort FROM our_genre ORDER BY sort, slug"""


def encode_cursor(generation: str, seq: int, page: int) -> str:
    return base64.urlsafe_b64encode(f"{generation}:{seq}:{page}".encode()).decode()


def decode_cursor(cursor: str) -> tuple[str, int, int]:
    try:
        parts = base64.urlsafe_b64decode(cursor.encode()).decode().split(":")
        if len(parts) == 3:
            return parts[0], int(parts[1]), int(parts[2])
    except Exception:
        pass
    raise ValueError("invalid cursor")


async def publish(database_url: str, generation: str | None = None) -> str:
    gen = generation or (datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S%f") + "_" + secrets.token_hex(4))
    conn = await asyncpg.connect(database_url)
    try:
        await conn.execute("SELECT pg_advisory_lock(742910482)")
        try:
            await conn.execute(SCHEMA_SQL)
        finally:
            await conn.execute("SELECT pg_advisory_unlock(742910482)")
        async with conn.transaction():
            await conn.execute("INSERT INTO catalog_snapshot_generation (generation, published_at) VALUES ($1, now())", gen)
            await conn.execute(INSERT_ARTISTS_SQL, gen)
            await conn.execute(INSERT_GENRES_SQL, gen)
        return gen
    finally:
        await conn.close()


async def handle_snapshot_request(
    request: Request, conn: asyncpg.Connection, generation: str | None = None, cursor: str | None = None
) -> Response:
    seq, page = 0, 1
    if cursor:
        try:
            cur_gen, seq, page = decode_cursor(cursor)
        except ValueError:
            return JSONResponse({"restart": True}, status_code=410)
        if generation and generation != cur_gen:
            return JSONResponse({"restart": True}, status_code=410)
        target_gen = cur_gen
        row = await conn.fetchrow("SELECT generation, retired_at FROM catalog_snapshot_generation WHERE generation = $1", target_gen)
        if not row or row["retired_at"] is not None:
            return JSONResponse({"restart": True}, status_code=410)
    else:
        if generation:
            target_gen = generation
            row = await conn.fetchrow("SELECT generation, retired_at FROM catalog_snapshot_generation WHERE generation = $1", target_gen)
            if not row:
                return JSONResponse({"status": "not_found"}, status_code=404)
            if row["retired_at"] is not None:
                return JSONResponse({"restart": True}, status_code=410)
        else:
            row = await conn.fetchrow(
                "SELECT generation, retired_at FROM catalog_snapshot_generation WHERE retired_at IS NULL ORDER BY published_at DESC, generation DESC LIMIT 1"
            )
            if not row:
                return JSONResponse({"status": "not_found"}, status_code=404)
            target_gen = row["generation"]

    etag = f'"{target_gen}:{page}"'
    inm = request.headers.get("if-none-match")
    if inm and (inm == etag or inm.strip('"') == etag.strip('"')):
        return Response(status_code=304, headers={"ETag": etag})

    genres = await conn.fetch("SELECT slug, name_en, name_ru FROM catalog_snapshot_genre WHERE generation = $1 ORDER BY sort, slug", target_gen)
    artists = await conn.fetch(
        "SELECT seq, artist_id::text, name, country, genre, image FROM catalog_snapshot_artist WHERE generation = $1 AND seq > $2 ORDER BY seq LIMIT 10001",
        target_gen, seq,
    )

    if len(artists) > PAGE_LIMIT:
        page_artists = artists[:PAGE_LIMIT]
        next_cursor = encode_cursor(target_gen, page_artists[-1]["seq"], page + 1)
    else:
        page_artists = artists
        next_cursor = None

    payload = {
        "generation": target_gen,
        "genres": [{"slug": r["slug"], "name_en": r["name_en"], "name_ru": r["name_ru"]} for r in genres],
        "artists": [
            {"artist_id": r["artist_id"], "name": r["name"], "country": r["country"], "genre": r["genre"], "image": r["image"]}
            for r in page_artists
        ],
        "cursor": next_cursor,
    }

    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    assert len(body) <= MAX_PAGE_BYTES, "page exceeded 64MiB"
    headers = {"ETag": etag}
    if "gzip" in request.headers.get("accept-encoding", "").lower():
        body = gzip.compress(body)
        headers["Content-Encoding"] = "gzip"

    return Response(content=body, status_code=200, headers=headers, media_type="application/json")


def install_catalog_snapshot(app: FastAPI, database_url: str | None = None) -> None:
    @app.get("/v1/catalog/snapshot")
    async def get_catalog_snapshot(
        request: Request, generation: str | None = Query(None), cursor: str | None = Query(None)
    ) -> Response:
        url = database_url or getattr(request.app.state, "database_url", None)
        if not url:
            return JSONResponse({"status": "catalog_unavailable"}, status_code=503)
        conn = await asyncpg.connect(url)
        try:
            return await handle_snapshot_request(request, conn, generation=generation, cursor=cursor)
        finally:
            await conn.close()


def create_snapshot_app(database_url: str) -> FastAPI:
    app = FastAPI(title="catalog-snapshot")
    install_catalog_snapshot(app, database_url=database_url)
    return app


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="python -m app.catalog_snapshot")
    sub = parser.add_subparsers(dest="cmd", required=True)

    pub = sub.add_parser("publish")
    pub.add_argument("--database-url", required=True)
    pub.add_argument("--generation", default=None)

    srv = sub.add_parser("serve")
    srv.add_argument("--database-url", required=True)
    srv.add_argument("--port", type=int, required=True)

    args = parser.parse_args(argv)
    if args.cmd == "publish":
        asyncio.run(publish(args.database_url, generation=args.generation))
        return 0
    elif args.cmd == "serve":
        import uvicorn
        uvicorn.run(create_snapshot_app(args.database_url), host="127.0.0.1", port=args.port, log_level="warning")
        return 0
    return 1


if __name__ == "__main__":
    import sys
    raise SystemExit(main(sys.argv[1:]))
