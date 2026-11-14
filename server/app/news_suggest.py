"""Empty feed suggestions (FT-580, Р-A83): artists the user listens to most frequently.

Contract:

- `GET /v1/news/suggestions` → `{"source": "history"|"popular", "artists": [{"id", "name"}]}`;
- `history`: artists from this user's `listens`, matched in `mb_artist` by
  case-insensitive name, more frequently played — higher, at most 10, excluding artists
  already followed; others' listens are not counted;
- no personal history — `popular`: popular artists from catalog (may be empty).

Boundaries are the same as feed (app/news.py): user's own history only, and neither
artist name nor suggestions content enters the log. Attached via a single line in
`install_news`.
"""

from __future__ import annotations

from typing import Any
from uuid import UUID

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

from app.news import Unavailable

# No more than ten suggestions needed on screen (FT-580 card scope).
LIMIT = 10

router = APIRouter()


# One artist per name: MusicBrainz can have multiple artists under the same name;
# pick the one with more recordings, breaking ties by lower mbid.
# LATERAL keeps the lookup on the lower(name) index: a plain JOIN on lower(a.name)
# was turned by the planner into a full scan of 3-million-row mb_artist (prod database
# 06.10: 9–12s vs 7ms for history and 0.5s for popular).
ONE_PER_NAME = """
    CROSS JOIN LATERAL (
        SELECT a.mbid, a.name
        FROM mb_artist a
        WHERE lower(a.name) = {key}
        ORDER BY (SELECT count(*) FROM mb_artist_credit_name cn
                  WHERE cn.artist_mbid = a.mbid) DESC,
                 a.mbid
        LIMIT 1
    ) k
"""

# Personal history: play count of the artist by this user, higher is ranked first.
# Already followed artists and others' listens do not enter suggestions.
HISTORY_SQL = f"""
    WITH plays AS (
        SELECT lower(artist) AS name_key, count(*) AS plays
        FROM listens
        WHERE user_id = $1
        GROUP BY lower(artist)
    )
    SELECT k.mbid, k.name
    FROM plays p
    {ONE_PER_NAME.format(key="p.name_key")}
    WHERE NOT EXISTS (
        SELECT 1 FROM news_follows f
        WHERE f.user_id = $1 AND f.artist_mbid = k.mbid
    )
    ORDER BY p.plays DESC, k.name
    LIMIT $2
"""

# No personal history: popular catalog artists — by popularity
# (app/search.py computes it the same way). Empty catalog yields empty list, not an error.
POPULAR_SQL = f"""
    WITH top AS (
        SELECT artist_key, sum(popularity) AS p
        FROM catalog_artists
        GROUP BY artist_key
        ORDER BY p DESC
        LIMIT 30
    )
    SELECT k.mbid, k.name
    FROM top t
    {ONE_PER_NAME.format(key="t.artist_key")}
    ORDER BY t.p DESC, k.name
    LIMIT $1
"""


@router.get("/v1/news/suggestions")
async def news_suggestions(request: Request) -> Any:
    news = request.app.state.news
    if not news.enabled:
        return JSONResponse({"enabled": False})
    try:
        conn = await news.connect()
    except Unavailable:
        return JSONResponse({"status": "news_unavailable"}, status_code=503)
    try:
        rows = await conn.fetch(HISTORY_SQL, UUID(request.state.user["id"]), LIMIT)
        source = "history"
        if not rows:
            rows = await conn.fetch(POPULAR_SQL, LIMIT)
            source = "popular"
        return {
            "source": source,
            "artists": [{"id": str(row["mbid"]), "name": row["name"]} for row in rows],
        }
    finally:
        await conn.close()
