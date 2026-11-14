"""Search over local catalog: artists, tracks, suggestions (Phase J).

Prior to this phase, `/v1/search` only queried MusicBrainz. The local catalog
was not involved in search at all — it was only checked upon pressing Play. This caused two issues:
query text was sent externally on every search, and results contained tracks
we did not have — user pressed Play and received `409 unresolved`.

What this module returns:

- `artists` — artists from `catalog_artists`. Only artists with an active source
  are stored here, so an "artist" result is never an empty promise.
  Typos handled via `pg_trgm` ("metalica" -> Metallica).
- `tracks` — tracks from `catalog_tracks`. Top Last.fm tracks filtered against
  local sources: only tracks with active sources are included (`catalog.build_tracks`).
- `suggest` — search suggestions as you type, matching prefix of artist name and track title.
  Queries strictly local tables and never calls external services.

No function in this module prints query text or makes network requests.

Result ranking: match quality first (exact -> prefix -> typo), and weight only
within equal match tiers. Weight formula (owner decision): source popularity plus Last.fm listeners.
Famous bands have millions of listeners but modest popularity numbers, so listeners dominate;
therefore match quality takes precedence over weight, otherwise exact queries would lose
to popular partial matches.
"""

from __future__ import annotations

import re
from typing import Any

import asyncpg

from app.catalog_browse import resolve_artist_name
from app.names import norm

# Prefixes shorter than 2 characters are meaningless: 'l' matches tens
# of thousands of names, exceeding the latency budget.
MIN_PREFIX = 2
# Limit of local rows fetched per category from DB. Mobile UI displays at most
# this many anyway, leaving room for MusicBrainz results.
LIMIT = 20


def like_prefix(key: str) -> str:
    r"""Prefix string for LIKE query. `norm` already stripped everything except words
    and spaces, so `%`, `_`, and `\` cannot occur."""
    return f"{key}%"


ARTISTS_SQL = """
WITH hit AS (
    SELECT artist_key,
           (array_agg(name ORDER BY popularity DESC))[1] AS name,
           sum(popularity) AS pop
    FROM catalog_artists
    WHERE artist_key LIKE $2 OR artist_key % $1
    GROUP BY artist_key
)
SELECT h.name,
       h.artist_key = $1 AS exact,
       h.artist_key LIKE $2 AS prefix,
       h.pop + coalesce(l.listeners, 0) AS weight
FROM hit h LEFT JOIN lastfm_artists l USING (artist_key)
WHERE NOT EXISTS (SELECT 1 FROM catalog_open_names)
   -- Ignore a stale mark until it overlaps the current own catalog.
   OR NOT EXISTS (
       SELECT 1 FROM catalog_artists c
       JOIN catalog_open_names o ON o.name = c.name
   )
   OR EXISTS (SELECT 1 FROM catalog_open_names o WHERE o.name = h.name)
ORDER BY exact DESC, prefix DESC, weight DESC, similarity(h.artist_key, $1) DESC, h.artist_key
LIMIT $3
"""


async def artists(conn: asyncpg.Connection, query: str, limit: int = LIMIT) -> list[dict[str, Any]]:
    """First exact copy artist, then open names from local catalog."""
    key = norm(query)
    if len(key) < MIN_PREFIX or limit <= 0:
        return []
    rows = await conn.fetch(ARTISTS_SQL, key, like_prefix(key), limit)
    seen: set[str] = set()
    out: list[dict[str, Any]] = []
    copy_artist, opens_with_albums = await resolve_artist_name(conn, query)
    if copy_artist is not None and opens_with_albums:
        name = str(copy_artist["name"])
        seen.add(name.casefold())
        out.append({"name": name})
    for row in rows:
        if len(out) >= limit:
            break
        name = str(row["name"])
        if name.casefold() in seen:
            continue
        seen.add(name.casefold())
        out.append({"name": name})
    return out


# `plainto_tsquery` joins words with AND: row matches only if all words
# are present. This handles queries like "linkin park numb" where words
# span both artist and title.
TRACKS_SQL = """
SELECT artist, title,
       title_key = $1 AS exact,
       to_tsvector('simple', artist_key || ' ' || title_key)
           @@ plainto_tsquery('simple', $1) AS all_words,
       weight
FROM catalog_tracks
WHERE title_key = $1
   OR title_key LIKE $2
   OR to_tsvector('simple', artist_key || ' ' || title_key) @@ plainto_tsquery('simple', $1)
ORDER BY exact DESC, all_words DESC, weight DESC, artist_key, title_key
LIMIT $3
"""


async def tracks(conn: asyncpg.Connection, query: str, limit: int = LIMIT) -> list[dict[str, Any]]:
    """Local tracks matching query: each pre-verified against active sources.

    "numb" and "linkin park numb" yield the same row: exact title match
    in the first case, all query words found in the second case, with highest
    weight artist ranked first.
    """
    key = norm(query)
    if not key:
        return []
    rows = await conn.fetch(TRACKS_SQL, key, like_prefix(key), limit)
    out = [{"artist": row["artist"], "title": row["title"]} for row in rows]
    exact = [item for item, row in zip(out, rows, strict=True) if row["exact"]]
    if len(exact) > 1:
        originals = await _originals(conn, exact)
        if originals:
            # Inside each group the order stays by weight.
            promoted = [item for item in exact if id(item) in originals]
            rest = [item for item in out if id(item) not in originals]
            return promoted + rest
    return out


_CREDIT_SPLIT = re.compile(r"\s&\s|\b(?:feat|ft|featuring)\b\.?", re.IGNORECASE)

# Start from the artist, in two steps, each on an index: exact `lower(name)` and the duet
# prefix "name & ..." use the btree `mb_artist_new_name_lower` (text_pattern_ops, the
# prefixes as separate constant LIKEs: the planner does not use it for LIKE ANY), then
# `song_artist`. A single join let the planner scan all of `song`. The title is compared
# in Python, through `norm`.
ARTISTS_OF_SQL = """
SELECT mbid, name FROM mb_artist WHERE lower(name) = ANY($1::text[]){prefixes}
"""

SONGS_OF_SQL = """
SELECT artist_mbid, title FROM song
WHERE artist_mbid = ANY($1::uuid[])
  AND work_mbid IS NOT NULL
  AND original_recording_mbid IS NOT NULL
"""


def _credit_parts(text: str) -> set[str]:
    """"Smokie & Chris Norman" -> {"smokie", "chris norman"}."""
    return {part for part in (norm(p) for p in _CREDIT_SPLIT.split(text)) if part}


def _credit_names(text: str) -> set[str]:
    """Names to look up in `mb_artist`: the whole credit and its parts, lower case.
    No split by comma: "Earth, Wind & Fire" is one artist."""
    names = {text.strip().lower()}
    names.update(p.strip().lower() for p in _CREDIT_SPLIT.split(text))
    return {n for n in names if n}


async def _originals(conn: asyncpg.Connection, items: list[dict[str, Any]]) -> set[int]:
    """`id()` of items whose song is the original in the MusicBrainz copy: the song has
    a work and a first studio recording. One query on the found candidates only.
    No copy (tables absent) or nothing found: empty set, the order stays as it was."""
    names = {name for item in items for name in _credit_names(item["artist"])}
    wanted = {norm(item["title"]) for item in items}
    # Escaped, because LIKE reads `%` and `_` in a raw name.
    likes = sorted(re.sub(r"([\\%_])", r"\\\1", name) + " & %" for name in names)
    sql = ARTISTS_OF_SQL.format(
        prefixes="".join(f" OR lower(name) LIKE ${n}" for n in range(2, len(likes) + 2))
    )
    try:
        artists = await conn.fetch(sql, sorted(names), *likes)
        if not artists:
            return set()
        rows = await conn.fetch(SONGS_OF_SQL, [row["mbid"] for row in artists])
    except asyncpg.UndefinedTableError:
        return set()
    credited = {row["mbid"]: row["name"] for row in artists}
    # title -> credited names of the artists holding an original of it
    found: dict[str, set[str]] = {}
    for row in rows:
        title = norm(row["title"])
        if title in wanted:
            found.setdefault(title, set()).update(_credit_parts(credited[row["artist_mbid"]]))
    return {
        id(item)
        for item in items
        if _credit_parts(item["artist"]) & found.get(norm(item["title"]), set())
    }


# Artists and tracks in a single query: two queries would double DB roundtrips,
# while the suggestion budget is under 100ms total.
SUGGEST_SQL = """
WITH hit AS (
    SELECT artist_key,
           (array_agg(name ORDER BY popularity DESC))[1] AS name,
           sum(popularity) AS pop
    FROM catalog_artists
    WHERE artist_key LIKE $1
    GROUP BY artist_key
)
SELECT h.name AS text, 0 AS kind, h.pop + coalesce(l.listeners, 0) AS weight
FROM hit h LEFT JOIN lastfm_artists l USING (artist_key)
UNION ALL
SELECT title, 1, weight FROM catalog_tracks WHERE title_key LIKE $1
ORDER BY kind, weight DESC, text
LIMIT $2
"""


async def suggest(conn: asyncpg.Connection, query: str, limit: int = 10) -> list[str]:
    """Search suggestions as you type: artist names and track titles by prefix.

    Strictly local DB. Neither MusicBrainz, Last.fm, nor any third party
    is notified of typing — this is an owner decision enforced by the absence of
    network calls in this function (guard — `tests/test_suggest.py`).
    """
    key = norm(query)
    if len(key) < MIN_PREFIX:
        return []
    rows = await conn.fetch(SUGGEST_SQL, like_prefix(key), limit)
    seen: set[str] = set()
    out: list[str] = []
    for row in rows:
        text = str(row["text"])
        if norm(text) in seen:
            continue
        seen.add(norm(text))
        out.append(text)
    try:
        if await conn.fetchval("SELECT EXISTS (SELECT 1 FROM mb_loads)"):
            from app import local_search
            for item in await local_search.suggest(conn, query, limit=limit):
                if norm(item) not in seen:
                    seen.add(norm(item))
                    out.append(item)
                    if len(out) >= limit:
                        break
    except Exception:
        pass
    return out
