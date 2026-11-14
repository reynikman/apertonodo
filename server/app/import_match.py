"""Match imported rows against local catalogs, without network, writes or logs."""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any, Literal
from uuid import UUID, uuid5

import asyncpg

from app.canonical import canonical_key
from app.import_formats import ImportRow
from app.names import norm

# Same namespace as app.main, without importing its application initialization.
_TRACK_NAMESPACE = UUID("6f1b4b8e-2f6a-5f2a-9a3b-1c0d8e7f4a21")
_BATCH_SIZE = 500
_GUEST = re.compile(
    r"(?:\(\s*(?:feat\.?|ft\.?|featuring|with)\s+[^()]*\)"
    r"|\[\s*(?:feat\.?|ft\.?|featuring|with)\s+[^\[\]]*\])\s*",
    re.IGNORECASE,
)
_EDITION = re.compile(
    r"\b(?:remaster(?:ed)?|mono|stereo|single\s+version|album\s+version"
    r"|radio\s+edit|explicit|clean)\b",
    re.IGNORECASE,
)
_PERFORMANCE = re.compile(r"\b(?:live|acoustic|remix)\b", re.IGNORECASE)


@dataclass(frozen=True)
class Match:
    status: Literal["found", "doubtful", "missing"]
    track: dict[str, Any] | None = None
    candidates: list[dict[str, Any]] = field(default_factory=list)


_ISRC_SQL = """
SELECT q.idx, hit.*
FROM unnest($1::int[], $2::text[]) AS q(idx, isrc)
CROSS JOIN LATERAL (
    SELECT DISTINCT s.original_recording_mbid::text AS id, s.title,
           a.name AS artist, coalesce(r.length_ms, 0) AS duration_ms
    FROM mb_isrc i
    JOIN song_version v ON v.recording_mbid = i.recording_mbid
    JOIN song s ON s.id = v.song_id
    JOIN mb_artist a ON a.mbid = s.artist_mbid
    LEFT JOIN mb_recording r ON r.mbid = s.original_recording_mbid
    WHERE i.isrc = q.isrc
    ORDER BY id, s.title, a.name
    LIMIT 3
) hit
"""

# OFFSET 0 keeps these LATERAL lookups parameterized even when artist counts
# are overestimated: title filters stay outside the artist-only song scan,
# and details use key lookups rather than whole-table joins before LIMIT 3.
_EXACT_SQL = """
SELECT q.idx, hit.*
FROM unnest($1::int[], $2::text[], $3::text[]) AS q(idx, artist, title)
CROSS JOIN LATERAL (
    WITH artists AS MATERIALIZED (
        SELECT mbid FROM mb_artist WHERE lower(name) = lower(q.artist)
        UNION
        SELECT artist_mbid FROM mb_artist_alias WHERE lower(name) = lower(q.artist)
    )
    SELECT s.original_recording_mbid::text AS id, s.title,
           a.name AS artist, coalesce(r.length_ms, 0) AS duration_ms
    FROM artists art
    CROSS JOIN LATERAL (
        SELECT id, title, original_recording_mbid
        FROM song WHERE artist_mbid = art.mbid
        OFFSET 0
    ) s
    CROSS JOIN LATERAL (
        SELECT name FROM mb_artist WHERE mbid = art.mbid
        OFFSET 0
    ) a
    LEFT JOIN LATERAL (
        SELECT length_ms FROM mb_recording WHERE mbid = s.original_recording_mbid
        OFFSET 0
    ) r ON true
    WHERE lower(s.title) = lower(q.title)
    ORDER BY s.original_recording_mbid, s.id
    LIMIT 3
) hit
"""

_OWN_SQL = """
SELECT q.idx, NULL::text AS id, c.title, c.artist, 0 AS duration_ms
FROM unnest($1::int[], $2::text[], $3::text[]) AS q(idx, artist_key, title_key)
JOIN catalog_tracks c ON c.artist_key = q.artist_key AND c.title_key = q.title_key
"""

_FUZZY_SQL = """
SELECT q.idx, hit.*
FROM unnest($1::int[], $2::text[], $3::text[]) AS q(idx, artist, title)
CROSS JOIN LATERAL (
    WITH artists AS MATERIALIZED (
        SELECT mbid FROM mb_artist WHERE lower(name) = lower(q.artist)
        UNION
        SELECT artist_mbid FROM mb_artist_alias WHERE lower(name) = lower(q.artist)
    )
    SELECT s.original_recording_mbid::text AS id, s.title,
           a.name AS artist, coalesce(r.length_ms, 0) AS duration_ms
    FROM artists art
    CROSS JOIN LATERAL (
        SELECT id, title, original_recording_mbid
        FROM song WHERE artist_mbid = art.mbid
        OFFSET 0
    ) s
    CROSS JOIN LATERAL (
        SELECT name FROM mb_artist WHERE mbid = art.mbid
        OFFSET 0
    ) a
    LEFT JOIN LATERAL (
        SELECT length_ms FROM mb_recording WHERE mbid = s.original_recording_mbid
        OFFSET 0
    ) r ON true
    WHERE similarity(s.title, q.title) >= 0.3
    ORDER BY similarity(s.title, q.title) DESC, s.original_recording_mbid, s.id
    LIMIT 3
) hit
"""

_NO_ARTIST_SQL = """
SELECT q.idx, hit.*
FROM unnest($1::int[], $2::text[]) AS q(idx, title_key)
CROSS JOIN LATERAL (
    SELECT NULL::text AS id, title, artist, 0 AS duration_ms
    FROM catalog_tracks
    WHERE title_key = q.title_key
    ORDER BY weight DESC, artist_key, title_key
    LIMIT 3
) hit
"""


def _clean_title(title: str) -> str:
    parts = _GUEST.sub("", title).strip().split(" - ")
    return " - ".join(
        part.strip() for idx, part in enumerate(parts)
        if idx == 0 or not _EDITION.search(part) or _PERFORMANCE.search(part)
    )


def _track(row: asyncpg.Record) -> dict[str, Any]:
    artist, title = row["artist"], row["title"]
    return {
        "id": row["id"] or str(uuid5(_TRACK_NAMESPACE, canonical_key(artist, title))),
        "title": title,
        "artist": artist,
        "duration_ms": row["duration_ms"],
        "artwork_url": "",
    }


async def match_rows(conn: asyncpg.Connection, rows: list[ImportRow]) -> list[Match]:
    """Return one result per row; each stage fetches at most 500 inputs at once."""
    result = [Match("missing") for _ in rows]
    for start in range(0, len(rows), _BATCH_SIZE):
        batch = rows[start:start + _BATCH_SIZE]
        artists = [row.artist.strip() for row in batch]
        titles = [_clean_title(row.title) for row in batch]
        isrcs = [row.isrc.replace("-", "").strip().upper() for row in batch]
        artist_keys = [norm(artist) for artist in artists]
        title_keys = [norm(title) for title in titles]
        stages = (
            (_ISRC_SQL, [isrcs], False),
            (_EXACT_SQL, [artists, titles], False),
            (_OWN_SQL, [artist_keys, title_keys], False),
            (_FUZZY_SQL, [artists, titles], True),
            (_NO_ARTIST_SQL, [title_keys], True),
        )
        for stage, (sql, columns, doubtful) in enumerate(stages):
            pending = [
                idx for idx in range(len(batch))
                if result[start + idx].status == "missing" and (
                    bool(isrcs[idx]) if stage == 0 else
                    bool(title_keys[idx]) and (
                        not artists[idx] if stage == 4 else bool(artists[idx])
                    )
                )
            ]
            if not pending:
                continue
            hits = await conn.fetch(sql, pending, *[
                [column[idx] for idx in pending] for column in columns
            ])
            grouped: dict[int, list[dict[str, Any]]] = {}
            for hit in hits:
                cards = grouped.setdefault(hit["idx"], [])
                card = _track(hit)
                if all(existing["id"] != card["id"] for existing in cards):
                    cards.append(card)
            for idx, cards in grouped.items():
                if doubtful or len(cards) > 1:
                    result[start + idx] = Match("doubtful", cards[0], cards[:3])
                else:
                    result[start + idx] = Match("found", cards[0])
    return result
