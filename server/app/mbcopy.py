"""Own copy of the needed MusicBrainz slice: dump stream, without 100 GB on disk.

`python -m app.mbcopy load [--url LATEST|<dir>] [--file path.tar.bz2]`

Archive is not written to disk: HTTP (same `MUSICBRAINZ_PROXY` as the catalog)
→ bz2 → tar. Only the needed `mbdump/<table>` are taken from the tar. Mismatched
SCHEMA_SEQUENCE triggers refusal; the existing copy is not touched. We write to
`mb_*_new`, then swap the live tables in a single transaction.

Tablespace `mb` is created by this loader, not by a migration: `CREATE TABLESPACE`
is not allowed inside a transaction, and the catalog is absent in tests.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import tarfile
import threading
import time
from collections.abc import Awaitable, Callable, Iterator, Mapping
from datetime import date, datetime
from typing import Any
from uuid import UUID, uuid4

import asyncpg
import httpx

from app import search_indexes

logger = logging.getLogger("apertonodo")

# lib/DBDefs/Default.pm ACTIVE_SCHEMA_SEQUENCE and the dump's SCHEMA_SEQUENCE file.
SCHEMA_SEQUENCE = 31
DUMP_ROOT = "https://data.metabrainz.org/pub/musicbrainz/data/fullexport"
TABLESPACE_DIR = "/var/lib/postgresql/mb"
BATCH = 2000
CHECK_INTERVAL_S = 3600.0
RETRY_AFTER_FAIL_S = 24 * 3600.0
READ_TIMEOUT_S = 300.0
MAINTENANCE_WORK_MEM = "512MB"
LOADER_LOCK_ID = 17017
SPACE_MULTIPLIER = 6
# FT-440: margin on top of WAL + today's hot size for the new copy that
# builds alongside the old one until the swap (see hot_fits_main_volume).
MAIN_VOLUME_RESERVE_BYTES = 10 * 2**30
ARCHIVES = ("mbdump.tar.bz2", "mbdump-derived.tar.bz2")
# https://musicbrainz.org/relationship/… — kind in its own table.
PART_OF_GID = UUID("de7cc874-8d13-45a6-8586-979a2521e470")
SUBGENRE_GID = UUID("9d61bc67-fa39-4719-8025-ea056a5bd7e6")
MEMBER_GID = UUID("5be4c609-9afa-4ea0-910b-12ffb71e3821")
# Artist official URL types (link_type.gid) → kind in mb_artist_url.
OFFICIAL_GID = UUID("fe33d22f-c3b0-4d68-bd53-a856badf2b15")
YOUTUBE_GID = UUID("6a540e5b-58c6-4192-b6ba-dbc71ec8fcf0")
SOCIAL_GID = UUID("99429741-f3f6-484b-84f8-23af51991770")

# Column order — admin/sql/CreateTables.sql musicbrainz-server,
# schema 31 (ACTIVE_SCHEMA_SEQUENCE in lib/DBDefs/Default.pm).
DUMP_COLUMNS: dict[str, tuple[str, ...]] = {
    "artist": (
        "id", "gid", "name", "sort_name",
        "begin_date_year", "begin_date_month", "begin_date_day",
        "end_date_year", "end_date_month", "end_date_day",
        "type", "area", "gender", "comment", "edits_pending", "last_updated",
        "ended", "begin_area", "end_area",
    ),
    "artist_alias": (
        "id", "artist", "name", "locale", "edits_pending", "last_updated",
        "type", "sort_name",
        "begin_date_year", "begin_date_month", "begin_date_day",
        "end_date_year", "end_date_month", "end_date_day",
        "primary_for_locale", "ended",
    ),
    "artist_type": ("id", "name", "parent", "child_order", "description", "gid"),
    "area": (
        "id", "gid", "name", "type", "edits_pending", "last_updated",
        "begin_date_year", "begin_date_month", "begin_date_day",
        "end_date_year", "end_date_month", "end_date_day", "ended", "comment",
    ),
    "area_type": ("id", "name", "parent", "child_order", "description", "gid"),
    "iso_3166_1": ("area", "code"),
    "l_area_area": (
        "id", "link", "entity0", "entity1", "edits_pending", "last_updated",
        "link_order", "entity0_credit", "entity1_credit",
    ),
    "artist_credit": (
        "id", "name", "artist_count", "ref_count", "created", "edits_pending", "gid",
    ),
    "artist_credit_name": ("artist_credit", "position", "artist", "name", "join_phrase"),
    "release_group": (
        "id", "gid", "name", "artist_credit", "type", "comment",
        "edits_pending", "last_updated",
    ),
    "release_group_primary_type": (
        "id", "name", "parent", "child_order", "description", "gid",
    ),
    "release_group_secondary_type": (
        "id", "name", "parent", "child_order", "description", "gid",
    ),
    "release_group_secondary_type_join": ("release_group", "secondary_type", "created"),
    "release": (
        "id", "gid", "name", "artist_credit", "release_group", "status",
        "packaging", "language", "script", "barcode", "comment",
        "edits_pending", "quality", "last_updated",
    ),
    "release_status": ("id", "name", "parent", "child_order", "description", "gid"),
    "release_country": ("release", "country", "date_year", "date_month", "date_day"),
    "release_unknown_country": ("release", "date_year", "date_month", "date_day"),
    "medium": (
        "id", "release", "position", "format", "name", "edits_pending",
        "last_updated", "track_count", "gid",
    ),
    "medium_format": (
        "id", "name", "parent", "child_order", "year", "has_discids",
        "description", "gid",
    ),
    "track": (
        "id", "gid", "recording", "medium", "position", "number", "name",
        "artist_credit", "length", "edits_pending", "last_updated", "is_data_track",
    ),
    "recording": (
        "id", "gid", "name", "artist_credit", "length", "comment",
        "edits_pending", "last_updated", "video",
    ),
    "isrc": ("id", "recording", "isrc", "edits_pending", "created"),
    "work": ("id", "gid", "name", "type", "comment", "edits_pending", "last_updated"),
    "l_recording_work": (
        "id", "link", "entity0", "entity1", "edits_pending", "last_updated",
        "link_order", "entity0_credit", "entity1_credit",
    ),
    "link_attribute": ("link", "attribute_type", "created"),
    "link_attribute_type": (
        "id", "parent", "root", "child_order", "gid", "name",
        "description", "last_updated",
    ),
    "genre": ("id", "gid", "name", "comment", "edits_pending", "last_updated"),
    "l_genre_genre": (
        "id", "link", "entity0", "entity1", "edits_pending", "last_updated",
        "link_order", "entity0_credit", "entity1_credit",
    ),
    "l_artist_artist": (
        "id", "link", "entity0", "entity1", "edits_pending", "last_updated",
        "link_order", "entity0_credit", "entity1_credit",
    ),
    "url": ("id", "gid", "url", "edits_pending", "last_updated"),
    "l_artist_url": (
        "id", "link", "entity0", "entity1", "edits_pending", "last_updated",
        "link_order", "entity0_credit", "entity1_credit",
    ),
    "link": (
        "id", "link_type", "begin_date_year", "begin_date_month", "begin_date_day",
        "end_date_year", "end_date_month", "end_date_day", "attribute_count",
        "created", "ended",
    ),
    "link_type": (
        "id", "parent", "child_order", "gid", "entity_type0", "entity_type1",
        "name", "description", "link_phrase", "reverse_link_phrase",
        "long_link_phrase", "last_updated", "is_deprecated", "has_dates",
        "entity0_cardinality", "entity1_cardinality",
    ),
    "tag": ("id", "name", "ref_count"),
    "artist_tag": ("artist", "tag", "count", "last_updated"),
    "release_group_tag": ("release_group", "tag", "count", "last_updated"),
    "recording_tag": ("recording", "tag", "count", "last_updated"),
}

# Which dump fields go into staging: (stg_name, type, dump_column_name)
# kind: i integer, t text, b bool, u uuid.
STAGING: dict[str, tuple[tuple[str, str, str], ...]] = {
    "artist": (
        ("id", "i", "id"), ("gid", "u", "gid"), ("name", "t", "name"),
        ("sort_name", "t", "sort_name"), ("type_id", "i", "type"),
        ("area_id", "i", "area"), ("begin_area_id", "i", "begin_area"),
        ("begin_year", "i", "begin_date_year"), ("ended", "b", "ended"),
    ),
    "artist_alias": (
        ("artist", "i", "artist"), ("name", "t", "name"),
        ("locale", "t", "locale"), ("primary_for_locale", "b", "primary_for_locale"),
    ),
    "artist_type": (("id", "i", "id"), ("name", "t", "name")),
    "area": (
        ("id", "i", "id"), ("gid", "u", "gid"), ("name", "t", "name"),
        ("type_id", "i", "type"),
    ),
    "area_type": (("id", "i", "id"), ("name", "t", "name")),
    "iso_3166_1": (("area", "i", "area"), ("code", "t", "code")),
    "l_area_area": (
        ("link", "i", "link"), ("entity0", "i", "entity0"), ("entity1", "i", "entity1"),
    ),
    "artist_credit": (
        ("id", "i", "id"), ("gid", "u", "gid"), ("name", "t", "name"),
    ),
    "artist_credit_name": (
        ("artist_credit", "i", "artist_credit"), ("position", "i", "position"),
        ("artist", "i", "artist"), ("name", "t", "name"),
    ),
    "release_group": (
        ("id", "i", "id"), ("gid", "u", "gid"), ("name", "t", "name"),
        ("artist_credit", "i", "artist_credit"), ("type_id", "i", "type"),
    ),
    "release_group_primary_type": (("id", "i", "id"), ("name", "t", "name")),
    "release_group_secondary_type": (("id", "i", "id"), ("name", "t", "name")),
    "release_group_secondary_type_join": (
        ("release_group", "i", "release_group"), ("secondary_type", "i", "secondary_type"),
    ),
    "release": (
        ("id", "i", "id"), ("gid", "u", "gid"), ("name", "t", "name"),
        ("release_group", "i", "release_group"), ("status_id", "i", "status"),
    ),
    "release_status": (("id", "i", "id"), ("name", "t", "name")),
    "release_country": (
        ("release", "i", "release"), ("country", "i", "country"),
        ("date_year", "i", "date_year"), ("date_month", "i", "date_month"),
        ("date_day", "i", "date_day"),
    ),
    "release_unknown_country": (
        ("release", "i", "release"), ("date_year", "i", "date_year"),
        ("date_month", "i", "date_month"), ("date_day", "i", "date_day"),
    ),
    "medium": (
        ("id", "i", "id"), ("release", "i", "release"),
        ("position", "i", "position"), ("format_id", "i", "format"),
    ),
    "medium_format": (("id", "i", "id"), ("name", "t", "name")),
    "track": (
        ("gid", "u", "gid"), ("recording", "i", "recording"),
        ("medium", "i", "medium"), ("position", "i", "position"),
        ("name", "t", "name"), ("length", "i", "length"),
    ),
    "recording": (
        ("id", "i", "id"), ("gid", "u", "gid"), ("name", "t", "name"),
        ("artist_credit", "i", "artist_credit"), ("length", "i", "length"),
        ("comment", "t", "comment"),
    ),
    "isrc": (("recording", "i", "recording"), ("isrc", "t", "isrc")),
    "work": (("id", "i", "id"), ("gid", "u", "gid"), ("name", "t", "name")),
    "l_recording_work": (
        ("link", "i", "link"),
        ("entity0", "i", "entity0"), ("entity1", "i", "entity1"),
    ),
    "link_attribute": (
        ("link", "i", "link"), ("attribute_type", "i", "attribute_type"),
    ),
    "link_attribute_type": (("id", "i", "id"), ("name", "t", "name")),
    "genre": (("id", "i", "id"), ("gid", "u", "gid"), ("name", "t", "name")),
    "l_genre_genre": (
        ("link", "i", "link"), ("entity0", "i", "entity0"), ("entity1", "i", "entity1"),
    ),
    "l_artist_artist": (
        ("link", "i", "link"), ("entity0", "i", "entity0"), ("entity1", "i", "entity1"),
    ),
    "url": (("id", "i", "id"), ("url", "t", "url")),
    "l_artist_url": (
        ("link", "i", "link"), ("entity0", "i", "entity0"), ("entity1", "i", "entity1"),
    ),
    "link": (("id", "i", "id"), ("link_type", "i", "link_type")),
    "link_type": (("id", "i", "id"), ("gid", "u", "gid"), ("name", "t", "name")),
    "tag": (("id", "i", "id"), ("name", "t", "name")),
    "artist_tag": (
        ("artist", "i", "artist"), ("tag", "i", "tag"), ("count", "i", "count"),
    ),
    "release_group_tag": (
        ("release_group", "i", "release_group"), ("tag", "i", "tag"), ("count", "i", "count"),
    ),
    "recording_tag": (
        ("recording", "i", "recording"), ("tag", "i", "tag"), ("count", "i", "count"),
    ),
}

STG_SQL = {
    "artist": "id bigint, gid uuid, name text, sort_name text, type_id integer, area_id integer, begin_area_id integer, begin_year smallint, ended boolean",
    "artist_alias": "artist bigint, name text, locale text, primary_for_locale boolean",
    "artist_type": "id bigint, name text",
    "area": "id bigint, gid uuid, name text, type_id integer",
    "area_type": "id bigint, name text",
    "iso_3166_1": "area bigint, code text",
    "l_area_area": "link bigint, entity0 bigint, entity1 bigint",
    "artist_credit": "id bigint, gid uuid, name text",
    "artist_credit_name": "artist_credit bigint, position smallint, artist bigint, name text",
    "release_group": "id bigint, gid uuid, name text, artist_credit bigint, type_id integer",
    "release_group_primary_type": "id bigint, name text",
    "release_group_secondary_type": "id bigint, name text",
    "release_group_secondary_type_join": "release_group bigint, secondary_type bigint",
    "release": "id bigint, gid uuid, name text, release_group bigint, status_id integer",
    "release_status": "id bigint, name text",
    "release_country": "release bigint, country bigint, date_year smallint, date_month smallint, date_day smallint",
    "release_unknown_country": "release bigint, date_year smallint, date_month smallint, date_day smallint",
    "medium": "id bigint, release bigint, position integer, format_id integer",
    "medium_format": "id bigint, name text",
    "track": "gid uuid, recording bigint, medium bigint, position integer, name text, length integer",
    "recording": "id bigint, gid uuid, name text, artist_credit bigint, length integer, comment text",
    "isrc": "recording bigint, isrc text",
    "work": "id bigint, gid uuid, name text",
    "l_recording_work": "link bigint, entity0 bigint, entity1 bigint",
    "link_attribute": "link bigint, attribute_type bigint",
    "link_attribute_type": "id bigint, name text",
    "genre": "id bigint, gid uuid, name text",
    "l_genre_genre": "link bigint, entity0 bigint, entity1 bigint",
    "l_artist_artist": "link bigint, entity0 bigint, entity1 bigint",
    "url": "id bigint, url text",
    "l_artist_url": "link bigint, entity0 bigint, entity1 bigint",
    "link": "id bigint, link_type bigint",
    "link_type": "id bigint, gid uuid, name text",
    "tag": "id bigint, name text",
    "artist_tag": "artist bigint, tag bigint, count integer",
    "release_group_tag": "release_group bigint, tag bigint, count integer",
    "recording_tag": "recording bigint, tag bigint, count integer",
}

LIVE: tuple[str, ...] = (
    "mb_artist",
    "mb_artist_alias",
    "mb_area",
    "mb_area_part",
    "mb_artist_credit",
    "mb_artist_credit_name",
    "mb_release_group",
    "mb_release",
    "mb_medium",
    "mb_track",
    "mb_recording",
    "mb_isrc",
    "mb_work",
    "mb_recording_work",
    "mb_genre",
    "mb_genre_edge",
    "mb_artist_artist",
    "mb_artist_url",
    "mb_tag",
    "mb_artist_tag",
    "mb_release_group_tag",
    "mb_recording_tag",
)

PUBLISHED = (*LIVE, "our_genre_map", "artist_genre", "artist_country", "song", "song_version")

# Test hook: called inside the swap transaction after dropping the first table.
_swap_hook: Callable[[], Any] | None = None


class SchemaMismatch(Exception):
    """Dump has a different schema than loader. Leave copy untouched."""


class TablespaceRequired(Exception):
    """Copy does not go on the main volume: no room on the root volume."""


LoaderBusy = RuntimeError
InsufficientSpace = OSError
IdentityConflict = ValueError


def copy_cell(value: Any) -> str:
    if value is None:
        return r"\N"
    if isinstance(value, bool):
        return "t" if value else "f"
    text = str(value)
    return (
        text.replace("\\", "\\\\")
        .replace("\t", r"\t")
        .replace("\n", r"\n")
        .replace("\r", r"\r")
    )


def format_copy_row(table: str, values: Mapping[str, Any]) -> str:
    """COPY row from dump: all MB table columns, extra are \\N."""
    return "\t".join(copy_cell(values.get(col)) for col in DUMP_COLUMNS[table]) + "\n"


def unescape(cell: str) -> str | None:
    if cell == r"\N":
        return None
    out: list[str] = []
    chars = iter(cell)
    for ch in chars:
        if ch != "\\":
            out.append(ch)
            continue
        nxt = next(chars, "")
        out.append({"t": "\t", "n": "\n", "r": "\r", "b": "\b", "f": "\f", "v": "\v", "\\": "\\"}.get(nxt, nxt))
    return "".join(out)


def parse_copy_line(line: str, columns: tuple[str, ...]) -> dict[str, str | None]:
    cells = line.rstrip("\n").split("\t")
    if len(cells) < len(columns):
        cells.extend([r"\N"] * (len(columns) - len(cells)))
    return {col: unescape(cells[i]) for i, col in enumerate(columns)}


def _typed(kind: str, raw: str | None) -> Any:
    if raw is None:
        return None
    if kind == "i":
        return int(raw)
    if kind == "b":
        return raw in {"t", "true", "1"}
    if kind == "u":
        return UUID(raw)
    return raw


def should_load(dump_date: date, last: date | None) -> bool:
    """Saturday dump, and this date has not been loaded yet."""
    if dump_date.weekday() != 5:
        return False
    return last != dump_date


def next_attempt_ok(now_mono: float, last_fail_mono: float | None) -> bool:
    """After a failure, the next attempt is not earlier than a day later."""
    if last_fail_mono is None:
        return True
    return now_mono - last_fail_mono >= RETRY_AFTER_FAIL_S


def dump_date_from_latest(latest: str) -> date:
    stamp = latest.strip().split("-", 1)[0]
    return date(int(stamp[:4]), int(stamp[4:6]), int(stamp[6:8]))


def _scrub_db_url(text: str, database_url: str) -> str:
    """Neither database address nor password must end up in the log."""
    if database_url:
        text = text.replace(database_url, "<db>")
    return re.sub(r"postgresql://\S+", "<db>", text)


def _failure_tail(stderr: str, stdout: str, *, limit: int = 400) -> str:
    """Last non-empty output lines of the loader, joined by ` | `.

    We take stderr, or stdout if stderr is empty. No longer than `limit` chars:
    the log gets the cause, not a massive dump.
    """
    source = stderr if stderr.strip() else stdout
    # Traceback pointer lines (`^^^^`) are not worth the space.
    lines = [line.strip() for line in source.splitlines() if line.strip().strip("^~ ")]
    picked: list[str] = []
    total = 0
    for line in reversed(lines):
        addition = len(line) + (len(" | ") if picked else 0)
        if picked and total + addition > limit:
            break
        picked.append(line)
        total += addition
    return " | ".join(reversed(picked))[:limit]


def _drain(fh: Any) -> None:
    while fh.read(1 << 20):
        pass


def _iter_copy(fh: Any) -> Iterator[str]:
    buf = b""
    while True:
        chunk = fh.read(1 << 16)
        if not chunk:
            break
        buf += chunk
        while True:
            idx = buf.find(b"\n")
            if idx < 0:
                break
            line, buf = buf[:idx], buf[idx + 1 :]
            if line:
                yield line.decode("utf-8")
    if buf.strip():
        yield buf.decode("utf-8")


class _HttpReader:
    def __init__(self, response: httpx.Response) -> None:
        self._it = response.iter_bytes(65536)
        self._buf = b""
        self._done = False

    def read(self, size: int = -1) -> bytes:
        if size == 0:
            return b""
        if size < 0:
            parts = [self._buf]
            self._buf = b""
            for chunk in self._it:
                parts.append(chunk)
            self._done = True
            return b"".join(parts)
        while len(self._buf) < size and not self._done:
            try:
                self._buf += next(self._it)
            except StopIteration:
                self._done = True
                break
        out, self._buf = self._buf[:size], self._buf[size:]
        return out

    def readable(self) -> bool:
        return True


def _open_tar(fileobj: Any) -> tarfile.TarFile:
    return tarfile.open(fileobj=fileobj, mode="r|bz2")


async def ensure_tablespace(conn: asyncpg.Connection) -> bool:
    if await conn.fetchval("SELECT 1 FROM pg_tablespace WHERE spcname = 'mb'"):
        return True
    try:
        # No parameters: simple query, not in a transaction.
        await conn.execute(f"CREATE TABLESPACE mb LOCATION '{TABLESPACE_DIR}'")
        return True
    except asyncpg.PostgresError as exc:
        logger.warning(
            "mbcopy: tablespace mb was not created: %s %s",
            type(exc).__name__,
            str(exc),
        )
        return False


async def _drop_new_and_stg(conn: asyncpg.Connection) -> None:
    for live in LIVE:
        await conn.execute(f"DROP TABLE IF EXISTS {live}_new")
    for name in STG_SQL:
        await conn.execute(f"DROP TABLE IF EXISTS mb_stg_{name}")


def _ts(has_mb: bool) -> str:
    return " TABLESPACE mb" if has_mb else ""


async def _create_staging(conn: asyncpg.Connection, has_mb: bool) -> None:
    extra = _ts(has_mb)
    for name, cols in STG_SQL.items():
        await conn.execute(f"CREATE UNLOGGED TABLE mb_stg_{name} ({cols}){extra}")


async def _create_new(conn: asyncpg.Connection, has_mb: bool, hot_on_main: bool = True) -> None:
    def ts(name: str) -> str:
        return search_indexes.relation_tablespace(name, has_mb=has_mb, hot_on_main=hot_on_main)

    statements = [
        f"""CREATE TABLE mb_artist_new (
            mbid uuid PRIMARY KEY, name text NOT NULL, sort_name text NOT NULL,
            type text, area_mbid uuid, begin_area_mbid uuid, begin_year smallint,
            ended boolean NOT NULL DEFAULT false){ts("mb_artist_new")}""",
        f"""CREATE TABLE mb_artist_alias_new (
            artist_mbid uuid NOT NULL, name text NOT NULL, locale text,
            primary_for_locale boolean NOT NULL DEFAULT false){ts("mb_artist_alias_new")}""",
        f"""CREATE TABLE mb_area_new (
            mbid uuid PRIMARY KEY, name text NOT NULL, type text, iso3166 text){ts("mb_area_new")}""",
        f"""CREATE TABLE mb_area_part_new (
            child_mbid uuid NOT NULL, parent_mbid uuid NOT NULL,
            PRIMARY KEY (child_mbid, parent_mbid)){ts("mb_area_part_new")}""",
        f"""CREATE TABLE mb_artist_credit_new (
            mbid uuid PRIMARY KEY, name text NOT NULL){ts("mb_artist_credit_new")}""",
        f"""CREATE TABLE mb_artist_credit_name_new (
            credit_mbid uuid NOT NULL, position smallint NOT NULL,
            artist_mbid uuid NOT NULL, name text NOT NULL,
            PRIMARY KEY (credit_mbid, position)){ts("mb_artist_credit_name_new")}""",
        f"""CREATE TABLE mb_release_group_new (
            mbid uuid PRIMARY KEY, artist_mbid uuid, title text NOT NULL,
            primary_type text, secondary_types text[] NOT NULL DEFAULT '{{}}',
            first_date text){ts("mb_release_group_new")}""",
        f"""CREATE TABLE mb_release_new (
            mbid uuid PRIMARY KEY, group_mbid uuid NOT NULL, title text NOT NULL,
            status text, country text, date text){ts("mb_release_new")}""",
        f"""CREATE TABLE mb_medium_new (
            id bigint PRIMARY KEY, release_mbid uuid NOT NULL,
            position integer NOT NULL, format text){ts("mb_medium_new")}""",
        f"""CREATE TABLE mb_track_new (
            mbid uuid PRIMARY KEY, medium_id bigint NOT NULL,
            recording_mbid uuid NOT NULL, position integer NOT NULL,
            title text NOT NULL, length_ms integer){ts("mb_track_new")}""",
        f"""CREATE TABLE mb_recording_new (
            mbid uuid PRIMARY KEY, artist_mbid uuid, title text NOT NULL,
            length_ms integer, comment text NOT NULL DEFAULT ''){ts("mb_recording_new")}""",
        f"""CREATE TABLE mb_isrc_new (
            recording_mbid uuid NOT NULL, isrc text NOT NULL,
            PRIMARY KEY (recording_mbid, isrc)){ts("mb_isrc_new")}""",
        f"""CREATE TABLE mb_work_new (
            mbid uuid PRIMARY KEY, title text NOT NULL){ts("mb_work_new")}""",
        f"""CREATE TABLE mb_recording_work_new (
            recording_mbid uuid NOT NULL, work_mbid uuid NOT NULL,
            attributes text[] NOT NULL DEFAULT '{{}}',
            PRIMARY KEY (recording_mbid, work_mbid)){ts("mb_recording_work_new")}""",
        f"""CREATE TABLE mb_genre_new (
            mbid uuid PRIMARY KEY, name text NOT NULL){ts("mb_genre_new")}""",
        f"""CREATE TABLE mb_genre_edge_new (
            child_mbid uuid NOT NULL, parent_mbid uuid NOT NULL, kind text NOT NULL,
            PRIMARY KEY (child_mbid, parent_mbid, kind)){ts("mb_genre_edge_new")}""",
        f"""CREATE TABLE mb_artist_artist_new (
            member_mbid uuid NOT NULL, group_mbid uuid NOT NULL,
            PRIMARY KEY (member_mbid, group_mbid)){ts("mb_artist_artist_new")}""",
        f"""CREATE TABLE mb_artist_url_new (
            artist_mbid uuid NOT NULL, kind text NOT NULL, url text NOT NULL,
            PRIMARY KEY (artist_mbid, kind, url)){ts("mb_artist_url_new")}""",
        f"""CREATE TABLE mb_tag_new (
            id bigint PRIMARY KEY, name text NOT NULL){ts("mb_tag_new")}""",
        f"""CREATE TABLE mb_artist_tag_new (
            artist_mbid uuid NOT NULL, tag_id bigint NOT NULL, count integer NOT NULL,
            PRIMARY KEY (artist_mbid, tag_id)){ts("mb_artist_tag_new")}""",
        f"""CREATE TABLE mb_release_group_tag_new (
            group_mbid uuid NOT NULL, tag_id bigint NOT NULL, count integer NOT NULL,
            PRIMARY KEY (group_mbid, tag_id)){ts("mb_release_group_tag_new")}""",
        f"""CREATE TABLE mb_recording_tag_new (
            recording_mbid uuid NOT NULL, tag_id bigint NOT NULL, count integer NOT NULL,
            PRIMARY KEY (recording_mbid, tag_id)){ts("mb_recording_tag_new")}""",
    ]
    for sql in statements:
        await conn.execute(sql)


async def _index_new(conn: asyncpg.Connection, has_mb: bool, hot_on_main: bool = True) -> None:
    def ts(name: str) -> str:
        return search_indexes.relation_tablespace(name, has_mb=has_mb, hot_on_main=hot_on_main)

    await conn.execute(f"SET maintenance_work_mem = '{MAINTENANCE_WORK_MEM}'")
    statements = [
        f"CREATE INDEX mb_artist_new_name_trgm ON mb_artist_new USING gin (name gin_trgm_ops){ts('mb_artist_new_name_trgm')}",
        f"CREATE INDEX mb_artist_new_area ON mb_artist_new (area_mbid){ts('mb_artist_new_area')}",
        f"CREATE INDEX mb_artist_new_begin_area ON mb_artist_new (begin_area_mbid){ts('mb_artist_new_begin_area')}",
        f"CREATE INDEX mb_artist_alias_new_artist ON mb_artist_alias_new (artist_mbid){ts('mb_artist_alias_new_artist')}",
        f"CREATE INDEX mb_artist_alias_new_name_trgm ON mb_artist_alias_new USING gin (name gin_trgm_ops){ts('mb_artist_alias_new_name_trgm')}",
        f"CREATE INDEX mb_area_new_iso ON mb_area_new (iso3166){ts('mb_area_new_iso')}",
        f"CREATE INDEX mb_artist_credit_name_new_artist ON mb_artist_credit_name_new (artist_mbid){ts('mb_artist_credit_name_new_artist')}",
        f"CREATE INDEX mb_release_group_new_artist ON mb_release_group_new (artist_mbid, first_date){ts('mb_release_group_new_artist')}",
        f"CREATE INDEX mb_release_group_new_title_trgm ON mb_release_group_new USING gin (title gin_trgm_ops){ts('mb_release_group_new_title_trgm')}",
        f"CREATE INDEX mb_release_new_group_mbid ON mb_release_new (group_mbid){ts('mb_release_new_group_mbid')}",
        f"CREATE INDEX mb_medium_new_release ON mb_medium_new (release_mbid){ts('mb_medium_new_release')}",
        f"CREATE INDEX mb_track_new_recording ON mb_track_new (recording_mbid) INCLUDE (medium_id){ts('mb_track_new_recording')}",
        f"CREATE INDEX mb_track_new_medium ON mb_track_new (medium_id){ts('mb_track_new_medium')}",
        f"CREATE INDEX mb_recording_new_artist ON mb_recording_new (artist_mbid){ts('mb_recording_new_artist')}",
        f"CREATE INDEX mb_recording_new_title_trgm ON mb_recording_new USING gin (title gin_trgm_ops){ts('mb_recording_new_title_trgm')}",
        *(f"CREATE INDEX {name} ON {table}_new ({expr}){ts(name)}" for name, table, expr in search_indexes.MB_INDEXES),
    ]
    for sql in statements:
        await conn.execute(sql)


async def _copy_table(conn: asyncpg.Connection, table: str, fh: Any) -> int:
    spec = STAGING[table]
    columns = [item[0] for item in spec]
    dump_cols = DUMP_COLUMNS[table]
    batch: list[tuple[Any, ...]] = []
    total = 0

    async def flush() -> None:
        nonlocal batch, total
        if not batch:
            return
        await conn.copy_records_to_table(f"mb_stg_{table}", records=batch, columns=columns)
        total += len(batch)
        batch = []

    for line in _iter_copy(fh):
        parsed = parse_copy_line(line, dump_cols)
        batch.append(tuple(_typed(kind, parsed.get(src)) for _, kind, src in spec))
        if len(batch) >= BATCH:
            await flush()
    await flush()
    return total


DATE_SQL = """CASE
    WHEN date_year IS NULL THEN NULL
    WHEN date_month IS NULL THEN date_year::text
    WHEN date_day IS NULL THEN date_year::text || '-' || lpad(date_month::text, 2, '0')
    ELSE date_year::text || '-' || lpad(date_month::text, 2, '0')
         || '-' || lpad(date_day::text, 2, '0')
END"""


async def _fill_new(conn: asyncpg.Connection) -> dict[str, int]:
    await conn.execute(
        """
        INSERT INTO mb_artist_new (mbid, name, sort_name, type, area_mbid, begin_area_mbid, begin_year, ended)
        SELECT a.gid, a.name, a.sort_name, t.name, ar.gid, br.gid, a.begin_year, COALESCE(a.ended, false)
        FROM mb_stg_artist a
        LEFT JOIN mb_stg_artist_type t ON t.id = a.type_id
        LEFT JOIN mb_stg_area ar ON ar.id = a.area_id
        LEFT JOIN mb_stg_area br ON br.id = a.begin_area_id
        """
    )
    await conn.execute(
        """
        INSERT INTO mb_artist_alias_new (artist_mbid, name, locale, primary_for_locale)
        SELECT a.gid, al.name, al.locale, COALESCE(al.primary_for_locale, false)
        FROM mb_stg_artist_alias al
        JOIN mb_stg_artist a ON a.id = al.artist
        """
    )
    await conn.execute(
        """
        INSERT INTO mb_area_new (mbid, name, type, iso3166)
        SELECT ar.gid, ar.name, t.name, iso.code
        FROM mb_stg_area ar
        LEFT JOIN mb_stg_area_type t ON t.id = ar.type_id
        LEFT JOIN mb_stg_iso_3166_1 iso ON iso.area = ar.id
        """
    )
    await conn.execute(
        """
        INSERT INTO mb_area_part_new (child_mbid, parent_mbid)
        SELECT DISTINCT c.gid, p.gid
        FROM mb_stg_l_area_area rel
        JOIN mb_stg_link l ON l.id = rel.link
        JOIN mb_stg_link_type t ON t.id = l.link_type
        JOIN mb_stg_area c ON c.id = rel.entity0
        JOIN mb_stg_area p ON p.id = rel.entity1
        WHERE t.gid = $1
        """,
        PART_OF_GID,
    )
    await conn.execute(
        """
        INSERT INTO mb_artist_credit_new (mbid, name)
        SELECT gid, name FROM mb_stg_artist_credit WHERE gid IS NOT NULL
        """
    )
    await conn.execute(
        """
        INSERT INTO mb_artist_credit_name_new (credit_mbid, position, artist_mbid, name)
        SELECT c.gid, n.position, a.gid, n.name
        FROM mb_stg_artist_credit_name n
        JOIN mb_stg_artist_credit c ON c.id = n.artist_credit
        JOIN mb_stg_artist a ON a.id = n.artist
        """
    )
    await conn.execute(
        """
        INSERT INTO mb_release_group_new (mbid, artist_mbid, title, primary_type, secondary_types, first_date)
        SELECT rg.gid, a.gid, rg.name, pt.name, COALESCE(sec.types, '{}'), dates.first_date
        FROM mb_stg_release_group rg
        LEFT JOIN mb_stg_release_group_primary_type pt ON pt.id = rg.type_id
        LEFT JOIN mb_stg_artist_credit_name acn
            ON acn.artist_credit = rg.artist_credit AND acn.position = 0
        LEFT JOIN mb_stg_artist a ON a.id = acn.artist
        LEFT JOIN (
            SELECT j.release_group, array_agg(st.name ORDER BY st.name) AS types
            FROM mb_stg_release_group_secondary_type_join j
            JOIN mb_stg_release_group_secondary_type st ON st.id = j.secondary_type
            GROUP BY j.release_group
        ) sec ON sec.release_group = rg.id
        LEFT JOIN (
            SELECT r.release_group, min(""" + DATE_SQL.replace("date_year", "c.date_year").replace("date_month", "c.date_month").replace("date_day", "c.date_day") + """) AS first_date
            FROM mb_stg_release r
            LEFT JOIN mb_stg_release_country c ON c.release = r.id
            GROUP BY r.release_group
        ) dates ON dates.release_group = rg.id
        """
    )
    await conn.execute(
        f"""
        INSERT INTO mb_release_new (mbid, group_mbid, title, status, country, date)
        SELECT r.gid, g.gid, r.name, st.name, iso.code,
               {DATE_SQL.replace("date_year", "COALESCE(c.date_year, u.date_year)").replace("date_month", "COALESCE(c.date_month, u.date_month)").replace("date_day", "COALESCE(c.date_day, u.date_day)")}
        FROM mb_stg_release r
        JOIN mb_stg_release_group g ON g.id = r.release_group
        LEFT JOIN mb_stg_release_status st ON st.id = r.status_id
        LEFT JOIN (
            SELECT DISTINCT ON (release) release, country, date_year, date_month, date_day
            FROM mb_stg_release_country
            ORDER BY release, date_year NULLS LAST, date_month NULLS LAST, date_day NULLS LAST, country
        ) c ON c.release = r.id
        LEFT JOIN mb_stg_iso_3166_1 iso ON iso.area = c.country
        LEFT JOIN mb_stg_release_unknown_country u ON u.release = r.id
        """
    )
    await conn.execute(
        """
        INSERT INTO mb_medium_new (id, release_mbid, position, format)
        SELECT m.id, r.gid, m.position, f.name
        FROM mb_stg_medium m
        JOIN mb_stg_release r ON r.id = m.release
        LEFT JOIN mb_stg_medium_format f ON f.id = m.format_id
        """
    )
    await conn.execute(
        """
        INSERT INTO mb_track_new (mbid, medium_id, recording_mbid, position, title, length_ms)
        SELECT t.gid, t.medium, rec.gid, t.position, t.name, t.length
        FROM mb_stg_track t
        JOIN mb_stg_recording rec ON rec.id = t.recording
        """
    )
    await conn.execute(
        """
        INSERT INTO mb_recording_new (mbid, artist_mbid, title, length_ms, comment)
        SELECT rec.gid, a.gid, rec.name, rec.length, COALESCE(rec.comment, '')
        FROM mb_stg_recording rec
        LEFT JOIN mb_stg_artist_credit_name acn
            ON acn.artist_credit = rec.artist_credit AND acn.position = 0
        LEFT JOIN mb_stg_artist a ON a.id = acn.artist
        """
    )
    await conn.execute(
        """
        INSERT INTO mb_isrc_new (recording_mbid, isrc)
        SELECT rec.gid, i.isrc
        FROM mb_stg_isrc i
        JOIN mb_stg_recording rec ON rec.id = i.recording
        """
    )
    await conn.execute("INSERT INTO mb_work_new (mbid, title) SELECT gid, name FROM mb_stg_work")
    await conn.execute(
        """
        INSERT INTO mb_recording_work_new (recording_mbid, work_mbid, attributes)
        SELECT rec.gid, w.gid,
               COALESCE(array_agg(DISTINCT lower(lat.name))
                        FILTER (WHERE lat.name IS NOT NULL), '{}')
        FROM mb_stg_l_recording_work rel
        JOIN mb_stg_recording rec ON rec.id = rel.entity0
        JOIN mb_stg_work w ON w.id = rel.entity1
        LEFT JOIN mb_stg_link_attribute la ON la.link = rel.link
        LEFT JOIN mb_stg_link_attribute_type lat ON lat.id = la.attribute_type
        GROUP BY rec.gid, w.gid
        """
    )
    await conn.execute("INSERT INTO mb_genre_new (mbid, name) SELECT gid, name FROM mb_stg_genre")
    await conn.execute(
        """
        INSERT INTO mb_genre_edge_new (child_mbid, parent_mbid, kind)
        SELECT DISTINCT c.gid, p.gid, 'subgenre'
        FROM mb_stg_l_genre_genre rel
        JOIN mb_stg_link l ON l.id = rel.link
        JOIN mb_stg_link_type t ON t.id = l.link_type
        -- "entity0 has subgenre entity1": parent is entity0 (as in the
        -- dump itself, musicbrainz.org/relationship/9d61bc67-…).
        JOIN mb_stg_genre c ON c.id = rel.entity1
        JOIN mb_stg_genre p ON p.id = rel.entity0
        WHERE t.gid = $1
        """,
        SUBGENRE_GID,
    )
    await conn.execute(
        """
        INSERT INTO mb_artist_artist_new (member_mbid, group_mbid)
        SELECT DISTINCT m.gid, g.gid
        FROM mb_stg_l_artist_artist rel
        JOIN mb_stg_link l ON l.id = rel.link
        JOIN mb_stg_link_type t ON t.id = l.link_type
        JOIN mb_stg_artist m ON m.id = rel.entity0
        JOIN mb_stg_artist g ON g.id = rel.entity1
        WHERE t.gid = $1
        """,
        MEMBER_GID,
    )
    await conn.execute(
        """
        INSERT INTO mb_artist_url_new (artist_mbid, kind, url)
        SELECT DISTINCT a.gid,
               CASE t.gid
                   WHEN $1 THEN 'official'
                   WHEN $2 THEN 'youtube'
                   WHEN $3 THEN 'social'
               END,
               u.url
        FROM mb_stg_l_artist_url rel
        JOIN mb_stg_link l ON l.id = rel.link
        JOIN mb_stg_link_type t ON t.id = l.link_type
        JOIN mb_stg_artist a ON a.id = rel.entity0
        JOIN mb_stg_url u ON u.id = rel.entity1
        WHERE t.gid IN ($1, $2, $3)
        """,
        OFFICIAL_GID,
        YOUTUBE_GID,
        SOCIAL_GID,
    )
    await conn.execute("INSERT INTO mb_tag_new (id, name) SELECT id, name FROM mb_stg_tag")
    await conn.execute(
        """
        INSERT INTO mb_artist_tag_new (artist_mbid, tag_id, count)
        SELECT a.gid, t.tag, t.count
        FROM mb_stg_artist_tag t
        JOIN mb_stg_artist a ON a.id = t.artist
        """
    )
    await conn.execute(
        """
        INSERT INTO mb_release_group_tag_new (group_mbid, tag_id, count)
        SELECT g.gid, t.tag, t.count
        FROM mb_stg_release_group_tag t
        JOIN mb_stg_release_group g ON g.id = t.release_group
        """
    )
    await conn.execute(
        """
        INSERT INTO mb_recording_tag_new (recording_mbid, tag_id, count)
        SELECT r.gid, t.tag, t.count
        FROM mb_stg_recording_tag t
        JOIN mb_stg_recording r ON r.id = t.recording
        """
    )
    counts: dict[str, int] = {}
    for live in LIVE:
        counts[live] = int(await conn.fetchval(f"SELECT count(*) FROM {live}_new") or 0)
    return counts


async def _rename_loaded_tables(conn: asyncpg.Connection) -> None:
    for live in LIVE:
        await conn.execute(f"ALTER TABLE {live}_new RENAME TO {live}")


async def _build_songs_in_generation(conn: asyncpg.Connection) -> dict[str, Any]:
    from app import catalog_songs

    has_mb = await catalog_songs._has_mb(conn)
    hot_on_main = await hot_fits_main_volume(conn, has_mb=has_mb)
    await catalog_songs._create_load(conn, has_mb, hot_on_main)
    try:
        summary = await catalog_songs._fill(conn)
        await catalog_songs._swap(conn, has_mb, hot_on_main)
        for table in ("song_rec", "song_first", "song_studio"):
            await conn.execute(f"DROP TABLE IF EXISTS {table}")
        return summary
    except Exception:
        await catalog_songs._drop_load(conn)
        raise


async def _create_derived_placeholders(conn: asyncpg.Connection) -> None:
    for table in ("our_genre_map", "artist_genre", "artist_country", "song", "song_version"):
        await conn.execute(f"CREATE TABLE {table} AS TABLE public.{table} WITH NO DATA")


async def _assign_song_identities(conn: asyncpg.Connection, only_song_id: int | None = None) -> None:
    # FT-679: merged and split songs are settled there instead of failing the whole load.
    from app.song_numbers import assign

    await assign(conn, only_song_id)


async def _publish_generation(
    conn: asyncpg.Connection,
    *,
    generation_id: UUID,
    schema: str,
    dump_date: date,
    replication: int | None,
    counts: dict[str, int],
    duration_ms: int,
    tablespace: str,
    settle: Callable[[asyncpg.Connection], Awaitable[Any]] | None = None,
) -> int:
    async with conn.transaction():
        # FT-745: a generation shipped from the Mac brings its numbers along — `settle` adopts them.
        if settle is None:
            await _assign_song_identities(conn)
        else:
            await settle(conn)
        previous = await conn.fetchval(
            "SELECT schema_name FROM public.catalog_generation WHERE is_current"
        )
        archive = str(previous or f"catalog_legacy_{uuid4().hex}")
        if previous is None:
            await conn.execute(f'CREATE SCHEMA "{archive}"')
        for index, table in enumerate(PUBLISHED):
            await conn.execute(f'ALTER TABLE public."{table}" SET SCHEMA "{archive}"')
            if index == 0 and _swap_hook is not None:
                maybe = _swap_hook()
                if asyncio.iscoroutine(maybe):
                    await maybe
        for table in PUBLISHED:
            await conn.execute(
                f'ALTER TABLE "{schema}"."{table}" SET SCHEMA public'
            )
        await conn.execute(
            "UPDATE public.catalog_generation SET is_current = false WHERE is_current"
        )
        size_bytes = await _copy_size(conn)
        await conn.execute(
            "INSERT INTO public.catalog_generation (generation_id, schema_name, is_current) VALUES ($1, $2, true)",
            generation_id, schema,
        )
        await conn.execute("""INSERT INTO public.mb_loads
            (dump_date, replication_sequence, row_counts, duration_ms, tablespace, size_bytes)
            VALUES ($1, $2, $3::jsonb, $4, $5, $6)""",
            dump_date, replication, json.dumps(counts), duration_ms, tablespace, size_bytes)
    return size_bytes


async def _read_archive(
    conn: asyncpg.Connection,
    fileobj: Any,
    meta: dict[str, str],
) -> None:
    tar = _open_tar(fileobj)
    try:
        seen_schema = False
        for member in tar:
            name = member.name.lstrip("./")
            fh = tar.extractfile(member)
            if fh is None:
                continue
            if name == "SCHEMA_SEQUENCE":
                seq = fh.read().decode("utf-8").strip()
                if seq != str(SCHEMA_SEQUENCE):
                    raise SchemaMismatch(
                        f"схема дампа {seq}, загрузчик ждёт {SCHEMA_SEQUENCE}"
                    )
                seen_schema = True
                continue
            if name == "REPLICATION_SEQUENCE":
                meta["replication"] = fh.read().decode("utf-8").strip()
                continue
            if name == "TIMESTAMP":
                meta["timestamp"] = fh.read().decode("utf-8").strip()
                continue
            if name.startswith("mbdump/"):
                table = name.split("/", 1)[1]
                if table not in STAGING:
                    _drain(fh)
                    continue
                if not seen_schema:
                    raise SchemaMismatch("archive has no SCHEMA_SEQUENCE before tables")
                await _copy_table(conn, table, fh)
                continue
            _drain(fh)
    finally:
        tar.close()


def _parse_timestamp(raw: str) -> date | None:
    raw = raw.strip()
    if not raw:
        return None
    try:
        return datetime.fromisoformat(raw.replace(" UTC", "+00:00")).date()
    except ValueError:
        try:
            return date.fromisoformat(raw[:10])
        except ValueError:
            return None


def _http_timeout() -> httpx.Timeout:
    return httpx.Timeout(connect=30.0, read=READ_TIMEOUT_S, write=30.0, pool=30.0)


async def _copy_size(conn: asyncpg.Connection) -> int:
    size = await conn.fetchval(
        "SELECT COALESCE(sum(pg_total_relation_size(format('%I.%I', schemaname, tablename))), 0) "
        "FROM pg_tables WHERE schemaname = 'public' AND tablename = ANY($1)",
        list(PUBLISHED),
    )
    return int(size or 0)


def _archive_size(
    files: list[str] | None,
    *,
    client: httpx.Client | None,
    latest: str,
) -> int:
    if files:
        return sum(os.path.getsize(path) for path in files)
    if client is None:
        raise InsufficientSpace("archive sizes are unavailable")
    total = 0
    for archive in ARCHIVES:
        response = client.head(f"{DUMP_ROOT}/{latest}/{archive}")
        response.raise_for_status()
        length = response.headers.get("content-length")
        if length is None or not length.isdigit():
            raise InsufficientSpace("archive size is unavailable before COPY")
        total += int(length)
    return total


def _free_bytes(path: str) -> int:
    """Free space of the filesystem holding `path` — the one measurement seam."""
    return shutil.disk_usage(path).free


async def _check_free_space(
    conn: asyncpg.Connection, *, has_mb: bool, archive_bytes: int
) -> None:
    table_path = await conn.fetchval(
        "SELECT NULLIF(pg_tablespace_location(oid), '') "
        "FROM pg_tablespace WHERE spcname = 'mb'"
    ) if has_mb else None
    data_path = await conn.fetchval("SHOW data_directory")
    table_path = str(table_path) if table_path else ""
    data_path = str(data_path) if data_path else ""
    old_bytes = await _copy_size(conn)
    # Tables and indexes land in tablespace mb; the data directory only takes
    # WAL (and sort spill, see temp_tablespaces in load()). Without mb both
    # land on the same filesystem and it needs the sum.
    tables_required = max(old_bytes * 2, archive_bytes * SPACE_MULTIPLIER)
    wal_required = 2 * int(
        await conn.fetchval("SELECT pg_size_bytes(current_setting('max_wal_size'))") or 0
    )
    if table_path and data_path and table_path != data_path:
        checks = [
            (table_path, tables_required, "catalog tables and indexes"),
            (data_path, wal_required, "WAL"),
        ]
    elif table_path or data_path:
        checks = [
            (
                table_path or data_path,
                tables_required + wal_required,
                "catalog tables, indexes, and WAL",
            ),
        ]
    else:
        raise InsufficientSpace("cannot inspect the catalog filesystem")
    for path, required, what in checks:
        try:
            free_bytes = await asyncio.to_thread(_free_bytes, path)
        except OSError as exc:
            raise InsufficientSpace(
                "cannot inspect free space: Postgres volumes are not mounted "
                "into the loader container"
            ) from exc
        if free_bytes < required:
            raise InsufficientSpace(f"insufficient free space for {what}")


async def hot_fits_main_volume(conn: asyncpg.Connection, *, has_mb: bool) -> bool:
    """Is there room for the hot search tables (search_indexes.HOT_RELATIONS)
    on the main volume right now.

    Needs the WAL reserve `_check_free_space` already requires, plus today's
    hot size, plus a 10 GiB margin. Not 2x the hot size: the hot tables
    already live on the main volume, so their current size is already
    counted as used space there. The load builds one new copy alongside the
    old one until the swap — one extra copy, not two — so the reserve only
    has to cover that single new copy. Never raises — short on space just
    means hot goes to tablespace mb, as before; the load itself must not
    fail over this.
    """
    if not has_mb:
        return True
    data_path = str(await conn.fetchval("SHOW data_directory") or "")
    wal_required = 2 * int(
        await conn.fetchval("SELECT pg_size_bytes(current_setting('max_wal_size'))") or 0
    )
    live_names = [search_indexes.live_name(name) for name in search_indexes.HOT_RELATIONS]
    hot_bytes = int(
        await conn.fetchval(
            "SELECT COALESCE(sum(pg_relation_size(c.oid)), 0) "
            "FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
            "WHERE n.nspname = 'public' AND c.relname = ANY($1)",
            live_names,
        )
        or 0
    )
    required = wal_required + hot_bytes + MAIN_VOLUME_RESERVE_BYTES
    try:
        free_bytes = await asyncio.to_thread(_free_bytes, data_path) if data_path else 0
    except OSError:
        free_bytes = 0
    if free_bytes >= required:
        return True
    logger.warning(
        "mbcopy: hot search tables on mb, main volume short: need %d free %d",
        required,
        free_bytes,
    )
    return False


async def load(
    database_url: str,
    *,
    files: list[str] | None = None,
    url: str | None = None,
    proxy: str | None = None,
    http: httpx.Client | None = None,
    allow_main_volume: bool = False,
) -> dict[str, Any]:
    began = time.monotonic()
    # A redeploy kills this process mid-statement. Without the check the
    # backend runs the statement to its end and keeps the advisory lock, so
    # the next loader fails as busy and the robot waits a day.
    conn = await asyncpg.connect(
        database_url, server_settings={"client_connection_check_interval": "10s"}
    )
    meta: dict[str, str] = {}
    locked = False
    published = False
    schema: str | None = None
    client = http
    own_client = False
    try:
        locked = bool(
            await conn.fetchval("SELECT pg_try_advisory_lock($1)", LOADER_LOCK_ID)
        )
        if not locked:
            raise LoaderBusy("another catalog loader is active")
        # Only load() creates catalog_gen_ schemas and it holds the advisory lock,
        # so an unlisted one belongs to no live load.
        abandoned = [
            row["nspname"]
            for row in await conn.fetch(
                """
                SELECT nspname FROM pg_namespace
                WHERE starts_with(nspname, 'catalog_gen_')
                  AND nspname NOT IN (SELECT schema_name FROM public.catalog_generation)
                """
            )
        ]
        for name in abandoned:
            await conn.execute(f'DROP SCHEMA "{name}" CASCADE')
        if abandoned:
            logger.info("mbcopy: dropped %d abandoned schemas", len(abandoned))
        has_mb = await ensure_tablespace(conn)
        if not has_mb and not allow_main_volume:
            raise TablespaceRequired(
                "need tablespace mb on HDD, will not use main volume"
            )
        latest = (url or "LATEST").strip() or "LATEST"
        if not files:
            if client is None:
                client = httpx.Client(
                    proxy=proxy or None,
                    timeout=_http_timeout(),
                    headers={"User-Agent": "apertonodo/0.1 ( mbcopy )"},
                )
                own_client = True
            if latest == "LATEST":
                latest = client.get(f"{DUMP_ROOT}/LATEST").text.strip()
        archive_bytes = await asyncio.to_thread(
            _archive_size, files, client=client, latest=latest
        )
        await _check_free_space(conn, has_mb=has_mb, archive_bytes=archive_bytes)
        hot_on_main = await hot_fits_main_volume(conn, has_mb=has_mb)
        generation_id = uuid4()
        schema = f"catalog_gen_{generation_id.hex}"
        await conn.execute(f'CREATE SCHEMA "{schema}"')
        await conn.execute(f'SET search_path TO "{schema}", public')
        await conn.execute(f"SET maintenance_work_mem = '{MAINTENANCE_WORK_MEM}'")
        if has_mb:
            # Index sorts spill to temp files and default to the root disk;
            # send them to tablespace mb as well.
            await conn.execute("SET temp_tablespaces = mb")
        await _create_staging(conn, has_mb)
        await _create_new(conn, has_mb, hot_on_main)
        if files:
            for path in files:
                # This CLI-only path may block while the one-off loader reads a local archive.
                with open(path, "rb") as fh:  # noqa: ASYNC230
                    await _read_archive(conn, fh, meta)
        else:
            assert client is not None
            for archive in ARCHIVES:
                address = f"{DUMP_ROOT}/{latest}/{archive}"
                with client.stream("GET", address) as response:
                    response.raise_for_status()
                    await _read_archive(conn, _HttpReader(response), meta)  # type: ignore[arg-type]
            meta.setdefault("latest", latest)
        counts = await _fill_new(conn)
        await _index_new(conn, has_mb, hot_on_main)
        await _rename_loaded_tables(conn)
        for name in STG_SQL:
            await conn.execute(f"DROP TABLE mb_stg_{name}")
        await _create_derived_placeholders(conn)
        from app.catalog_genres import build_in_connection as build_genres_in_connection

        await build_genres_in_connection(conn)
        await _build_songs_in_generation(conn)
        dump_date = _parse_timestamp(meta.get("timestamp", "")) or date.today()
        replication = None
        if meta.get("replication", "").strip().isdigit():
            replication = int(meta["replication"].strip())
        duration_ms = int((time.monotonic() - began) * 1000)
        space = "mb" if has_mb else "pg_default"
        size_bytes = await _publish_generation(
            conn,
            generation_id=generation_id,
            schema=schema,
            dump_date=dump_date,
            replication=replication,
            counts=counts,
            duration_ms=duration_ms,
            tablespace=space,
        )
        published = True
        logger.info(
            "mbcopy: dump %s, replication %s, %d tables, %s, %d bytes, %d ms",
            dump_date.isoformat(),
            replication,
            len(counts),
            space,
            size_bytes,
            duration_ms,
        )
        return {
            "dump_date": dump_date.isoformat(),
            "replication_sequence": replication,
            "row_counts": counts,
            "duration_ms": duration_ms,
            "tablespace": space,
            "size_bytes": size_bytes,
        }
    finally:
        if schema and not published:
            try:
                await conn.execute("RESET search_path")
                await conn.execute(f'DROP SCHEMA IF EXISTS "{schema}" CASCADE')
            except Exception as exc:  # noqa: BLE001
                logger.warning("mbcopy: failed generation cleanup: %s", type(exc).__name__)
        if own_client and client is not None:
            client.close()
        if locked:
            try:
                await conn.execute("SELECT pg_advisory_unlock($1)", LOADER_LOCK_ID)
            except asyncpg.PostgresError:
                pass
        await conn.close()


class MbCopy:
    def __init__(
        self,
        database_url: str,
        *,
        proxy: str | None = None,
        http: httpx.Client | None = None,
    ) -> None:
        self.database_url = database_url
        self.proxy = proxy
        self.http = http
        self.last_check = float("-inf")
        self.last_fail: float | None = None
        self.thread: threading.Thread | None = None

    def soon(self) -> None:
        if self.thread is not None and self.thread.is_alive():
            return
        if time.monotonic() - self.last_check < CHECK_INTERVAL_S:
            return
        self.last_check = time.monotonic()
        self.thread = threading.Thread(target=self._run_safely, name="mbcopy", daemon=True)
        self.thread.start()

    def _run_safely(self) -> None:
        if not next_attempt_ok(time.monotonic(), self.last_fail):
            return
        try:
            latest = self._read_latest()
            dump_date = dump_date_from_latest(latest)
            last = asyncio.run(self._last_date())
            if not should_load(dump_date, last):
                if dump_date.weekday() != 5:
                    logger.info(
                        "mbcopy: dump %s is not a saturday one, skipped",
                        dump_date.isoformat(),
                    )
                else:
                    logger.info(
                        "mbcopy: dump %s already loaded", dump_date.isoformat()
                    )
                return
            logger.info("mbcopy: dump %s, load started", dump_date.isoformat())
            code, tail = self._spawn_load(latest)
            if code != 0:
                self.last_fail = time.monotonic()
                logger.warning("mbcopy: crawl failed: exit %s: %s", code, tail)
                return
            logger.info("mbcopy: load finished")
        except Exception as exc:  # noqa: BLE001
            self.last_fail = time.monotonic()
            logger.warning("mbcopy: crawl failed: %s", type(exc).__name__)

    def _read_latest(self) -> str:
        client = self.http or httpx.Client(
            proxy=self.proxy or None,
            timeout=_http_timeout(),
            headers={"User-Agent": "apertonodo/0.1 ( mbcopy )"},
        )
        own = self.http is None
        try:
            return client.get(f"{DUMP_ROOT}/LATEST").text.strip()
        finally:
            if own:
                client.close()

    async def _last_date(self) -> date | None:
        conn = await asyncpg.connect(self.database_url)
        try:
            last = await conn.fetchval(
                "SELECT dump_date FROM mb_loads ORDER BY loaded_at DESC LIMIT 1"
            )
        finally:
            await conn.close()
        return last if isinstance(last, date) else None

    def _spawn_load(self, latest: str) -> tuple[int, str]:
        env = os.environ.copy()
        env["DATABASE_URL"] = self.database_url
        if self.proxy:
            env["MUSICBRAINZ_PROXY"] = self.proxy
        env.pop("MBCOPY_ENABLED", None)
        proc = subprocess.run(
            [sys.executable, "-m", "app.mbcopy", "load", "--url", latest],
            env=env,
            capture_output=True,
            text=True,
        )
        tail = _failure_tail(
            _scrub_db_url(proc.stderr or "", self.database_url),
            _scrub_db_url(proc.stdout or "", self.database_url),
        )
        return int(proc.returncode), tail


def mbcopy_from_env(env: Mapping[str, str], database_url: str | None) -> MbCopy | None:
    if env.get("MBCOPY_ENABLED", "").strip() not in {"1", "true", "yes"}:
        return None
    if not database_url:
        return None
    return MbCopy(
        database_url,
        proxy=str(env.get("MUSICBRAINZ_PROXY", "") or "").strip() or None,
    )


def wake(app: Any) -> None:
    robot = getattr(app.state, "mbcopy", None)
    if robot is not None:
        robot.soon()


def main(argv: list[str]) -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    parser = argparse.ArgumentParser(prog="python -m app.mbcopy")
    sub = parser.add_subparsers(dest="cmd")
    load_p = sub.add_parser("load")
    load_p.add_argument("--url", default="")
    load_p.add_argument("--file", action="append", default=[])
    load_p.add_argument("--allow-main-volume", action="store_true")
    args = parser.parse_args(argv)
    if args.cmd != "load":
        parser.print_help()
        return 2
    url = os.environ.get("DATABASE_URL")
    if not url:
        print("DATABASE_URL is not set", file=sys.stderr)
        return 2
    proxy = str(os.environ.get("MUSICBRAINZ_PROXY", "") or "").strip() or None
    result = asyncio.run(
        load(
            url,
            files=args.file or None,
            url=args.url or None,
            proxy=proxy,
            allow_main_volume=args.allow_main_volume,
        )
    )
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
