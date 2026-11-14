"""Genre artists — from precomputed order, not a full table scan of `mb_artist` (FT-766).

Owner feedback 11.10: "Artists" of a genre take long to open. Production measurement 12.10:
first genre request after deployment — 55 s, subsequent — 0.5 s. The query on
every invocation joined `artist_genre` with `mb_artist` (1.5M rows) and after
restart read the entire table from disk. Now the order of genre artists
is materialized once — upon catalog publication — and the screen reads only that.

Guards:
- order and `total` are the same as the previous query (reference below), for all
  genres and pages;
- responds even when `mb_artist` and `artist_genre` are locked by another
  connection — meaning they are not read;
- catalog publication (`publish_catalog_open_names`) rebuilds the order itself,
  otherwise after a new dump the list would become stale.
"""

from __future__ import annotations

import asyncio

import asyncpg
from test_catalog_browse import _extension, _seed
from test_genre_alphabet import EXPECTED, _extra

from app.catalog_browse import genre_artists

# Previous `genre_artists` query (prior to FT-766) — reference for order and count.
REFERENCE = (
    "SELECT name, count(*) OVER () AS total FROM ("
    "  SELECT DISTINCT ON (lower(a.name)) a.name"
    "  FROM artist_genre g JOIN mb_artist a ON a.mbid = g.artist_mbid"
    "  LEFT JOIN catalog_open_names o ON o.name = a.name"
    "  WHERE g.is_primary AND g.slug = $1"
    "  AND (o.listed OR NOT EXISTS (SELECT 1 FROM catalog_open_names))"
    "  AND (o.mbid IS NULL OR o.mbid = g.artist_mbid)"
    "  ORDER BY lower(a.name), a.mbid"
    ") one ORDER BY CASE"
    "  WHEN name ~ '^[A-Za-zÀ-ÖØ-öø-ɏ]' THEN 0"
    "  WHEN name ~ '^[Ѐ-ӿ]' THEN 1 ELSE 2 END,"
    "  name COLLATE \"und-x-icu\", name LIMIT $2 OFFSET $3"
)

LATE = "5b11f4ce-0000-4000-8000-0000000002aa"


def _built(postgres_url: str) -> str:
    asyncio.run(_seed(postgres_url))
    asyncio.run(_extension().build_catalog(postgres_url))
    asyncio.run(_extra(postgres_url))
    return postgres_url


async def _reference(conn: asyncpg.Connection, slug: str, offset: int, limit: int) -> tuple[list[str], int]:
    rows = await conn.fetch(REFERENCE, slug, limit, offset)
    total = rows[0]["total"] if rows else 0
    return [r["name"] for r in rows], int(total)


def test_same_order_and_total_as_before(postgres_url: str) -> None:
    url = _built(postgres_url)

    async def run() -> None:
        conn = await asyncpg.connect(url)
        try:
            await conn.execute("SELECT public.build_catalog_genre_artists()")
            slugs = [r["slug"] for r in await conn.fetch("SELECT DISTINCT slug FROM artist_genre ORDER BY 1")]
            assert "rock" in slugs
            for slug in slugs:
                full = await _reference(conn, slug, 0, 1000)
                for offset, limit in ((0, 1000), (0, 3), (2, 5), (7, 4)):
                    names, total = await genre_artists(conn, slug, offset, limit)
                    want, _ = await _reference(conn, slug, offset, limit)
                    assert names == want, (slug, offset, limit)
                    assert total == full[1], (slug, offset, limit)
            names, total = await genre_artists(conn, "rock", 0, 50)
            assert names == EXPECTED and total == len(EXPECTED)
        finally:
            await conn.close()

    asyncio.run(run())


def test_answers_while_mb_tables_are_locked(postgres_url: str) -> None:
    url = _built(postgres_url)

    async def run() -> None:
        conn = await asyncpg.connect(url)
        locker = await asyncpg.connect(url)
        try:
            await conn.execute("SELECT public.build_catalog_genre_artists()")
            tx = locker.transaction()
            await tx.start()
            await locker.execute("LOCK TABLE mb_artist, artist_genre IN ACCESS EXCLUSIVE MODE")
            await conn.execute("SET statement_timeout = '3s'")
            try:
                names, total = await genre_artists(conn, "rock", 0, 50)
            except asyncpg.QueryCanceledError as error:  # pragma: no cover - failure mode
                raise AssertionError("genre still reads mb_artist/artist_genre on every call") from error
            finally:
                await tx.rollback()
            assert names == EXPECTED and total == len(EXPECTED)
        finally:
            await conn.close()
            await locker.close()

    asyncio.run(run())


def test_publication_rebuilds_the_order(postgres_url: str) -> None:
    url = _built(postgres_url)

    async def run() -> None:
        conn = await asyncpg.connect(url)
        try:
            await conn.execute("SELECT public.build_catalog_genre_artists()")
            # New dump: a genre artist appeared, catalog publication reveals them.
            await conn.execute(
                "INSERT INTO mb_artist (mbid, name, sort_name, ended) VALUES ($1, 'Amber Tide', 'Amber Tide', false)",
                LATE,
            )
            await conn.execute(
                "INSERT INTO artist_genre (artist_mbid, slug, source, score, is_primary)"
                " VALUES ($1, 'rock', 'mb', 5, true)",
                LATE,
            )
            await conn.execute("SELECT public.prepare_catalog_open_names()")
            await conn.execute("TRUNCATE pg_temp.catalog_open_names_pending")
            await conn.execute(
                "INSERT INTO pg_temp.catalog_open_names_pending (name, mbid, listed)"
                " SELECT name, mbid, listed FROM catalog_open_names"
                " UNION ALL SELECT 'Amber Tide', $1::uuid, true",
                LATE,
            )
            await conn.execute("SELECT public.publish_catalog_open_names()")
            names, total = await genre_artists(conn, "rock", 0, 50)
            assert "Amber Tide" in names
            assert names == (await _reference(conn, "rock", 0, 50))[0]
            assert total == len(names)
        finally:
            await conn.close()

    asyncio.run(run())
