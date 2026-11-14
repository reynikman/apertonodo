"""Local search across own MusicBrainz and catalog tables (Phase V5)."""

from __future__ import annotations

import re
from typing import Any

import asyncpg
from app.names import norm


def _similarity(s1: str, s2: str) -> float:
    p1, p2 = f"  {s1.lower()} ", f"  {s2.lower()} "
    t1 = {p1[i : i + 3] for i in range(len(p1) - 2)}
    t2 = {p2[i : i + 3] for i in range(len(p2) - 2)}
    return len(t1 & t2) / len(t1 | t2) if t1 and t2 else 0.0


def _escape_like(text: str) -> str:
    return text.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


# Details — cheap data only: per song and artist row. Previously all song
# versions and aliases were gathered for each candidate — on HDD this caused
# hundreds of random reads, 6.5s for "enter sandman" (benchmark 30.09).
# The version and alias matched by search are carried by the search itself
# (version_title, alias_name), while duration is fetched afterwards and only
# for top output rows (DURATIONS_SQL).
DETAILS_SQL = """
, grouped AS (
    SELECT song_id, array_remove(array_agg(DISTINCT version_title), NULL) AS version_titles,
           array_remove(array_agg(DISTINCT alias_name), NULL) AS alias_names, bool_or(top) AS top
    FROM candidate_ids GROUP BY song_id
)
SELECT s.id AS song_id, s.title, a.name AS artist, a.mbid::text AS artist_id,
       s.original_recording_mbid::text AS id, c.version_titles, c.alias_names, c.top,
       coalesce(ca.pop, 0) + coalesce(la.listeners, 0)::bigint AS weight,
       coalesce(la.found, false) AS lastfm_found
FROM grouped c
JOIN song s ON s.id = c.song_id
JOIN mb_artist a ON a.mbid = s.artist_mbid
LEFT JOIN LATERAL (SELECT sum(popularity)::bigint AS pop FROM catalog_artists WHERE artist_key = lower(a.name)) ca ON true
LEFT JOIN lastfm_artists la ON la.artist_key = lower(a.name)
LIMIT 300;
"""

DURATIONS_SQL = "SELECT mbid::text AS id, coalesce(length_ms, 0)::integer AS duration_ms FROM mb_recording WHERE mbid = ANY($1::uuid[])"


# Candidates — equality and lower-case prefix only: using
# btree `(lower(...) text_pattern_ops)`, milliseconds across 30–40M rows.
# Fuzzy `%` via trigram used to be the main path here and never fit the budget
# on the production replica: frequent trigrams yield millions of candidates
# to recheck (docs/troubleshooting.md, "MusicBrainz replica search"). It was
# retained only as a fallback path — FUZZY_CANDIDATES_SQL.
# "artist + title" in any order — via query splits ($3, $4):
# full artist name and title prefix among their songs.
SEARCH_CANDIDATES_SQL = """
WITH matched_songs AS (
    SELECT song_id FROM (
        (SELECT id AS song_id FROM song WHERE lower(title) = $1 LIMIT 60)
        UNION ALL (SELECT id FROM song WHERE lower(title) LIKE $2 LIMIT 30)
    ) u
),
matched_recordings AS (
    SELECT mbid, title FROM (
        (SELECT mbid, title FROM mb_recording WHERE lower(title) = $1 LIMIT 40)
        UNION ALL (SELECT mbid, title FROM mb_recording WHERE lower(title) LIKE $2 LIMIT 20)
    ) u
),
version_songs AS (
    SELECT DISTINCT ON (v.song_id) v.song_id, r.title FROM matched_recordings r
    JOIN song_version v ON v.recording_mbid = r.mbid LIMIT 40
),
-- Namesakes: the MusicBrainz replica holds multiple mbids for the same
-- name. Exact name match is sorted by artist song count in descending order
-- (index `song_artist`, count capped at 200) — previously LIMIT without
-- ORDER BY picked arbitrary rows, and the real Prince or Michael Jackson
-- might not be among them (docs/troubleshooting.md, #58). Song count is
-- only checked for the first 50 name matches: popular names have thousands,
-- and counting across all of them exceeds the budget.
matched_artists AS (
    SELECT mbid, name FROM (
        (SELECT mbid, name, 0 AS prio FROM (
            SELECT mbid, name FROM mb_artist WHERE lower(name) = $1 LIMIT 50
         ) a
         ORDER BY (SELECT count(*) FROM (SELECT 1 FROM song s WHERE s.artist_mbid = a.mbid LIMIT 200) x) DESC LIMIT 10)
        UNION ALL (SELECT mbid, name, 1 FROM mb_artist WHERE lower(name) LIKE $2 LIMIT 10)
    ) u ORDER BY prio LIMIT 10
),
matched_aliases AS (
    SELECT artist_mbid AS mbid, name FROM (
        SELECT artist_mbid, name FROM mb_artist_alias WHERE lower(name) = $1 LIMIT 50
    ) al
    ORDER BY (SELECT count(*) FROM (SELECT 1 FROM song s WHERE s.artist_mbid = al.artist_mbid LIMIT 200) x) DESC LIMIT 10
),
-- DISTINCT ON collapses namesakes to a single, most-played mbid per
-- name — otherwise single-song duplicates would remain alongside the real
-- artist and arbitrary _rank order would decide.
all_matched_artists AS (
    SELECT mbid, name, alias FROM (
        SELECT DISTINCT ON (lower(name)) mbid, name, alias, prio, song_count FROM (
            SELECT mbid, name, NULL::text AS alias, 0 AS prio,
                   (SELECT count(*) FROM (SELECT 1 FROM song s WHERE s.artist_mbid = ma.mbid LIMIT 200) x) AS song_count
            FROM matched_artists ma
            UNION ALL
            SELECT al.mbid, a.name, al.name, 1,
                   (SELECT count(*) FROM (SELECT 1 FROM song s WHERE s.artist_mbid = al.mbid LIMIT 200) x)
            FROM matched_aliases al JOIN mb_artist a ON a.mbid = al.mbid
        ) u ORDER BY lower(name), prio, song_count DESC
    ) d ORDER BY prio, song_count DESC LIMIT 4
),
artist_songs AS (
    SELECT s.id AS song_id, art.alias, s.top FROM all_matched_artists art
    LEFT JOIN lastfm_artists la ON la.artist_key = lower(art.name)
    -- uuids of the Last.fm list are pulled out once per artist (jsonb -> text -> uuid[]),
    -- not once per song. Works for the object shape {title: {"id": uuid}} and for an array.
    LEFT JOIN LATERAL (
        SELECT array_agg(m[1]::uuid) AS ids
        FROM regexp_matches(lower(la.top_track_ids::text),
                            '"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"', 'g') m
    ) t ON true
    CROSS JOIN LATERAL (
        SELECT s.id, coalesce(s.original_recording_mbid = ANY(t.ids), false) AS top
        FROM song s WHERE s.artist_mbid = art.mbid
        ORDER BY 2 DESC, s.id LIMIT 20
    ) s
),
splits AS (
    SELECT artist_part, title_pat FROM unnest($3::text[], $4::text[]) AS sp(artist_part, title_pat)
),
-- LATERAL rather than JOIN: the planner has no row count or value statistics
-- for unnest and selected hash join reading all 3M artists from HDD.
-- Same namesake handling, but when parsing "artist + title": without sorting
-- by song count LIMIT 10 could pick ten single-song duplicates and miss
-- the real one — then "prince purple rain" would return zero rows.
split_artists AS (
    SELECT DISTINCT mbid, title_pat, alias FROM (
        SELECT a.mbid, sp.title_pat, NULL::text AS alias FROM splits sp
        CROSS JOIN LATERAL (
            SELECT mbid FROM (SELECT mbid FROM mb_artist WHERE lower(name) = sp.artist_part LIMIT 50) b
            ORDER BY (SELECT count(*) FROM (SELECT 1 FROM song s WHERE s.artist_mbid = b.mbid LIMIT 200) x) DESC
            LIMIT 10
        ) a
        UNION ALL
        SELECT al.artist_mbid, sp.title_pat, al.name FROM splits sp
        CROSS JOIN LATERAL (
            SELECT artist_mbid, name FROM (
                SELECT artist_mbid, name FROM mb_artist_alias WHERE lower(name) = sp.artist_part LIMIT 50
            ) c
            ORDER BY (SELECT count(*) FROM (SELECT 1 FROM song s WHERE s.artist_mbid = c.artist_mbid LIMIT 200) x) DESC
            LIMIT 10
        ) al
    ) u LIMIT 20
),
split_songs AS (
    SELECT s.id AS song_id, sa.alias FROM split_artists sa
    CROSS JOIN LATERAL (
        SELECT id FROM song WHERE artist_mbid = sa.mbid AND lower(title) LIKE sa.title_pat LIMIT 10
    ) s
),
candidate_ids AS (
    SELECT song_id, NULL::text AS version_title, NULL::text AS alias_name, false AS top FROM matched_songs
    UNION ALL SELECT song_id, title, NULL, false FROM version_songs
    UNION ALL SELECT song_id, NULL, alias, top FROM artist_songs
    UNION ALL SELECT song_id, NULL, alias, false FROM split_songs
)
""" + DETAILS_SQL

# Fallback path for typos: only when exact path is nearly empty, with high
# similarity threshold and its own budget. If timed out — output stays exact.
FUZZY_CANDIDATES_SQL = """
WITH matched_songs AS (
    SELECT id AS song_id FROM song WHERE title % $1 LIMIT 50
),
-- Same namesake handling: trigram-similar names for a single word can be in
-- the thousands (production replica benchmark 30.09: "one" — 2663 names, "the" — 32380),
-- and counting songs across all of them took 1.4s for a single CTE on a 0.7s budget.
-- First 50 matches first, count only on them; DISTINCT ON
-- collapses namesakes to the most-played one.
matched_artists AS (
    SELECT mbid FROM (
        SELECT DISTINCT ON (lower(name)) mbid,
               (SELECT count(*) FROM (SELECT 1 FROM song s WHERE s.artist_mbid = a.mbid LIMIT 200) x) AS song_count
        FROM (SELECT mbid, name FROM mb_artist WHERE name % $1 LIMIT 50) a
        ORDER BY lower(name), song_count DESC
    ) d ORDER BY song_count DESC LIMIT 5
),
artist_songs AS (
    SELECT s.id AS song_id FROM matched_artists art
    CROSS JOIN LATERAL (SELECT id FROM song s WHERE s.artist_mbid = art.mbid ORDER BY id LIMIT 20) s
),
candidate_ids AS (
    SELECT song_id, NULL::text AS version_title, NULL::text AS alias_name, false AS top FROM matched_songs
    UNION ALL SELECT song_id, NULL, NULL, false FROM artist_songs
)
""" + DETAILS_SQL


FUZZY_BELOW = 5
MAX_SPLIT_WORDS = 8


def _splits(low: str) -> tuple[list[str], list[str]]:
    """All "artist + title prefix" splits in both orders."""
    parts = low.split()
    if len(parts) < 2 or len(parts) > MAX_SPLIT_WORDS:
        return [], []
    artists, titles = [], []
    for k in range(1, len(parts)):
        head, tail = " ".join(parts[:k]), " ".join(parts[k:])
        artists += [head, tail]
        titles += [f"{_escape_like(tail)}%", f"{_escape_like(head)}%"]
    return artists, titles


async def _fuzzy(conn: asyncpg.Connection, q: str) -> list[asyncpg.Record]:
    try:
        async with conn.transaction():
            await conn.execute("SET LOCAL statement_timeout = '700ms'")
            await conn.execute("SET LOCAL pg_trgm.similarity_threshold = 0.5")
            await conn.execute("SET LOCAL work_mem = '64MB'")
            return await conn.fetch(FUZZY_CANDIDATES_SQL, q)
    except asyncpg.QueryCanceledError:
        return []


async def search(conn: asyncpg.Connection, query: str, limit: int = 20) -> list[dict[str, Any]]:
    q = query.strip()
    q_norm = norm(q)
    words = [w for w in q_norm.split() if w]
    if not words and not any(ch in q for ch in ("%", "_")):
        return []
    low = q.lower()
    prefix = f"{_escape_like(low)}%"
    artist_parts, title_pats = _splits(low)
    async with conn.transaction():
        await conn.execute("SET LOCAL statement_timeout = '1500ms'")
        await conn.execute("SET LOCAL plan_cache_mode = force_custom_plan")
        rows = await conn.fetch(SEARCH_CANDIDATES_SQL, low, prefix, artist_parts, title_pats)
        if len(rows) < FUZZY_BELOW and words:
            seen = {row["song_id"] for row in rows}
            rows = [*rows, *(row for row in await _fuzzy(conn, q) if row["song_id"] not in seen)]
        scored = _rank(rows, q, q_norm, words)[: limit * 2]
        wanted = [item[-1]["id"] for item in scored if item[-1]["id"]]
        durations = {r["id"]: r["duration_ms"] for r in await conn.fetch(DURATIONS_SQL, wanted)} if wanted else {}
    return [
        {
            "song_id": item[-1]["song_id"],
            "title": item[-1]["title"],
            "artist": item[-1]["artist"],
            "artist_id": item[-1]["artist_id"],
            "id": item[-1]["id"],
            "duration_ms": durations.get(item[-1]["id"], 0),
            "artwork_url": "",
        }
        for item in scored[:limit]
    ]


def _rank(rows: list[asyncpg.Record], q: str, q_norm: str, words: list[str]) -> list[tuple[int, int, int, int, float, int, dict[str, Any]]]:
    scored: list[tuple[int, int, int, int, float, int, dict[str, Any]]] = []
    has_spec = "%" in q or "_" in q
    for row in rows:
        title, artist = str(row["title"] or ""), str(row["artist"] or "")
        versions = [str(v) for v in (row["version_titles"] or []) if v]
        aliases = [str(a) for a in (row["alias_names"] or []) if a]
        weight, song_id = int(row["weight"] or 0), int(row["song_id"])

        all_texts = [title, artist] + versions + aliases
        blob = f"{artist} {title} {' '.join(versions)} {' '.join(aliases)}"
        if has_spec and (("%" in q and "%" not in blob) or ("_" in q and "_" not in blob)):
            continue

        cands_norm = {norm(title), norm(artist), *(norm(v) for v in versions), *(norm(a) for a in aliases), norm(f"{artist} {title}"), norm(f"{title} {artist}")}
        cands_raw = {t.casefold() for t in all_texts} | {f"{artist.casefold()} {title.casefold()}", f"{title.casefold()} {artist.casefold()}"}
        # Matching artist name/alias separately from title match:
        # artist name alone, without Last.fm, is not considered "exact" —
        # otherwise obscure "One" would shadow Metallica "One"
        # (docs/troubleshooting.md, #58).
        name_norms = {norm(artist), *(norm(a) for a in aliases)}
        name_raw = {artist.casefold(), *(a.casefold() for a in aliases)}
        is_exact_name = (q_norm in name_norms) or (q.casefold() in name_raw)
        famous_name_match = is_exact_name and bool(row["lastfm_found"])
        is_exact_other = (q_norm in (cands_norm - name_norms)) or (q.casefold() in (cands_raw - name_raw))
        is_exact = is_exact_other or famous_name_match
        tokens = set(norm(blob).split())
        is_all_words = bool(words) and all(w in tokens for w in words)
        is_prefix = any(c.startswith(q_norm) for c in cands_norm if c) or any(c.startswith(q.casefold()) for c in cands_raw)

        sims = [_similarity(target, q) for target in all_texts]
        max_sim = max(sims) if sims else 0.0
        is_trgm = len(words) == 1 and max_sim >= 0.3
        if not (is_exact or is_all_words or is_prefix or is_trgm):
            continue

        rank = 1 if is_exact else (2 if is_all_words else (3 if is_prefix else 4))
        # Well-known artist by name (query matched their name or alias,
        # and they exist in Last.fm) ranks above songs matching title only:
        # otherwise "madonna" would open Drake "Madonna"
        # (docs/troubleshooting.md, #58).
        # Top Last.fm track ranks ahead of other songs by same artist:
        # otherwise for "metallica" "[instrumental jam]" came first (benchmark 30.09).
        scored.append((rank, 0 if famous_name_match else 1, -weight, 0 if row["top"] else 1, -max_sim, song_id, dict(row)))

    scored.sort(key=lambda item: item[:6])
    return scored


SUGGEST_SQL = """
WITH hits AS (
    (SELECT name AS text, 0 AS kind, mbid AS artist_mbid FROM mb_artist WHERE name ILIKE $1 LIMIT $2)
    UNION ALL (SELECT name, 1, artist_mbid FROM mb_artist_alias WHERE name ILIKE $1 LIMIT $2)
    UNION ALL (SELECT title, 2, artist_mbid FROM song WHERE title ILIKE $1 LIMIT $2)
    UNION ALL (SELECT title, 3, artist_mbid FROM mb_recording WHERE title ILIKE $1 LIMIT $2)
)
SELECT h.text FROM hits h
LEFT JOIN mb_artist a ON a.mbid = h.artist_mbid
LEFT JOIN LATERAL (SELECT sum(popularity)::bigint AS pop FROM catalog_artists WHERE artist_key = lower(a.name)) ca ON true
LEFT JOIN lastfm_artists la ON la.artist_key = lower(a.name)
ORDER BY h.kind ASC, (coalesce(ca.pop, 0) + coalesce(la.listeners, 0)) DESC, h.text ASC
LIMIT $2;
"""


async def suggest(conn: asyncpg.Connection, query: str, limit: int = 10) -> list[str]:
    q = query.strip()
    if len(norm(q)) < 2 and len(q) < 2:
        return []
    prefix = f"{_escape_like(q)}%"
    async with conn.transaction():
        await conn.execute("SET LOCAL statement_timeout = '500ms'")
        rows = await conn.fetch(SUGGEST_SQL, prefix, limit * 2)
    seen, out = set(), []
    has_spec = "%" in q or "_" in q
    for row in rows:
        text = str(row["text"]).strip()
        if has_spec and (("%" in q and "%" not in text) or ("_" in q and "_" not in text)):
            continue
        k = norm(text) or text.casefold()
        if k and k not in seen:
            seen.add(k)
            out.append(text)
            if len(out) >= limit:
                break
    return out


# Title key that ignores punctuation, case, apostrophe style and «Pt.»/«Part» (FT-866). The same expression
# runs on both sides of the comparison, so «Who Is She ?» meets «Who Is She?» and «X - Remix» meets «X (Remix)».
# The punctuation set is explicit: `[[:alnum:]]` depends on the database locale.
_LOOSE_PUNCT = r"""[\s.,;:!?¿¡"'’‘´`“”«»\-–—()\[\]/*=#+~_&]+""".replace("'", "''")


def _loose(expr: str) -> str:
    return f"regexp_replace(regexp_replace(lower({expr}), '\\mpt\\M', 'part', 'g'), '{_LOOSE_PUNCT}', '', 'g')"


TOP_TRACKS_SQL = """
WITH art AS MATERIALIZED (
    SELECT mbid FROM mb_artist WHERE name = $1 OR name ILIKE $4
    UNION SELECT artist_mbid FROM mb_artist_alias WHERE name = $1 OR name ILIKE $4
),
-- Featured artist and release edition suffix in title: Last.fm writes "Unholy (feat. Kim Petras)",
-- "The Diary of Jane - Single Version", "Dance The Night - From Barbie The Album",
-- "The Flower Duet (From ""Lakmé"")", while MusicBrainz replica holds the recording under a clean
-- title. Hyphenated versions ("Pool - Stripped", "We Are The World - Live")
-- are parenthesized in recording. Versions (Remix, Live, Acoustic, Stripped) remain part
-- of the title and are not replaced by the studio recording (FT-539, FT-569).
top AS MATERIALIZED (
    SELECT t.raw_title, t.norm_title,
           trim(regexp_replace(
               regexp_replace(
                   regexp_replace(
                       regexp_replace(t.raw_title,
                           '\\s*\\(\\s*(feat\\.?|ft\\.?|featuring|with)\\s+[^()]*\\)\\s*', '', 'gi'),
                       '\\s*\\[\\s*(feat\\.?|ft\\.?|featuring|with)\\s+[^\\[\\]]*\\]\\s*', '', 'gi'),
                   '\\s*(?:[-–]\\s*(?:single\\s+version|radio\\s+edit|edit|from\\s+.*)|[\\(\\[]\\s*(?:single\\s+version|radio\\s+edit|edit|from\\s+[^()[\\]]*)[\\)\\]])\\s*$', '', 'gi'),
               '\\s*(?:\\(\\s*(feat\\.?|ft\\.?|featuring|with)\\s+[^()]*\\)|\\[\\s*(feat\\.?|ft\\.?|featuring|with)\\s+[^\\[\\]]*\\])\\s*', '', 'gi')) AS bare_title,
           regexp_replace(t.raw_title,
               '^(.+)\\s+[-–]\\s+(.+)$', '\\1 (\\2)', 'i') AS bracket_title
    FROM (
        SELECT * FROM unnest($2::text[], $3::text[])
        UNION ALL SELECT * FROM unnest($5::text[], $6::text[])
    ) AS t(raw_title, norm_title)
),
-- Title variants — once per title, not per each recording of the artist:
-- in join condition parsing ran ~20,000 times, Metallica took 24s (FT-583).
cand AS MATERIALIZED (
    SELECT DISTINCT t.norm_title, c.title, LOOSE(c.title) AS lk
    FROM top t, unnest(ARRAY[
        lower(t.raw_title), lower(t.norm_title), lower(t.bare_title), lower(t.bracket_title),
        replace(lower(t.raw_title), '''', '’'), replace(lower(t.raw_title), '’', ''''),
        replace(lower(t.bare_title), '''', '’'), replace(lower(t.bare_title), '’', ''''),
        replace(lower(t.bracket_title), '''', '’'), replace(lower(t.bracket_title), '’', '''')
    ]) AS c(title)
),
-- Fallback matching (FT-866): a key without punctuation. The key of a record is computed once per record.
recs AS MATERIALIZED (
    SELECT r.mbid, r.title, r.length_ms, LOOSE(r.title) AS lk
    FROM art JOIN mb_recording r ON r.artist_mbid = art.mbid
)
SELECT DISTINCT ON (cand.norm_title) cand.norm_title, r.mbid::text AS id, coalesce(r.length_ms, 0)::integer AS duration_ms
FROM recs r
JOIN cand ON r.lk = cand.lk AND cand.lk <> ''
JOIN song_version v ON v.recording_mbid = r.mbid
JOIN song s ON s.id = v.song_id
ORDER BY cand.norm_title, (lower(r.title) = cand.title) DESC, (CASE v.kind WHEN 'original' THEN 1 WHEN 'cover' THEN 2 ELSE 3 END), (r.mbid = s.original_recording_mbid) DESC NULLS LAST, r.length_ms DESC NULLS LAST;
"""
TOP_TRACKS_SQL = TOP_TRACKS_SQL.replace("LOOSE(c.title)", _loose("c.title")).replace("LOOSE(r.title)", _loose("r.title"))

_ROMAN = {1: "I", 2: "II", 3: "III", 4: "IV", 5: "V", 6: "VI", 7: "VII", 8: "VIII", 9: "IX", 10: "X"}
_ARABIC = {value: key for key, value in _ROMAN.items()}
_MOVEMENT = re.compile(r"(?<=[:\s])(\d{1,2}|[IVX]{1,4})\.(?=\s)")


def movement_variants(title: str) -> list[str]:
    """Same title with a movement number written the other way: «: 2. Adagio» and «: II. Adagio»."""
    out = []
    for match in _MOVEMENT.finditer(title):
        number = match.group(1)
        other = _ROMAN.get(int(number)) if number.isdigit() else str(_ARABIC.get(number, ""))
        if other:
            out.append(title[: match.start(1)] + other + title[match.end(1) :])
    return out


async def top_track_ids(
    conn: asyncpg.Connection, artist: str, titles: list[str]
) -> dict[str, dict[str, Any]]:
    if not artist.strip() or not titles:
        return {}
    raw_titles = [t.strip() for t in titles if t.strip()]
    norm_titles = [norm(t) for t in raw_titles]
    extra = [(variant, key) for title, key in zip(raw_titles, norm_titles, strict=True) for variant in movement_variants(title)]
    rows = await conn.fetch(
        TOP_TRACKS_SQL,
        artist.strip(),
        raw_titles,
        norm_titles,
        _escape_like(artist.strip()),
        [variant for variant, _ in extra],
        [key for _, key in extra],
    )
    return {
        row["norm_title"]: {"id": row["id"], "duration_ms": int(row["duration_ms"])}
        for row in rows
    }
