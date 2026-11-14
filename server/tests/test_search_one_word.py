"""FT-887: a one-word query that is not an exact artist name stays as fast as the full name.

On the production copy `/v1/search?q=Morricone` took ~2 s and `q=Ennio Morricone` ~0.35 s.
The time went into `RESOLVE_ARTIST_SQL` (app/catalog_browse.py), called by
`search.artists`: when no artist is named exactly like the query, its `sort_name` branch
ran `name % $1` through the trigram index at the default 0.3 threshold, i.e. rechecked
hundreds of thousands of artists whose names share a few common trigrams ("one", "con").
That branch now runs only for a query with a comma ("Morricone, Ennio"): without a comma
it can only find an artist that `exact_name` has already found.

Guarded here:
1. the answer: exact name, alias, sort name with a comma, and a miss resolve as before;
2. the shape: for a query without a comma the `sort_name` CTE is not executed
   (plan has `Actual Loops: 0`), for a query with a comma it is.
"""

from __future__ import annotations

import json
from typing import Any
from uuid import UUID

import asyncpg
import pytest

from app.catalog_browse import RESOLVE_ARTIST_SQL, resolve_artist_name
from app.migrate import apply

ENNIO = UUID(int=0x887_0001)
NOISE = UUID(int=0x887_0002)


@pytest.fixture
async def conn(postgres_url: str):
    await apply(postgres_url)
    c = await asyncpg.connect(postgres_url)
    try:
        await c.execute("TRUNCATE mb_artist, mb_artist_alias, mb_release_group, mb_release, mb_medium, mb_track CASCADE")
        await c.execute(
            "INSERT INTO mb_artist (mbid, name, sort_name) VALUES ($1, 'Ennio Morricone', 'Morricone, Ennio'), "
            "($2, 'Dino Morricone', 'Morricone, Dino')",
            ENNIO,
            NOISE,
        )
        await c.execute("INSERT INTO mb_artist_alias (artist_mbid, name) VALUES ($1, 'Maestro')", ENNIO)
        yield c
    finally:
        await c.close()


@pytest.mark.parametrize(
    ("query", "expected"),
    [
        ("Ennio Morricone", "Ennio Morricone"),  # exact name
        ("ennio morricone", "Ennio Morricone"),  # case
        ("Maestro", "Ennio Morricone"),  # alias
        ("Morricone, Ennio", "Ennio Morricone"),  # sort name, has a comma
        ("Morricone", None),  # one word, no artist is called so
        ("Morricon", None),  # typo
    ],
)
async def test_answer_unchanged(conn: asyncpg.Connection, query: str, expected: str | None) -> None:
    artist, _ = await resolve_artist_name(conn, query)
    assert (artist["name"] if artist else None) == expected


def _executed(plan: dict[str, Any], cte: str) -> bool:
    """Whether the CTE's scan ran at least once. A node that never ran has Actual Loops 0;
    a custom plan with a constant-false condition has no scan node at all."""
    found: list[bool] = []

    def walk(node: dict[str, Any], inside: bool) -> None:
        inside = inside or node.get("Subplan Name") == f"CTE {cte}"
        if inside and node.get("Node Type") in {"Seq Scan", "Bitmap Heap Scan", "Index Scan", "Bitmap Index Scan"}:
            found.append(node.get("Actual Loops", 0) > 0)
        for child in node.get("Plans", []):
            walk(child, inside)

    walk(plan, False)
    return any(found)


async def _plan(conn: asyncpg.Connection, query: str, mode: str) -> dict[str, Any]:
    await conn.execute(f"SET plan_cache_mode = {mode}")
    exact = query.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    raw = await conn.fetchval("EXPLAIN (ANALYZE, FORMAT JSON) " + RESOLVE_ARTIST_SQL, query, exact)
    return (json.loads(raw) if isinstance(raw, str) else raw)[0]["Plan"]


@pytest.mark.parametrize("mode", ["force_custom_plan", "force_generic_plan"])
async def test_sort_name_scan_only_for_a_comma(conn: asyncpg.Connection, mode: str) -> None:
    assert not _executed(await _plan(conn, "Morricone", mode), "sort_name")
    assert _executed(await _plan(conn, "Morricone, Ennio", mode), "sort_name")
