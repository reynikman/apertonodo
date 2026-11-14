"""Genre catalog from extension exports (FT-757, FT-594c, P8).

Builds the `catalog_artists` table from streaming exports of `GET /v1/catalog`
of all connected extensions that declare the `catalog` capability in `/v1/info`.
"""

from __future__ import annotations

import json
import logging
import unicodedata
from collections import Counter, defaultdict
from collections.abc import AsyncIterator
from dataclasses import dataclass

import asyncpg
import httpx

from app.catalog import MAX_ARTIST_CHARS, NOT_ARTISTS, letter_of
from app.genres import GENRE_NAMES
from app.names import norm

# The first line of the export does not arrive right away: the source first counts the request over
# millions of rows (measured 13.10 at production sizes: 764 thousand rows in 43–51 s).
# The default httpx timeout, 5 s per read, would silently keep the old catalog.
CATALOG_TIMEOUT = httpx.Timeout(600.0, connect=5.0)

logger = logging.getLogger("apertonodo")

MAX_LINE_BYTES = 64 * 1024


async def _iter_lines(
    resp: httpx.Response,
    max_line_bytes: int = MAX_LINE_BYTES,
) -> AsyncIterator[bytes]:
    buffer = bytearray()
    discarding = False

    async for chunk in resp.aiter_bytes():
        # Index through chunk: slicing remainder after each line would copy chunk
        # anew — quadratic in its size (1 MiB chunks took 27 s for 2M lines).
        start = 0
        while True:
            pos = chunk.find(b"\n", start)
            if pos == -1:
                rest = len(chunk) - start
                if discarding:
                    pass
                elif len(buffer) + rest > max_line_bytes:
                    buffer.clear()
                    discarding = True
                else:
                    buffer += chunk[start:]
                break
            if discarding:
                discarding = False
            elif len(buffer) + pos - start <= max_line_bytes:
                if buffer:
                    buffer += chunk[start:pos]
                    yield bytes(buffer)
                else:
                    yield chunk[start:pos]
            buffer.clear()
            start = pos + 1

    if buffer and not discarding and len(buffer) <= max_line_bytes:
        yield bytes(buffer)


@dataclass(frozen=True)
class BuildResult:
    status: str
    artists: int
    genres: int
    reason: str | None = None


async def build(
    database_url: str,
    urls: dict[str, str],
    *,
    client: httpx.AsyncClient,
) -> BuildResult:
    popularity: dict[tuple[str, str], int] = defaultdict(int)
    spellings: dict[str, Counter[str]] = defaultdict(Counter)

    for name, raw_url in urls.items():
        base_url = raw_url.rstrip("/")

        try:
            info_resp = await client.get(f"{base_url}/v1/info")
        except Exception as exc:
            logger.warning(
                "catalog_from_extensions: %s: info request failed: %s",
                name,
                type(exc).__name__,
            )
            return BuildResult(status="kept", artists=0, genres=0, reason="info_failed")

        if info_resp.status_code != 200:
            logger.warning(
                "catalog_from_extensions: %s: info status %d",
                name,
                info_resp.status_code,
            )
            return BuildResult(status="kept", artists=0, genres=0, reason="info_failed")

        try:
            info_data = info_resp.json()
        except Exception:
            logger.warning(
                "catalog_from_extensions: %s: info response not json",
                name,
            )
            return BuildResult(status="kept", artists=0, genres=0, reason="info_failed")

        if not isinstance(info_data, dict):
            logger.warning(
                "catalog_from_extensions: %s: info response not json object",
                name,
            )
            return BuildResult(status="kept", artists=0, genres=0, reason="info_failed")

        features = info_data.get("features")
        if not isinstance(features, (list, tuple, set)) or "catalog" not in features:
            logger.info(
                "catalog_from_extensions: %s: no catalog feature, skipped", name
            )
            continue

        ext_rows = 0
        try:
            async with client.stream(
                "GET", f"{base_url}/v1/catalog", timeout=CATALOG_TIMEOUT
            ) as resp:
                if resp.status_code == 404:
                    logger.info(
                        "catalog_from_extensions: %s: catalog 404, skipped", name
                    )
                    continue
                if resp.status_code != 200:
                    logger.warning(
                        "catalog_from_extensions: %s: catalog failed with status %d",
                        name,
                        resp.status_code,
                    )
                    return BuildResult(
                        status="kept", artists=0, genres=0, reason="catalog_failed"
                    )

                async for raw_line in _iter_lines(resp):
                    line_bytes = raw_line.strip(b"\r\n \t")
                    if not line_bytes:
                        continue
                    try:
                        data = json.loads(line_bytes)
                    except Exception:
                        continue
                    if not isinstance(data, dict):
                        continue

                    genre = data.get("genre")
                    if not isinstance(genre, str) or genre not in GENRE_NAMES:
                        continue

                    pop = data.get("popularity")
                    if isinstance(pop, bool) or not isinstance(pop, int) or pop < 0:
                        continue

                    artist = data.get("artist")
                    if not isinstance(artist, str):
                        continue

                    name_clean = artist.strip()
                    if not name_clean or len(name_clean) > MAX_ARTIST_CHARS:
                        continue

                    if any(unicodedata.category(c) in ("Cc", "Cs") for c in artist):
                        continue

                    key = norm(name_clean)
                    if not key or key in NOT_ARTISTS:
                        continue

                    popularity[(genre, key)] += pop
                    spellings[key][name_clean] += 1
                    ext_rows += 1
        except Exception as exc:
            logger.warning(
                "catalog_from_extensions: %s: catalog stream error: %s",
                name,
                type(exc).__name__,
            )
            return BuildResult(
                status="kept", artists=0, genres=0, reason="stream_failed"
            )

        logger.info("catalog_from_extensions: %s: read %d valid rows", name, ext_rows)

    if not popularity:
        logger.info("catalog_from_extensions: nothing to build, old catalog kept")
        return BuildResult(status="kept", artists=0, genres=0, reason="empty")

    rows = [
        (
            genre,
            key,
            spellings[key].most_common(1)[0][0],
            letter_of(key),
            min(total, 2**31 - 1),
        )
        for (genre, key), total in popularity.items()
    ]

    genres_count = len({genre for genre, _key in popularity})

    conn = await asyncpg.connect(database_url)
    try:
        async with conn.transaction():
            await conn.execute("SELECT pg_advisory_xact_lock(17017)")
            await conn.execute("DELETE FROM catalog_artists")
            await conn.copy_records_to_table(
                "catalog_artists",
                records=rows,
                columns=("genre", "artist_key", "name", "letter", "popularity"),
            )
            await conn.execute("SELECT public.refresh_catalog_open_names()")
            await conn.execute(
                "INSERT INTO catalog_built (id, built_at) VALUES (1, now()) "
                "ON CONFLICT (id) DO UPDATE SET built_at = EXCLUDED.built_at"
            )
    finally:
        await conn.close()

    logger.info(
        "catalog_from_extensions: built %d artists across %d genres",
        len(rows),
        genres_count,
    )
    return BuildResult(status="built", artists=len(rows), genres=genres_count)
