"""Catalog: genres, artists A–Z, what is playable.

Artists and genres come from extension exports (`catalog_from_extensions`),
whether a song or album is playable is queried from them as well (`playable_from_extensions`).
Without extensions there is nothing to play: "playable" is "no" everywhere.

`python -m app.catalog build` — rebuild catalog from extensions (`EXTENSIONS`).
Later it rebuilds itself when older than `EXTENSION_REBUILD_S`.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import sys
import time
import unicodedata
from datetime import UTC, datetime
from typing import Any

import asyncpg
import httpx

from app.genres import GENRE_NAMES
from app.extensions import parse_extensions
from app.names import norm
from app.playable_from_extensions import Playable

logger = logging.getLogger("apertonodo")

LEADING_TAGS = re.compile(r"^\s*(?:(?:\([^)]*\)|\[[^\]]*\])\s*)+")
TRAILING_TAGS = re.compile(r"(?:\s*(?:\([^)]*\)|\[[^\]]*\]))+\s*$")
ARTIST_SEP = re.compile(r"\s+[-–—]\s+")
YEAR_FIRST = re.compile(r"^\d{4}\b")
# Compilations of various artists are not an artist. Keys are after `norm`.
NOT_ARTISTS = frozenset(
    {"va", "v a", "various", "various artists", "сборник", "сборники", "разные исполнители"}
)
MAX_ARTIST_CHARS = 80


def artist_of(title: str) -> str | None:
    """Artist from the release title or None if absent.

    "Album Title - 2009, FLAC" has two chunks, and the second starts with a year:
    there is no artist in such a title (soundtracks, authorless classical), and
    the first chunk would be the album title.
    """
    parts = ARTIST_SEP.split(LEADING_TAGS.sub("", title))
    if len(parts) < 2 or (len(parts) == 2 and YEAR_FIRST.match(parts[1].strip())):
        return None
    name = TRAILING_TAGS.sub("", parts[0]).strip(" .,:;/")
    key = norm(name)
    if not key or key in NOT_ARTISTS or len(name) > MAX_ARTIST_CHARS:
        return None
    return name


def letter_of(key: str) -> str:
    """Index letter: A–Z or '#'. 'Édith' -> E, 'Ёлка' -> 'Е'."""
    first = unicodedata.normalize("NFKD", key[:1])[:1].upper()
    if "A" <= first <= "Z" or "А" <= first <= "Я":
        return first
    return "#"


async def genres(conn: asyncpg.Connection) -> list[dict[str, object]]:
    rows = await conn.fetch(
        "SELECT genre, count(*) AS n FROM catalog_artists c "
        "LEFT JOIN catalog_open_names o ON o.name = c.name "
        "WHERE o.listed OR NOT EXISTS (SELECT 1 FROM catalog_open_names) GROUP BY genre"
    )
    listed = [
        {"id": row["genre"], "name": GENRE_NAMES[row["genre"]], "artists": row["n"]}
        for row in rows
        if row["genre"] in GENRE_NAMES
    ]
    return sorted(listed, key=lambda item: str(item["name"]).casefold())


async def genre_artists(
    conn: asyncpg.Connection, genre: str, offset: int, limit: int | None
) -> tuple[list[str], int]:
    """Genre artists alphabetically: Latin, Cyrillic, other."""
    rows = await conn.fetch(
        "SELECT c.name, count(*) OVER () AS total FROM catalog_artists c "
        "LEFT JOIN catalog_open_names o ON o.name = c.name WHERE genre = $1 "
        "AND (o.listed OR NOT EXISTS (SELECT 1 FROM catalog_open_names)) "
        "ORDER BY CASE"
        "  WHEN c.name ~ '^[A-Za-zÀ-ÖØ-öø-ɏ]' THEN 0"
        "  WHEN c.name ~ '^[Ѐ-ӿ]' THEN 1 ELSE 2 END,"
        "  c.name COLLATE \"und-x-icu\", artist_key LIMIT $2 OFFSET $3",
        genre,
        limit,
        offset,
    )
    total = rows[0]["total"] if rows else await conn.fetchval(
        "SELECT count(*) FROM catalog_artists c LEFT JOIN catalog_open_names o ON o.name = c.name "
        "WHERE genre = $1 AND (o.listed OR NOT EXISTS (SELECT 1 FROM catalog_open_names))", genre
    )
    return [row["name"] for row in rows], int(total)


def genre_letters(names: list[str]) -> list[dict[str, object]]:
    """Letters and their positions in the same alphabetical list that browses the genre."""
    grouped: list[dict[str, object]] = []
    start = 0
    for offset, name in enumerate(names):
        alphabetic = re.match(r"^[A-Za-zÀ-ÖØ-öø-ɏЀ-ӿ]", name)
        letter = letter_of(norm(name)) if alphabetic else "#"
        # "Ørjan", "Ісус" without their own letter stay in the previous group.
        if letter == "#" and alphabetic and grouped:
            letter = str(grouped[-1]["letter"])
        if not grouped or grouped[-1]["letter"] != letter:
            start = offset
            grouped.append({"letter": letter, "artists": 0, "offset": offset})
        grouped[-1]["artists"] = offset - start + 1
    return grouped


async def letters(conn: asyncpg.Connection) -> list[dict[str, object]]:
    rows = await conn.fetch(
        "SELECT letter, count(DISTINCT artist_key) AS n FROM catalog_artists c "
        "LEFT JOIN catalog_open_names o ON o.name = c.name "
        "WHERE o.listed OR NOT EXISTS (SELECT 1 FROM catalog_open_names) GROUP BY letter"
    )

    def order(letter: str) -> tuple[int, str]:
        # Cyrillic first, then Latin, "#" at the end — like in a phonebook.
        return (0 if "А" <= letter <= "Я" else 1 if letter != "#" else 2, letter)

    return [
        {"letter": row["letter"], "artists": row["n"]}
        for row in sorted(rows, key=lambda row: order(row["letter"]))
    ]


async def letter_artists(
    conn: asyncpg.Connection, letter: str, offset: int, limit: int
) -> tuple[list[str], int]:
    """Artists for a letter, alphabetically. An artist in three genres appears once."""
    rows = await conn.fetch(
        "SELECT name, count(*) OVER () AS total FROM ("
        "  SELECT DISTINCT ON (artist_key) artist_key, c.name FROM catalog_artists c"
        "  LEFT JOIN catalog_open_names o ON o.name = c.name"
        "  WHERE letter = $1 AND (o.listed OR NOT EXISTS (SELECT 1 FROM catalog_open_names))"
        "  ORDER BY artist_key, popularity DESC"
        ") one ORDER BY artist_key LIMIT $2 OFFSET $3",
        letter,
        limit,
        offset,
    )
    total = rows[0]["total"] if rows else await conn.fetchval(
        "SELECT count(DISTINCT artist_key) FROM catalog_artists c "
        "LEFT JOIN catalog_open_names o ON o.name = c.name WHERE letter = $1 "
        "AND (o.listed OR NOT EXISTS (SELECT 1 FROM catalog_open_names))", letter
    )
    return [row["name"] for row in rows], int(total)


async def alphabet_artists(
    conn: asyncpg.Connection, offset: int, limit: int
) -> tuple[list[str], int]:
    """Artists from the beginning of the alphabet. An artist in three genres appears once.

    Start screen calls /v1/artists without a letter: this is the same index, only
    without WHERE letter.
    """
    rows = await conn.fetch(
        "SELECT name, count(*) OVER () AS total FROM ("
        "  SELECT DISTINCT ON (artist_key) artist_key, c.name FROM catalog_artists c"
        "  LEFT JOIN catalog_open_names o ON o.name = c.name"
        "  WHERE o.listed OR NOT EXISTS (SELECT 1 FROM catalog_open_names)"
        "  ORDER BY artist_key, popularity DESC"
        ") one ORDER BY artist_key LIMIT $1 OFFSET $2",
        limit,
        offset,
    )
    total = rows[0]["total"] if rows else await conn.fetchval(
        "SELECT count(DISTINCT artist_key) FROM catalog_artists c "
        "LEFT JOIN catalog_open_names o ON o.name = c.name "
        "WHERE o.listed OR NOT EXISTS (SELECT 1 FROM catalog_open_names)"
    )
    return [row["name"] for row in rows], int(total)


# "Playable" is queried from extensions (`POST /v1/has`). Installed by the application
# for lifespan (`main.py`, lifespan); until set — there are no extensions and the answer is "no".
_extensions: Playable | None = None


def use_extensions(playable: Playable | None) -> None:
    global _extensions
    _extensions = playable


async def playable(conn: asyncpg.Connection | None, artist: str, titles: list[str]) -> list[bool]:
    """For each title (album or song): whether it is playable by extensions.

    Connection is not needed by extensions; parameter is kept to avoid touching call sites.
    """
    if _extensions is None:
        return [False] * len(titles)
    return await _extensions.playable(artist, titles)


async def playable_pairs(
    conn: asyncpg.Connection | None, pairs: list[tuple[str, str]]
) -> list[bool]:
    """Whether each "artist - song" pair is playable: response from extensions (see `playable`)."""
    if _extensions is None:
        return [False] * len(pairs)
    return await _extensions.pairs(pairs)


# Own songs for search results. Titles in standard case in own database
# come from exactly one source — Last.fm top tracks: release tracklists are stored
# normalized (`release_index.py`), with no raw string available. Therefore the song
# list is built from top tracks, and a live release for each is verified with `playable` —
# using the same rule that Play later uses to search.
TRACK_QUEUE_SQL = """
SELECT l.artist_key, c.name, l.top_tracks,
       c.pop + coalesce(l.listeners, 0) AS weight
FROM lastfm_artists l
JOIN (
    SELECT artist_key, (array_agg(name ORDER BY popularity DESC))[1] AS name,
           sum(popularity) AS pop
    FROM catalog_artists GROUP BY artist_key
) c USING (artist_key)
WHERE l.found AND cardinality(l.top_tracks) > 0
"""


async def build_tracks(database_url: str, *, ask: Playable | None = None) -> int:
    """Rebuild `catalog_tracks`. Returns the number of songs.

    `ask` — custom "is playable" query to extensions during the build: the global one (`use_extensions`)
    is not touched, so the server during and after it responds as before (FT-763).

    Built into a staging table and swaps the working one with a single rename:
    the crawl takes minutes, and throughout that time search must respond using the old
    list rather than half of a new one.
    """
    began = time.monotonic()
    conn = await asyncpg.connect(database_url)
    try:
        rows: list[tuple[str, str, str, str, int]] = []
        timed_out: list[str] = []
        for row in await conn.fetch(TRACK_QUEUE_SQL):
            titles = list(row["top_tracks"])
            try:
                plays = (
                    await ask.playable(row["name"], titles)
                    if ask is not None
                    else await playable(conn, row["name"], titles)
                )
            except asyncio.TimeoutError:
                timed_out.append(row["artist_key"])
                continue
            for title, ok in zip(titles, plays, strict=True):
                if ok and norm(title):
                    rows.append(
                        (row["artist_key"], norm(title), row["name"], title, int(row["weight"]))
                    )
        if timed_out:
            kept = await conn.fetch(
                "SELECT artist_key, title_key, artist, title, weight FROM catalog_tracks "
                "WHERE artist_key = ANY($1::text[])", timed_out,
            )
            rows.extend(tuple(row) for row in kept)
            logger.info("catalog: %d artists timed out, kept their old songs", len(timed_out))
        await conn.execute("DROP TABLE IF EXISTS catalog_tracks_load")
        await conn.execute(
            "CREATE TABLE catalog_tracks_load (LIKE catalog_tracks INCLUDING DEFAULTS)"
        )
        # The same artist comes as a single queue row, but two
        # different top tracks occasionally collide into the same `norm` ("Numb" and
        # "Numb."). The table key is composite, so duplicates must be removed here.
        unique = list({(row[0], row[1]): row for row in rows}.values())
        await conn.copy_records_to_table(
            "catalog_tracks_load",
            records=unique,
            columns=("artist_key", "title_key", "artist", "title", "weight"),
        )
        await conn.execute("ALTER TABLE catalog_tracks_load ADD PRIMARY KEY (artist_key, title_key)")
        await conn.execute(
            "CREATE INDEX catalog_tracks_load_title "
            "ON catalog_tracks_load (title_key text_pattern_ops)"
        )
        await conn.execute(
            "CREATE INDEX catalog_tracks_load_weight ON catalog_tracks_load (weight DESC)"
        )
        await conn.execute(
            "CREATE INDEX catalog_tracks_load_fts ON catalog_tracks_load "
            "USING gin (to_tsvector('simple', artist_key || ' ' || title_key))"
        )
        async with conn.transaction():
            await conn.execute("DROP TABLE catalog_tracks")
            await conn.execute("ALTER TABLE catalog_tracks_load RENAME TO catalog_tracks")
            await conn.execute("ALTER INDEX catalog_tracks_load_pkey RENAME TO catalog_tracks_pkey")
            await conn.execute(
                "ALTER INDEX catalog_tracks_load_title RENAME TO catalog_tracks_title"
            )
            await conn.execute(
                "ALTER INDEX catalog_tracks_load_weight RENAME TO catalog_tracks_weight"
            )
            await conn.execute("ALTER INDEX catalog_tracks_load_fts RENAME TO catalog_tracks_fts")
    finally:
        await conn.close()
    logger.info(
        "catalog: built %d songs in %d ms", len(unique), int((time.monotonic() - began) * 1000)
    )
    return len(unique)


EXTENSION_REBUILD_S = 6 * 3600  # with `EXTENSIONS`, catalog older than this rebuilds itself (FT-763)


async def needs_build_from_extensions(conn: asyncpg.Connection) -> bool:
    """With extensions there are no local popularity data: catalog is not built or built long ago."""
    built = await conn.fetchval("SELECT built_at FROM catalog_built WHERE id = 1")
    return built is None or (datetime.now(UTC) - built).total_seconds() > EXTENSION_REBUILD_S


async def build_from_extensions(database_url: str, urls: dict[str, str]) -> dict[str, Any]:
    """P8 (FT-757): genre catalog from extension exports, songs from their `/v1/has`.
    If one extension does not answer — keep the old catalog in full (`{"catalog": "kept"}`)."""
    from app import catalog_from_extensions  # it imports from this module itself

    async with httpx.AsyncClient() as client:
        result = await catalog_from_extensions.build(database_url, urls, client=client)
        if result.status == "kept":
            return {"catalog": "kept", "reason": result.reason}
        songs = await build_tracks(database_url, ask=Playable(urls, client=client))
    return {"artists": result.artists, "genres": result.genres, "songs": songs}


async def _build_from_extensions(database_url: str, urls: dict[str, str]) -> int:
    summary = await build_from_extensions(database_url, urls)
    print(json.dumps(summary))
    return 1 if summary.get("catalog") == "kept" else 0


def main(argv: list[str]) -> int:
    """`build` — rebuild catalog: from extensions (`EXTENSIONS`)."""
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    if argv[:1] == ["build"]:
        url = os.environ["DATABASE_URL"]
        urls = parse_extensions(os.environ.get("EXTENSIONS", ""))
        if urls:
            return asyncio.run(_build_from_extensions(url, urls))
        print("EXTENSIONS is empty: nothing to build the catalog from", file=sys.stderr)
        return 2
    print(main.__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
