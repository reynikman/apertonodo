"""Catalog browse entrypoint and SQL queries for published MusicBrainz copy (FT-024)."""

from __future__ import annotations

import re
from typing import Any
from uuid import UUID

import asyncpg
from fastapi import FastAPI

from app.names import norm

DATE_RE = re.compile(r"^\d{4}(-\d{2}(-\d{2})?)?$")


def norm_date(value: Any) -> tuple[str | None, int | None]:
    t = str(value or "")
    return (t, int(t[:4])) if DATE_RE.fullmatch(t) else (None, None)


def build_app(database_url: str, api_key: str) -> FastAPI:
    from app.main import create_app

    return create_app(database_url=database_url, api_key=api_key)


async def is_published(conn: asyncpg.Connection) -> bool:
    try:
        return bool(await conn.fetchval("SELECT EXISTS (SELECT 1 FROM mb_loads)"))
    except Exception:
        return False


async def get_countries(conn: asyncpg.Connection) -> list[dict[str, Any]]:
    rows = await conn.fetch("SELECT iso, count(*)::int AS artists FROM artist_country GROUP BY iso ORDER BY artists DESC, iso")
    unknown = await conn.fetchval("SELECT count(*)::int FROM mb_artist a WHERE NOT EXISTS (SELECT 1 FROM artist_country c WHERE c.artist_mbid = a.mbid)")
    return [{"iso": r["iso"], "artists": r["artists"]} for r in rows] + ([{"iso": "unknown", "artists": unknown}] if unknown else [])


async def get_genres(conn: asyncpg.Connection, country: str = "") -> list[dict[str, Any]]:
    if await conn.fetchval("SELECT EXISTS (SELECT 1 FROM catalog_open_names)"):
        rows = await conn.fetch("SELECT slug, artists FROM catalog_open_genres WHERE country = $1", country)
        by = {r["slug"]: r["artists"] for r in rows}
    else:
        # Migration does not backfill. Until catalog.build, keep the old counts.
        args: tuple[Any, ...] = ()
        if country == "unknown":
            sql = "SELECT g.slug, count(*)::int AS n FROM artist_genre g WHERE g.is_primary AND NOT EXISTS (SELECT 1 FROM artist_country c WHERE c.artist_mbid = g.artist_mbid) GROUP BY g.slug"
        elif country:
            sql, args = "SELECT g.slug, count(*)::int AS n FROM artist_genre g JOIN artist_country c ON c.artist_mbid = g.artist_mbid WHERE g.is_primary AND c.iso = $1 GROUP BY g.slug", (country,)
        else:
            sql = "SELECT slug, count(*)::int AS n FROM artist_genre WHERE is_primary GROUP BY slug"
        by = {r["slug"]: r["n"] for r in await conn.fetch(sql, *args)}
    return [{"id": r["slug"], "name": r["name_en"], "name_ru": r["name_ru"], "artists": by.get(r["slug"], 0)}
            for r in await conn.fetch("SELECT slug, name_en, name_ru FROM our_genre ORDER BY sort, slug")]


async def genre_artists(conn: asyncpg.Connection, slug: str, offset: int, limit: int | None) -> tuple[list[str], int]:
    """Genre artists of the copy alphabetically (P-A54); each name appears once.

    Same ones counted by /v1/genres; Latin first, then Cyrillic, then other.
    Order was generated during catalog publication (FT-766) — we read it without touching `mb_artist`.
    """
    if await conn.fetchval("SELECT EXISTS (SELECT 1 FROM catalog_genre_artists_state)"):
        rows = await conn.fetch(
            "SELECT name FROM catalog_genre_artists WHERE slug = $1 ORDER BY pos LIMIT $2 OFFSET $3",
            slug, limit, offset,
        )
        total = await conn.fetchval("SELECT count(*) FROM catalog_genre_artists WHERE slug = $1", slug)
        return [row["name"] for row in rows], int(total)
    rows = await conn.fetch(
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
        "  name COLLATE \"und-x-icu\", name LIMIT $2 OFFSET $3",
        slug, limit, offset,
    )
    total = rows[0]["total"] if rows else await conn.fetchval(
        "SELECT count(DISTINCT lower(a.name)) FROM artist_genre g JOIN mb_artist a ON a.mbid = g.artist_mbid "
        "LEFT JOIN catalog_open_names o ON o.name = a.name WHERE g.is_primary AND g.slug = $1 "
        "AND (o.listed OR NOT EXISTS (SELECT 1 FROM catalog_open_names)) "
        "AND (o.mbid IS NULL OR o.mbid = g.artist_mbid)", slug
    )
    return [row["name"] for row in rows], int(total)


RESOLVE_ARTIST_SQL = """
WITH exact_name AS MATERIALIZED (
    SELECT a.mbid, a.name, 0 AS match_order
    FROM mb_artist a
    WHERE a.name ILIKE $2 AND lower(a.name) = lower($1)
), sort_name AS MATERIALIZED (
    SELECT a.mbid, a.name, 1 AS match_order
    FROM mb_artist a
    WHERE a.name % $1 AND lower(a.sort_name) = lower($1)
      -- Sort names of people and "The ..." bands hold a comma ("Morricone, Ennio"). Without
      -- a comma in the query this branch only re-finds an artist whose sort name equals
      -- the name, and `exact_name` already took it. The trigram scan costs ~2 s on 30M
      -- artists for a one-word query that is not an exact name (FT-887).
      AND position(',' in $1) > 0
      AND NOT EXISTS (SELECT 1 FROM exact_name)
), alias_name AS MATERIALIZED (
    SELECT a.mbid, a.name, 2 AS match_order
    FROM mb_artist_alias al JOIN mb_artist a ON a.mbid = al.artist_mbid
    WHERE al.name ILIKE $2 AND lower(al.name) = lower($1)
      AND NOT EXISTS (SELECT 1 FROM exact_name)
      AND NOT EXISTS (SELECT 1 FROM sort_name)
), winner AS (
    SELECT candidate.mbid, candidate.name
    FROM (
        SELECT * FROM exact_name
        UNION ALL SELECT * FROM sort_name
        UNION ALL SELECT * FROM alias_name
    ) candidate
    ORDER BY candidate.match_order,
             (SELECT count(*) FROM mb_release_group g WHERE g.artist_mbid = candidate.mbid) DESC,
             candidate.mbid
    LIMIT 1
)
SELECT w.mbid::text AS id, w.name,
       EXISTS (
           SELECT 1
           FROM mb_release_group g JOIN mb_release r ON r.group_mbid = g.mbid
           JOIN mb_medium m ON m.release_mbid = r.mbid
           JOIN mb_track t ON t.medium_id = m.id
           WHERE g.artist_mbid = w.mbid
             AND (g.primary_type IN ('Album', 'EP') OR g.primary_type IS NULL)
             AND (g.secondary_types = '{}' OR g.secondary_types IS NULL)
             AND r.status = 'Official'
       ) AS has_official_album
FROM winner w
"""


async def resolve_artist_name(
    conn: asyncpg.Connection, name: str
) -> tuple[dict[str, Any] | None, bool]:
    """Resolve a page name with get_artist's precedence and namesake ranking."""
    wanted = name.strip()
    if not wanted:
        return None, False
    exact = wanted.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    row = await conn.fetchrow(RESOLVE_ARTIST_SQL, wanted, exact)
    if row is None:
        return None, False
    return {"id": row["id"], "name": row["name"]}, bool(row["has_official_album"])


async def get_artist(
    conn: asyncpg.Connection, name: str = "", artist_id: str | None = None
) -> tuple[dict[str, Any] | None, list[dict[str, Any]], list[dict[str, Any]], dict[str, str | None]]:
    row = None
    if artist_id:
        try:
            row = await conn.fetchrow("SELECT mbid::text AS id, name FROM mb_artist WHERE mbid = $1::uuid", UUID(artist_id))
        except Exception:
            row = None
    if row is None and name:
        row, _ = await resolve_artist_name(conn, name)
    if row is None:
        return None, [], [], {}
    mbid = UUID(row["id"])
    aliases = sorted([{"name": r["name"], "locale": r["locale"]} for r in await conn.fetch("SELECT name, locale FROM mb_artist_alias WHERE artist_mbid = $1", mbid)],
                     key=lambda x: (x["locale"] or "", x["name"]))
    group_rows = await conn.fetch(
        # Only groups that have an official release: without this, Metallica's discography
        # included bootlegs and promos (Plays the Ramones, Live in Concert, "Power Metal") that the band never released.
        "SELECT g.mbid::text AS id, g.title, g.primary_type, g.secondary_types, g.first_date, editions.official_releases "
        "FROM mb_release_group g JOIN LATERAL ("
        "SELECT count(*) AS official_releases FROM mb_release r "
        "WHERE r.group_mbid = g.mbid AND r.status = 'Official'"
        ") editions ON editions.official_releases > 0 "
        "WHERE g.artist_mbid = $1 AND (g.primary_type IN ('Album', 'EP', 'Single') OR g.primary_type IS NULL) "
        "AND (g.secondary_types <@ ARRAY['Live', 'Compilation']::text[] OR g.secondary_types IS NULL) "
        "AND EXISTS ("
        "SELECT 1 FROM mb_release r JOIN mb_medium m ON m.release_mbid = r.mbid "
        "JOIN mb_track t ON t.medium_id = m.id WHERE r.group_mbid = g.mbid"
        ") "
        "ORDER BY g.first_date NULLS LAST, g.title, g.mbid", mbid
    )
    groups = [dict(g) for g in group_rows]
    for group in groups:
        secondary = group["secondary_types"] or []
        if "Live" in secondary:
            group["kind"] = "live"
        elif "Compilation" in secondary:
            group["kind"] = "compilation"
        else:
            group["kind"] = {"Single": "single", "EP": "ep"}.get(group["primary_type"], "album")
    # EP and single sharing title with a studio album are hidden, live and compilation are not.
    album_titles = {norm(g["title"]) for g in groups if g["kind"] == "album"}
    groups = [g for g in groups if g["kind"] not in ("ep", "single") or norm(g["title"]) not in album_titles]
    # Same-year namesakes: same title and year for one artist form a single card,
    # remaining releases become "other editions" inside it (FT-552, P-A12). Main one is
    # studio, then whoever has more official releases, then smaller id.
    # Tile order is by first occurrence, i.e., as before (year, title, id).
    namesakes: dict[tuple[str, int | None], list[dict[str, Any]]] = {}
    for group in groups:
        namesakes.setdefault((norm(group["title"]), norm_date(group["first_date"])[1]), []).append(group)
    folded: list[dict[str, Any]] = []
    for dupes in namesakes.values():
        dupes.sort(key=lambda g: (0 if g["kind"] == "album" else 1, -g["official_releases"], g["id"]))
        main = dupes[0]
        main["editions"] = [
            {"id": g["id"], "title": g["title"], "year": norm_date(g["first_date"])[1], "kind": g["kind"]}
            for g in dupes[1:]
        ]
        folded.append(main)
    groups = folded
    # Trim both non-studio rows to formats, playable and covers; all studio ones remain.
    kept_ids = {g["id"] for g in groups if g["kind"] == "album"}
    for kinds in (("ep", "single"), ("live", "compilation")):
        ranked = sorted(
            (g for g in groups if g["kind"] in kinds),
            key=lambda g: g["official_releases"], reverse=True,
        )
        kept_ids.update(g["id"] for g in ranked[:24])
    groups = [g for g in groups if g["id"] in kept_ids]
    discs: dict[str, str | None] = {}
    if groups:
        discs = {r["gid"]: r["format"] for r in await conn.fetch(
            "SELECT DISTINCT ON (r.group_mbid) r.group_mbid::text AS gid, m.format FROM mb_release r "
            "JOIN mb_medium m ON m.release_mbid = r.mbid AND m.position = 1 WHERE r.group_mbid = ANY($1::uuid[]) "
            # Same order as tracklist in get_album: format on card matches the edition inside.
            "ORDER BY r.group_mbid, NOT EXISTS ("
            "SELECT 1 FROM mb_medium m2 JOIN mb_track t ON t.medium_id = m2.id WHERE m2.release_mbid = r.mbid"
            "), r.status IS DISTINCT FROM 'Official', left(r.date, 4) NULLS LAST, "
            "COALESCE(m.format ~* 'vinyl|cassette', false), r.date NULLS LAST, r.mbid", [UUID(g["id"]) for g in groups]
        )}
    return dict(row), aliases, groups, discs


async def get_album(
    conn: asyncpg.Connection, album_id: UUID
) -> tuple[dict[str, Any] | None, str | None, list[dict[str, Any]]]:
    group = await conn.fetchrow("SELECT g.mbid::text AS id, g.title, g.first_date, COALESCE(a.name, '') AS artist FROM mb_release_group g LEFT JOIN mb_artist a ON a.mbid = g.artist_mbid WHERE g.mbid = $1::uuid", album_id)
    if group is None:
        return None, None, []
    # Tracklist from the earliest official release; within the same year CD or digital precedes vinyl and cassette:
    # their sides are separate media with restarted track numbering, which gave Adele's "30" (finding 30.09)
    # two sets of 1–6 on screen. Format in response matches the tracklist release.
    release = await conn.fetchrow(
        "SELECT r.mbid, m1.format FROM mb_release r "
        "LEFT JOIN mb_medium m1 ON m1.release_mbid = r.mbid AND m1.position = 1 "
        "WHERE r.group_mbid = $1::uuid "
        "ORDER BY NOT EXISTS ("
        "SELECT 1 FROM mb_medium m JOIN mb_track t ON t.medium_id = m.id WHERE m.release_mbid = r.mbid"
        "), r.status IS DISTINCT FROM 'Official', left(r.date, 4) NULLS LAST, "
        "COALESCE(m1.format ~* 'vinyl|cassette', false), r.date NULLS LAST, r.mbid LIMIT 1",
        album_id,
    )
    if release is None:
        return dict(group), None, []
    # Duration, if release lacks it, is taken from the recording itself. For "72 Seasons" the first release
    # on 2023-04-14 had no durations, and a song without duration is treated as unplayable: the whole album
    # appeared dim even though it was playable.
    tracks = await conn.fetch(
        "SELECT t.recording_mbid::text AS id, t.position, t.title, COALESCE(t.length_ms, rec.length_ms, 0)::int AS duration_ms "
        "FROM mb_medium m JOIN mb_track t ON t.medium_id = m.id "
        "LEFT JOIN mb_recording rec ON rec.mbid = t.recording_mbid "
        "WHERE m.release_mbid = $1 ORDER BY m.position, t.position", release["mbid"]
    )
    return dict(group), release["format"], [dict(t) for t in tracks]


async def get_track_album(
    conn: asyncpg.Connection, track_id: UUID
) -> dict[str, Any] | None:
    """Album of displayed song according to MusicBrainz (FT-562).

    If id is a MusicBrainz recording (mb_track.recording_mbid), use it; otherwise
    mb_recording entries of the song artist with the same title.
    """
    track = await conn.fetchrow(
        "SELECT id, title, artist FROM tracks WHERE id = $1", track_id
    )
    if track is None:
        return None

    is_recording = await conn.fetchval(
        "SELECT EXISTS (SELECT 1 FROM mb_track WHERE recording_mbid = $1)", track_id
    )
    if is_recording:
        row = await conn.fetchrow(
            """
            SELECT g.mbid::text AS id, g.title
            FROM mb_track t
            JOIN mb_medium m ON m.id = t.medium_id
            JOIN mb_release r ON r.mbid = m.release_mbid
            JOIN mb_release_group g ON g.mbid = r.group_mbid
            WHERE t.recording_mbid = $1
              AND r.status = 'Official'
            ORDER BY
                CASE g.primary_type
                    WHEN 'Album' THEN 0
                    WHEN 'EP' THEN 1
                    WHEN 'Single' THEN 2
                    ELSE 3
                END,
                CASE WHEN g.secondary_types IS NULL OR g.secondary_types = '{}' THEN 0 ELSE 1 END,
                g.first_date NULLS LAST,
                g.mbid
            LIMIT 1
            """,
            track_id,
        )
        if row is not None:
            return {"id": row["id"], "title": str(row["title"] or "")}
        return None

    artist_row, _ = await resolve_artist_name(conn, track["artist"])
    if artist_row is None:
        return None
    artist_mbid = UUID(artist_row["id"])

    row = await conn.fetchrow(
        """
        SELECT g.mbid::text AS id, g.title
        FROM mb_recording rec
        JOIN mb_track t ON t.recording_mbid = rec.mbid
        JOIN mb_medium m ON m.id = t.medium_id
        JOIN mb_release r ON r.mbid = m.release_mbid
        JOIN mb_release_group g ON g.mbid = r.group_mbid
        WHERE rec.artist_mbid = $1
          AND lower(rec.title) = lower($2)
          AND r.status = 'Official'
        ORDER BY
            CASE g.primary_type
                WHEN 'Album' THEN 0
                WHEN 'EP' THEN 1
                WHEN 'Single' THEN 2
                ELSE 3
            END,
            CASE WHEN g.secondary_types IS NULL OR g.secondary_types = '{}' THEN 0 ELSE 1 END,
            g.first_date NULLS LAST,
            g.mbid
        LIMIT 1
        """,
        artist_mbid,
        track["title"],
    )
    if row is not None:
        return {"id": row["id"], "title": str(row["title"] or "")}
    return None

