"""FT-583: Artist's "Popular" does not parse the title anew for each of its recordings.

Lead's measurement on 05.10 on prod database (read-only): Metallica, ten Last.fm
songs — 24 s. Title parsing (`regexp_replace`: guest, release suffix, hyphen)
was in the join condition and was evaluated for each of the artist's ~20,000 recordings,
rather than once per title. The same response without it — 0.14 s.

The check inspects the query plan: `regexp_replace` is allowed only inside
a subquery that runs once (CTE), and not in any join condition
or filter of the main query. That the query returns the same result is verified by
test_top_tracks.py, test_top_featured.py, test_top_own_versions.py.
"""

from __future__ import annotations

import json

import asyncpg
import pytest

import app.local_search as local_search
from app.migrate import apply
from app.names import norm

CONDITIONS = ("Join Filter", "Filter", "Hash Cond", "Merge Cond", "Index Cond", "Recheck Cond")


def _offenders(node: dict, in_cte: bool = False) -> list[str]:
    in_cte = in_cte or str(node.get("Subplan Name", "")).startswith("CTE ")
    found = []
    if not in_cte:
        for key in CONDITIONS:
            if "regexp_replace" in str(node.get(key, "")):
                found.append(f"{node.get('Node Type')}: {key}")
    for child in node.get("Plans", []):
        found += _offenders(child, in_cte)
    return found


@pytest.fixture(autouse=True)
async def migrated(postgres_url: str):
    await apply(postgres_url)
    yield


async def test_title_parsing_runs_once_per_title_not_per_recording(postgres_url: str):
    titles = ["Enter Sandman", "Unholy (feat. Kim Petras)", "Pool - Stripped", "Dance The Night - From Barbie The Album"]
    conn = await asyncpg.connect(postgres_url)
    try:
        await conn.execute("SET enable_hashjoin = off; SET enable_mergejoin = off")
        raw = await conn.fetchval(
            "EXPLAIN (VERBOSE, FORMAT JSON) " + local_search.TOP_TRACKS_SQL.strip().rstrip(";"),
            "Metallica", titles, [norm(t) for t in titles], "Metallica", [], [],
        )
    finally:
        await conn.close()
    plan = (json.loads(raw) if isinstance(raw, str) else raw)[0]["Plan"]
    assert _offenders(plan) == [], (
        "title parsing is evaluated in join condition — for each recording of the artist "
        "(on prod Metallica: 24 s); extract into a CTE evaluated once"
    )
