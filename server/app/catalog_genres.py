"""Our own genre tree, main genre and artist country (catalog v2, V2).

`python -m app.catalog_genres build`

Genre and country are different axes. The top is the general genres of the Apple Music screen, without
"Russian Rock" and other national labels. The local MusicBrainz genre
is stored next to the top (`mb_genre_mbid`). The country is `artist_country`.

Top mapping: a manual dictionary of roots, the rest climbs the
mb_genre_edge kind=subgenre tree; no path means worldwide. Genre sources:
MB tags, then Last.fm, then the catalog section genre.

Called after a successful `python -m app.mbcopy load`. The screens are in V5.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import sys
import time
from collections import defaultdict, deque
from collections.abc import Callable
from typing import Any
from uuid import UUID

import asyncpg

from app.env_names import env
from app.genres import CATALOG_TO_OUR
from app.names import norm

logger = logging.getLogger("apertonodo")

# Manual mapping of roots only. Names are as in the MusicBrainz dictionary,
# case-insensitive. A subgenre without its own key climbs the tree.
ROOT_MAP: dict[str, str] = {
    "rock": "rock",
    "metal": "metal",
    "punk": "punk",
    "punk rock": "punk",
    "alternative rock": "alternative",
    "alternative": "alternative",
    "hip hop": "hip-hop",
    "pop": "pop",
    "electronic": "electronic",
    "dance": "dance",
    "jazz": "jazz",
    "blues": "blues",
    "country": "country",
    "folk": "folk",
    "classical": "classical",
    "latin": "latin",
    "reggae": "reggae",
    "r&b": "rnb",
    "soul": "rnb",
    "k-pop": "k-pop",
    "j-pop": "j-pop",
    "easy listening": "easy-listening",
    "singer-songwriter": "singer-songwriter",
    "sovietwave": "electronic",
    # Measured 30.09 (Р-A39): these big genres have no path to the roots.
    # Mapped via the Apple Music genre tree.
    "ambient": "electronic",
    "experimental": "electronic",
    "industrial": "electronic",
    "pop rock": "pop",
    "metalcore": "metal",
    "psychedelic": "rock",
    "blues rock": "rock",
    "funk": "rnb",
    "regional mexicano": "latin",
    "noise": "alternative",
    # MusicBrainz genres that used to lead to "Christian".
    # Since 01.10 the top is removed (Р-A44): we map by sound.
    "contemporary christian": "pop",
    "praise & worship": "pop",
    "gospel": "rnb",
    "christian rock": "rock",
    "christian metal": "metal",
    "christian hip hop": "hip-hop",
    "christian hardcore": "metal",
    "children's music": "kids",
    "world music": "worldwide",
    # Not top level: direct iTunes subcategories by country, and adjacent ones.
    # Snapshot of the names is app/data/itunes_genres.json. Put them here so as
    # not to spawn the enka/tarab/marching screens.
    "brazilian": "latin",
    "cuban": "latin",
    "african": "worldwide",
    "arabic": "worldwide",
    "chinese": "worldwide",
    "indian": "worldwide",
    "turkish": "worldwide",
    "tarab": "worldwide",
    "jewish music": "worldwide",
    "german folk": "worldwide",
    "korean": "worldwide",
    "enka": "worldwide",
    "kayokyoku": "worldwide",
    "french pop": "pop",
    "german pop": "pop",
    "disney": "kids",
    "anime": "soundtrack",
    "inspirational": "pop",
    "orchestral": "classical",
    "marching": "classical",
    "vocal": "easy-listening",
    "new age": "easy-listening",
    "instrumental": "easy-listening",
}

# Historical ISO 3166-1 codes. A city with a modern country overrides them.
DISSOLVED_ISO = frozenset({"SU", "YU", "CS", "DD", "SUHH"})

# The top is the general genres of the Apple Music screen. National labels are not stored.
OUR_GENRES: tuple[tuple[str, str, str, int], ...] = (
    ("pop", "Pop", "Поп", 1),
    ("rock", "Rock", "Рок", 2),
    ("alternative", "Alternative", "Альтернатива", 3),
    ("metal", "Metal", "Метал", 4),
    ("punk", "Punk", "Панк", 5),
    ("hip-hop", "Hip-Hop/Rap", "Хип-хоп", 6),
    ("rnb", "R&B/Soul", "R&B и соул", 7),
    ("electronic", "Electronic", "Электроника", 8),
    ("dance", "Dance", "Танцевальная", 9),
    ("jazz", "Jazz", "Джаз", 10),
    ("blues", "Blues", "Блюз", 11),
    ("country", "Country", "Кантри", 12),
    ("folk", "Folk", "Фолк", 13),
    ("classical", "Classical", "Классика", 14),
    ("latin", "Latin", "Латинская", 15),
    ("reggae", "Reggae", "Регги", 16),
    ("k-pop", "K-Pop", "K-pop", 17),
    ("j-pop", "J-Pop", "J-pop", 18),
    ("soundtrack", "Soundtrack", "Саундтреки", 19),
    ("easy-listening", "Easy Listening", "Изи-лиснинг", 20),
    ("kids", "Children's Music", "Детское", 21),
    ("singer-songwriter", "Singer/Songwriter", "Авторская песня", 22),
    ("worldwide", "Worldwide", "Мировая", 24),
)

OUR_SLUGS = frozenset(slug for slug, _en, _ru, _sort in OUR_GENRES)
SORT_OF = {slug: sort for slug, _en, _ru, sort in OUR_GENRES}

_swap_hook: Callable[[], Any] | None = None


def map_genre(
    mbid: UUID,
    *,
    roots: dict[UUID, str],
    parents: dict[UUID, list[UUID]],
) -> str | None:
    """Nearest mapped ancestor by subgenre. No path - None."""
    if mbid in roots:
        return roots[mbid]
    seen = {mbid}
    queue: deque[tuple[UUID, int]] = deque([(mbid, 0)])
    found: list[tuple[int, int, str]] = []
    while queue:
        cur, dist = queue.popleft()
        for parent in parents.get(cur, ()):
            if parent in seen:
                continue
            seen.add(parent)
            slug = roots.get(parent)
            if slug is not None:
                found.append((dist + 1, SORT_OF.get(slug, 10_000), slug))
            else:
                queue.append((parent, dist + 1))
    if not found:
        return None
    found.sort()
    return found[0][2]


def _norm_iso(iso: str | None) -> str | None:
    code = (iso or "").strip().upper()
    return code or None


def _climb_iso(
    start: UUID | None,
    *,
    areas: dict[UUID, tuple[str | None, str]],
    parts: dict[UUID, list[UUID]],
) -> str | None:
    """First modern ISO by part-of, otherwise the first historical one."""
    if start is None:
        return None
    seen: set[UUID] = set()
    queue: deque[UUID] = deque([start])
    dissolved: str | None = None
    while queue:
        cur = queue.popleft()
        if cur in seen:
            continue
        seen.add(cur)
        iso, _name = areas.get(cur, (None, ""))
        code = _norm_iso(iso)
        if code:
            if code not in DISSOLVED_ISO:
                return code
            if dissolved is None:
                dissolved = code
        queue.extend(parts.get(cur, ()))
    return dissolved


def resolve_country(
    area: UUID | None,
    begin: UUID | None,
    *,
    areas: dict[UUID, tuple[str | None, str]],
    parts: dict[UUID, list[UUID]],
) -> tuple[str, str] | None:
    """Country: the city (begin_area) wins; a vanished one without a city stays."""
    city = _climb_iso(begin, areas=areas, parts=parts)
    nation = _climb_iso(area, areas=areas, parts=parts)
    if city and city not in DISSOLVED_ISO:
        return city, "begin_area"
    if nation and nation not in DISSOLVED_ISO:
        return nation, "area"
    if city:
        return city, "dissolved"
    if nation:
        return nation, "dissolved"
    return None


def pick_top(weights: dict[str, int]) -> tuple[str, int] | None:
    if not weights:
        return None
    slug, score = max(weights.items(), key=lambda item: (item[1], -SORT_OF.get(item[0], 10_000)))
    return slug, score


def _uuid(value: Any) -> UUID:
    return value if isinstance(value, UUID) else UUID(str(value))


async def _seed_our_genre(conn: asyncpg.Connection) -> None:
    await conn.executemany(
        """
        INSERT INTO our_genre (slug, name_en, name_ru, sort)
        VALUES ($1, $2, $3, $4)
        ON CONFLICT (slug) DO UPDATE SET
            name_en = EXCLUDED.name_en,
            name_ru = EXCLUDED.name_ru,
            sort = EXCLUDED.sort
        """,
        OUR_GENRES,
    )
    await conn.execute(
        "DELETE FROM our_genre WHERE NOT (slug = ANY($1::text[]))",
        list(OUR_SLUGS),
    )


async def _create_load(conn: asyncpg.Connection) -> None:
    await conn.execute("DROP TABLE IF EXISTS our_genre_map_load")
    await conn.execute("DROP TABLE IF EXISTS artist_genre_load")
    await conn.execute("DROP TABLE IF EXISTS artist_country_load")
    await conn.execute(
        """
        CREATE TABLE our_genre_map_load (
            mb_genre_mbid uuid PRIMARY KEY,
            slug text NOT NULL
        )
        """
    )
    await conn.execute(
        """
        CREATE TABLE artist_genre_load (
            artist_mbid uuid NOT NULL,
            slug text NOT NULL,
            source text NOT NULL,
            score integer NOT NULL,
            is_primary boolean NOT NULL DEFAULT false,
            mb_genre_mbid uuid,
            PRIMARY KEY (artist_mbid, slug, source)
        )
        """
    )
    await conn.execute(
        "CREATE UNIQUE INDEX artist_genre_load_one_primary "
        "ON artist_genre_load (artist_mbid) WHERE is_primary"
    )
    await conn.execute(
        """
        CREATE TABLE artist_country_load (
            artist_mbid uuid PRIMARY KEY,
            iso text NOT NULL,
            source text NOT NULL
        )
        """
    )


async def _swap(conn: asyncpg.Connection) -> None:
    async with conn.transaction():
        await _seed_our_genre(conn)
        await conn.execute("DROP TABLE IF EXISTS our_genre_map")
        if _swap_hook is not None:
            maybe = _swap_hook()
            if asyncio.iscoroutine(maybe):
                await maybe
        await conn.execute("ALTER TABLE our_genre_map_load RENAME TO our_genre_map")
        await conn.execute(
            "ALTER INDEX IF EXISTS our_genre_map_load_pkey RENAME TO our_genre_map_pkey"
        )
        await conn.execute("DROP TABLE IF EXISTS artist_genre")
        await conn.execute("ALTER TABLE artist_genre_load RENAME TO artist_genre")
        await conn.execute(
            "ALTER INDEX IF EXISTS artist_genre_load_one_primary "
            "RENAME TO artist_genre_one_primary"
        )
        await conn.execute(
            "ALTER INDEX IF EXISTS artist_genre_load_pkey RENAME TO artist_genre_pkey"
        )
        await conn.execute(
            "CREATE INDEX IF NOT EXISTS artist_genre_slug ON artist_genre (slug)"
        )
        await conn.execute(
            "CREATE INDEX IF NOT EXISTS artist_genre_artist ON artist_genre (artist_mbid)"
        )
        await conn.execute("DROP TABLE IF EXISTS artist_country")
        await conn.execute("ALTER TABLE artist_country_load RENAME TO artist_country")
        await conn.execute(
            "ALTER INDEX IF EXISTS artist_country_load_pkey RENAME TO artist_country_pkey"
        )
        await conn.execute(
            "CREATE INDEX IF NOT EXISTS artist_country_iso ON artist_country (iso)"
        )
        # Prepare staged marks before publication locks; mb_loads publishes them
        # from this same connection. A standalone build refreshes public directly.
        if await conn.fetchval("SELECT current_schema()") == "public":
            await conn.execute("SELECT public.refresh_catalog_open_names()")
        else:
            await conn.execute("SELECT public.prepare_catalog_open_names()")


async def countries_with_counts(conn: asyncpg.Connection) -> list[asyncpg.Record]:
    return await conn.fetch(
        "SELECT iso, count(*)::bigint AS artists FROM artist_country "
        "GROUP BY iso ORDER BY artists DESC, iso"
    )


async def country_slice(conn: asyncpg.Connection, iso: str) -> dict[str, Any]:
    genres = await conn.fetch(
        "SELECT g.slug, count(*)::bigint AS artists "
        "FROM artist_country c "
        "JOIN artist_genre g ON g.artist_mbid = c.artist_mbid AND g.is_primary "
        "WHERE c.iso = $1 GROUP BY g.slug ORDER BY artists DESC, g.slug",
        iso,
    )
    local = await conn.fetch(
        "SELECT g.mb_genre_mbid, count(*)::bigint AS artists "
        "FROM artist_country c "
        "JOIN artist_genre g ON g.artist_mbid = c.artist_mbid AND g.is_primary "
        "WHERE c.iso = $1 AND g.mb_genre_mbid IS NOT NULL "
        "GROUP BY g.mb_genre_mbid ORDER BY artists DESC",
        iso,
    )
    return {"iso": iso, "genres": genres, "local": local}


async def build(database_url: str) -> dict[str, Any]:
    """Recompute our_genre_map and artist_genre. The swap is one transaction."""
    began = time.monotonic()
    conn = await asyncpg.connect(database_url)
    try:
        # The standalone builder must use one copy throughout, just like mbcopy.
        await conn.execute("SELECT pg_advisory_lock(17017)")
        summary = await build_in_connection(conn)
        duration_ms = int((time.monotonic() - began) * 1000)
        summary["duration_ms"] = duration_ms
        logger.info(
            "catalog genres: %d artists, mb %d, lastfm %d, forum %d, "
            "soundtrack %d, none %d, unmapped %d, %d ms",
            summary["artists"],
            summary["source_mb"],
            summary["source_lastfm"],
            summary["source_forum"],
            summary["source_soundtrack"],
            summary["none"],
            summary["unmapped"],
            duration_ms,
        )
        top = summary.get("unmapped_top") or []
        if top:
            logger.info(
                "catalog genres: no path, top %s",
                ", ".join(f"{name} {count}" for name, count in top),
            )
        return summary
    finally:
        await conn.close()


async def build_in_connection(conn: asyncpg.Connection) -> dict[str, Any]:
    """Build derived genre tables using the caller's current search_path."""
    if env("FAIL_BUILD") == "genres":
        raise RuntimeError("genres build failure requested")
    try:
        await _create_load(conn)
        summary = await _fill(conn)
        await _swap(conn)
        return summary
    except Exception:
        await conn.execute("DROP TABLE IF EXISTS our_genre_map_load")
        await conn.execute("DROP TABLE IF EXISTS artist_genre_load")
        await conn.execute("DROP TABLE IF EXISTS artist_country_load")
        raise


async def _fill(conn: asyncpg.Connection) -> dict[str, Any]:
    genres = await conn.fetch("SELECT mbid, name FROM mb_genre")
    edges = await conn.fetch(
        "SELECT child_mbid, parent_mbid FROM mb_genre_edge WHERE kind = 'subgenre'"
    )
    name_of: dict[UUID, str] = {_uuid(row["mbid"]): str(row["name"]) for row in genres}
    roots: dict[UUID, str] = {}
    for mbid, name in name_of.items():
        slug = ROOT_MAP.get(name.casefold())
        if slug is not None and slug in OUR_SLUGS:
            roots[mbid] = slug
    parents: dict[UUID, list[UUID]] = defaultdict(list)
    for row in edges:
        parents[_uuid(row["child_mbid"])].append(_uuid(row["parent_mbid"]))

    mapped: dict[UUID, str] = {}
    unmapped_names: list[str] = []
    for mbid, name in name_of.items():
        slug = map_genre(mbid, roots=roots, parents=parents)
        if slug is None:
            unmapped_names.append(name)
            slug = "worldwide"
        mapped[mbid] = slug
    if mapped:
        await conn.copy_records_to_table(
            "our_genre_map_load",
            records=[(mbid, slug) for mbid, slug in mapped.items()],
            columns=("mb_genre_mbid", "slug"),
        )

    genre_by_name = {name.casefold(): mbid for mbid, name in name_of.items()}

    areas = {
        _uuid(row["mbid"]): (row["iso3166"], str(row["name"]))
        for row in await conn.fetch("SELECT mbid, iso3166, name FROM mb_area")
    }
    parts: dict[UUID, list[UUID]] = defaultdict(list)
    for row in await conn.fetch("SELECT child_mbid, parent_mbid FROM mb_area_part"):
        parts[_uuid(row["child_mbid"])].append(_uuid(row["parent_mbid"]))

    artists = await conn.fetch(
        "SELECT mbid, name, area_mbid, begin_area_mbid FROM mb_artist"
    )
    aliases = await conn.fetch("SELECT artist_mbid, name FROM mb_artist_alias")
    by_key: dict[str, set[UUID]] = defaultdict(set)
    area_of: dict[UUID, UUID | None] = {}
    begin_of: dict[UUID, UUID | None] = {}
    for row in artists:
        mbid = _uuid(row["mbid"])
        by_key[norm(str(row["name"]))].add(mbid)
        area_of[mbid] = _uuid(row["area_mbid"]) if row["area_mbid"] is not None else None
        begin_of[mbid] = (
            _uuid(row["begin_area_mbid"]) if row["begin_area_mbid"] is not None else None
        )
    for row in aliases:
        by_key[norm(str(row["name"]))].add(_uuid(row["artist_mbid"]))
    unique_key = {key: next(iter(ids)) for key, ids in by_key.items() if len(ids) == 1}

    soundtrack_of: dict[UUID, tuple[int, int]] = {}
    for row in await conn.fetch(
        """
        SELECT artist_mbid,
               count(*) AS total,
               count(*) FILTER (WHERE 'Soundtrack' = ANY(secondary_types)) AS ost
        FROM mb_release_group
        WHERE artist_mbid IS NOT NULL
        GROUP BY artist_mbid
        """
    ):
        soundtrack_of[_uuid(row["artist_mbid"])] = (int(row["ost"]), int(row["total"]))

    mb_weights: dict[UUID, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    mb_local: dict[UUID, dict[UUID, tuple[str, int]]] = defaultdict(dict)
    unmapped_tag: dict[str, int] = defaultdict(int)
    tag_rows = await conn.fetch(
        """
        SELECT t.artist_mbid, g.mbid AS genre_mbid, g.name, t.count
        FROM mb_artist_tag t
        JOIN mb_tag tag ON tag.id = t.tag_id
        JOIN mb_genre g ON lower(g.name) = lower(tag.name)
        """
    )
    for row in tag_rows:
        artist = _uuid(row["artist_mbid"])
        genre_mbid = _uuid(row["genre_mbid"])
        slug = mapped.get(genre_mbid) or "worldwide"
        weight = int(row["count"] or 0)
        if genre_mbid in mapped and mapped[genre_mbid] == "worldwide" and str(row["name"]) in unmapped_names:
            unmapped_tag[str(row["name"])] += weight
        elif map_genre(genre_mbid, roots=roots, parents=parents) is None:
            unmapped_tag[str(row["name"])] += weight
        mb_weights[artist][slug] += weight
        prev = mb_local[artist].get(genre_mbid)
        mb_local[artist][genre_mbid] = (slug, weight + (prev[1] if prev else 0))

    lastfm_weights: dict[UUID, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    lastfm_local: dict[UUID, dict[UUID, tuple[str, int]]] = defaultdict(dict)
    for row in await conn.fetch(
        "SELECT artist_key, tags FROM lastfm_artists WHERE found AND tags <> '{}'"
    ):
        artist_id = unique_key.get(str(row["artist_key"]))
        if artist_id is None:
            continue
        names = list(row["tags"] or [])
        for name in names:
            raw = str(name)
            folded = raw.casefold()
            genre_id = genre_by_name.get(folded)
            if genre_id is None:
                continue
            slug = mapped.get(genre_id) or "worldwide"
            if map_genre(genre_id, roots=roots, parents=parents) is None:
                unmapped_tag[raw] += 1
            lastfm_weights[artist_id][slug] += 1
            prev = lastfm_local[artist_id].get(genre_id)
            lastfm_local[artist_id][genre_id] = (slug, 1 + (prev[1] if prev else 0))

    rt_weights: dict[UUID, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    for row in await conn.fetch(
        "SELECT artist_key, genre, popularity FROM catalog_artists"
    ):
        artist_id = unique_key.get(str(row["artist_key"]))
        if artist_id is None:
            continue
        slug = CATALOG_TO_OUR.get(str(row["genre"]))
        if slug is None or slug not in OUR_SLUGS:
            continue
        rt_weights[artist_id][slug] += int(row["popularity"] or 0)

    def local_of(store: dict[UUID, dict[UUID, tuple[str, int]]], artist: UUID, slug: str) -> UUID | None:
        best: tuple[int, UUID] | None = None
        for genre_mbid, (mapped_slug, weight) in store.get(artist, {}).items():
            if mapped_slug != slug:
                continue
            cand = (weight, genre_mbid)
            if best is None or cand[0] > best[0]:
                best = cand
        return best[1] if best else None

    rows: list[tuple[UUID, str, str, int, bool, UUID | None]] = []
    countries: list[tuple[UUID, str, str]] = []
    source_counts = {"mb": 0, "lastfm": 0, "forum": 0, "soundtrack": 0}
    none = 0
    seen_artists = [_uuid(row["mbid"]) for row in artists]
    for mbid in seen_artists:
        country = resolve_country(
            area_of.get(mbid), begin_of.get(mbid), areas=areas, parts=parts
        )
        if country is not None:
            countries.append((mbid, country[0], country[1]))
        ost, total = soundtrack_of.get(mbid, (0, 0))
        chosen: tuple[str, str, int] | None = None
        local: UUID | None = None
        if total > 0 and ost * 2 > total:
            chosen = ("soundtrack", "soundtrack", ost)
        if chosen is None:
            picked = pick_top(mb_weights.get(mbid) or {})
            if picked is not None:
                chosen = (picked[0], "mb", picked[1])
                local = local_of(mb_local, mbid, picked[0])
        if chosen is None:
            picked = pick_top(lastfm_weights.get(mbid) or {})
            if picked is not None:
                chosen = (picked[0], "lastfm", picked[1])
                local = local_of(lastfm_local, mbid, picked[0])
        if chosen is None:
            picked = pick_top(rt_weights.get(mbid) or {})
            if picked is not None:
                chosen = (picked[0], "forum", picked[1])
        if chosen is None:
            none += 1
            continue
        slug, source, score = chosen
        if slug not in OUR_SLUGS:
            none += 1
            continue
        source_counts[source] += 1
        rows.append((mbid, slug, source, score, True, local))

    if rows:
        await conn.copy_records_to_table(
            "artist_genre_load",
            records=rows,
            columns=("artist_mbid", "slug", "source", "score", "is_primary", "mb_genre_mbid"),
        )
    if countries:
        await conn.copy_records_to_table(
            "artist_country_load",
            records=countries,
            columns=("artist_mbid", "iso", "source"),
        )

    unmapped_top = sorted(unmapped_tag.items(), key=lambda item: (-item[1], item[0]))[:10]
    if not unmapped_top:
        unmapped_top = [(name, 0) for name in sorted(unmapped_names)[:10]]
    return {
        "artists": len(rows),
        "countries": len(countries),
        "source_mb": source_counts["mb"],
        "source_lastfm": source_counts["lastfm"],
        "source_forum": source_counts["forum"],
        "source_soundtrack": source_counts["soundtrack"],
        "none": none,
        "unmapped": len(unmapped_names),
        "unmapped_top": unmapped_top,
        "unmapped_examples": unmapped_names[:10],
    }


def main(argv: list[str]) -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    parser = argparse.ArgumentParser(prog="python -m app.catalog_genres")
    sub = parser.add_subparsers(dest="cmd")
    sub.add_parser("build")
    args = parser.parse_args(argv)
    if args.cmd != "build":
        parser.print_help()
        return 2
    url = os.environ.get("DATABASE_URL")
    if not url:
        print("DATABASE_URL не задан", file=sys.stderr)
        return 2
    result = asyncio.run(build(url))
    print(json.dumps(result, ensure_ascii=False, default=str))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
