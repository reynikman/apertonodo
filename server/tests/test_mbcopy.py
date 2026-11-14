"""Loader of own MusicBrainz copy (catalog v2, V1). Does not use network."""

from __future__ import annotations

import io
import tarfile
from datetime import date
from pathlib import Path
from typing import Any
from uuid import UUID, uuid4

import asyncpg
import pytest

import app.mbcopy as mbcopy
from app.mbcopy import (
    LIVE,
    MAINTENANCE_WORK_MEM,
    MEMBER_GID,
    PART_OF_GID,
    RETRY_AFTER_FAIL_S,
    SCHEMA_SEQUENCE,
    STG_SQL,
    SUBGENRE_GID,
    InsufficientSpace,
    SchemaMismatch,
    TablespaceRequired,
    _create_new,
    _create_staging,
    _fill_new,
    dump_date_from_latest,
    format_copy_row,
    load,
    mbcopy_from_env,
    next_attempt_ok,
    should_load,
)
from app.migrate import apply
from app import search_indexes

# The real measurement — captured before the autouse fixture replaces it.
real_free_bytes = mbcopy._free_bytes

METALLICA = "65f4f0c5-ef9e-490c-aee3-909e7ae6b2ab"
KINO = "4d02e204-826c-47b8-bfd3-2c8c0e1d1355"
MEMBER = "11111111-1111-1111-1111-111111111111"
CREDIT = "22222222-2222-2222-2222-222222222222"
RG = "33333333-3333-3333-3333-333333333333"
RELEASE = "44444444-4444-4444-4444-444444444444"
TRACK = "55555555-5555-5555-5555-555555555555"
RECORDING = "66666666-6666-6666-6666-666666666666"
WORK = "77777777-7777-7777-7777-777777777777"
GENRE_ROCK = "88888888-8888-8888-8888-888888888888"
GENRE_ALT = "99999999-9999-9999-9999-999999999999"
AREA_RU = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
AREA_SU = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
MEDIUM_ID = 10


def _add(tar: tarfile.TarFile, name: str, data: bytes) -> None:
    info = tarfile.TarInfo(name)
    info.size = len(data)
    tar.addfile(info, io.BytesIO(data))


def pack_dump(
    path: Path,
    *,
    schema: int = SCHEMA_SEQUENCE,
    extra: tuple[str, bytes] | None = None,
    table_overrides: dict[str, list[dict[str, Any]]] | None = None,
) -> None:
    tables: dict[str, list[dict[str, Any]]] = {
        "artist": [
            {"id": 1, "gid": METALLICA, "name": "Metallica", "sort_name": "Metallica", "type": 1, "ended": False},
            {
                "id": 2,
                "gid": KINO,
                "name": "Kino",
                "sort_name": "Kino",
                "type": 1,
                "area": 2,
                "begin_area": 1,
                "ended": True,
            },
            {"id": 3, "gid": MEMBER, "name": "James Hetfield", "sort_name": "Hetfield, James", "type": 2, "ended": False},
        ],
        "artist_alias": [
            {
                "id": 1,
                "artist": 2,
                "name": "Кино",
                "locale": "ru",
                "sort_name": "Кино",
                "primary_for_locale": True,
                "ended": False,
            }
        ],
        "artist_type": [
            {"id": 1, "name": "Group", "child_order": 0, "gid": "cccccccccccccccc-cccc-cccc-cccc-cccccccccccc"},
            {"id": 2, "name": "Person", "child_order": 1, "gid": "dddddddd-dddd-dddd-dddd-dddddddddddd"},
        ],
        "area": [
            {"id": 1, "gid": AREA_RU, "name": "Russia", "type": 1, "ended": False, "comment": ""},
            {"id": 2, "gid": AREA_SU, "name": "Soviet Union", "type": 1, "ended": True, "comment": ""},
        ],
        "area_type": [{"id": 1, "name": "Country", "child_order": 0, "gid": "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"}],
        "iso_3166_1": [{"area": 1, "code": "RU"}],
        "link_type": [
            {
                "id": 1,
                "child_order": 0,
                "gid": str(PART_OF_GID),
                "entity_type0": "area",
                "entity_type1": "area",
                "name": "part of",
                "link_phrase": "part of",
                "reverse_link_phrase": "has part",
                "long_link_phrase": "is part of",
            },
            {
                "id": 2,
                "child_order": 0,
                "gid": str(SUBGENRE_GID),
                "entity_type0": "genre",
                "entity_type1": "genre",
                "name": "subgenre",
                # As in the real dump (musicbrainz.org/relationship/9d61bc67-…):
                # "black metal has subgenre atmospheric black metal" — entity0 is the parent.
                "link_phrase": "subgenres",
                "reverse_link_phrase": "subgenre of",
                "long_link_phrase": "has subgenre",
            },
            {
                "id": 3,
                "child_order": 0,
                "gid": str(MEMBER_GID),
                "entity_type0": "artist",
                "entity_type1": "artist",
                "name": "member of",
                "link_phrase": "member of",
                "reverse_link_phrase": "has member",
                "long_link_phrase": "is a member of",
            },
        ],
        "link": [
            {"id": 1, "link_type": 1, "attribute_count": 0, "ended": False},
            {"id": 2, "link_type": 2, "attribute_count": 0, "ended": False},
            {"id": 3, "link_type": 3, "attribute_count": 0, "ended": False},
            {"id": 4, "link_type": 1, "attribute_count": 1, "ended": False},
        ],
        "l_area_area": [{"id": 1, "link": 1, "entity0": 1, "entity1": 2, "edits_pending": 0, "link_order": 0, "entity0_credit": "", "entity1_credit": ""}],
        "artist_credit": [{"id": 1, "name": "Metallica", "artist_count": 1, "ref_count": 1, "edits_pending": 0, "gid": CREDIT}],
        "artist_credit_name": [
            {"artist_credit": 1, "position": 0, "artist": 1, "name": "Metallica", "join_phrase": ""}
        ],
        "release_group": [
            {"id": 1, "gid": RG, "name": "Metallica", "artist_credit": 1, "type": 1, "comment": "", "edits_pending": 0}
        ],
        "release_group_primary_type": [
            {"id": 1, "name": "Album", "child_order": 0, "gid": "ffffffff-ffff-ffff-ffff-ffffffffffff"}
        ],
        "release_group_secondary_type": [
            {"id": 1, "name": "Soundtrack", "child_order": 0, "gid": "12121212-1212-1212-1212-121212121212"}
        ],
        "release_group_secondary_type_join": [{"release_group": 1, "secondary_type": 1}],
        "release": [
            {
                "id": 1,
                "gid": RELEASE,
                "name": "Metallica",
                "artist_credit": 1,
                "release_group": 1,
                "status": 1,
                "comment": "",
                "edits_pending": 0,
                "quality": -1,
            }
        ],
        "release_status": [{"id": 1, "name": "Official", "child_order": 0, "gid": "13131313-1313-1313-1313-131313131313"}],
        "release_country": [{"release": 1, "country": 1, "date_year": 1991, "date_month": 8, "date_day": 12}],
        "medium": [
            {
                "id": MEDIUM_ID,
                "release": 1,
                "position": 1,
                "format": 1,
                "name": "",
                "edits_pending": 0,
                "track_count": 1,
                "gid": "14141414-1414-1414-1414-141414141414",
            }
        ],
        "medium_format": [
            {"id": 1, "name": "CD", "child_order": 0, "has_discids": True, "gid": "15151515-1515-1515-1515-151515151515"}
        ],
        "recording": [
            {
                "id": 1,
                "gid": RECORDING,
                "name": "Enter Sandman",
                "artist_credit": 1,
                "length": 331573,
                "comment": "album version",
                "edits_pending": 0,
                "video": False,
            }
        ],
        "track": [
            {
                "id": 1,
                "gid": TRACK,
                "recording": 1,
                "medium": MEDIUM_ID,
                "position": 1,
                "number": "1",
                "name": "Enter Sandman",
                "artist_credit": 1,
                "length": 331573,
                "edits_pending": 0,
                "is_data_track": False,
            }
        ],
        "isrc": [{"id": 1, "recording": 1, "isrc": "USPR39105201", "edits_pending": 0}],
        "work": [{"id": 1, "gid": WORK, "name": "Enter Sandman", "comment": "", "edits_pending": 0}],
        "l_recording_work": [
            {"id": 1, "link": 4, "entity0": 1, "entity1": 1, "edits_pending": 0, "link_order": 0, "entity0_credit": "", "entity1_credit": ""}
        ],
        "link_attribute_type": [
            {
                "id": 1,
                "parent": 1,
                "root": 1,
                "child_order": 0,
                "gid": "16161616-1616-1616-1616-161616161616",
                "name": "live",
            }
        ],
        "link_attribute": [{"link": 4, "attribute_type": 1}],
        "genre": [
            {"id": 1, "gid": GENRE_ROCK, "name": "rock", "comment": "", "edits_pending": 0},
            {"id": 2, "gid": GENRE_ALT, "name": "alternative rock", "comment": "", "edits_pending": 0},
        ],
        "l_genre_genre": [
            {"id": 1, "link": 2, "entity0": 1, "entity1": 2, "edits_pending": 0, "link_order": 0, "entity0_credit": "", "entity1_credit": ""}
        ],
        "l_artist_artist": [
            {"id": 1, "link": 3, "entity0": 3, "entity1": 1, "edits_pending": 0, "link_order": 0, "entity0_credit": "", "entity1_credit": ""}
        ],
        "tag": [{"id": 1, "name": "metal", "ref_count": 10}],
        "artist_tag": [{"artist": 1, "tag": 1, "count": 42}],
        "release_group_tag": [{"release_group": 1, "tag": 1, "count": 7}],
        "recording_tag": [{"recording": 1, "tag": 1, "count": 3}],
    }
    if table_overrides:
        tables.update(table_overrides)
    with tarfile.open(path, "w:bz2") as tar:
        _add(tar, "TIMESTAMP", b"2026-09-19 00:20:48+00\n")
        _add(tar, "REPLICATION_SEQUENCE", b"189107\n")
        _add(tar, "SCHEMA_SEQUENCE", f"{schema}\n".encode())
        for name, rows in tables.items():
            body = "".join(format_copy_row(name, row) for row in rows).encode()
            _add(tar, f"mbdump/{name}", body)
        if extra is not None:
            _add(tar, extra[0], extra[1])


async def _load(url: str, **kwargs: Any) -> dict[str, Any]:
    kwargs.setdefault("allow_main_volume", True)
    return await load(url, **kwargs)


async def _counts(url: str) -> dict[str, int]:
    conn = await asyncpg.connect(url)
    try:
        out = {}
        for live in LIVE:
            out[live] = int(await conn.fetchval(f"SELECT count(*) FROM {live}") or 0)
        return out
    finally:
        await conn.close()


async def _leftover_new(url: str) -> list[str]:
    conn = await asyncpg.connect(url)
    try:
        rows = await conn.fetch(
            "SELECT tablename FROM pg_tables WHERE schemaname = current_schema() AND tablename LIKE $1",
            "%_new",
        )
        return sorted(str(row["tablename"]) for row in rows)
    finally:
        await conn.close()


@pytest.fixture
async def db(postgres_url: str) -> str:
    await apply(postgres_url)
    conn = await asyncpg.connect(postgres_url)
    try:
        for live in (*LIVE, "mb_loads"):
            await conn.execute(f"TRUNCATE {live} CASCADE")
    finally:
        await conn.close()
    return postgres_url


@pytest.fixture
def dump_file(tmp_path: Path) -> Path:
    path = tmp_path / "mbdump.tar.bz2"
    pack_dump(path)
    return path


async def test_load_counts_match_fixture(db: str, dump_file: Path) -> None:
    result = await _load(db, files=[str(dump_file)])
    counts = await _counts(db)
    assert counts["mb_artist"] == 3
    assert counts["mb_artist_alias"] == 1
    assert counts["mb_area"] == 2
    assert counts["mb_area_part"] == 1
    assert counts["mb_release_group"] == 1
    assert counts["mb_release"] == 1
    assert counts["mb_medium"] == 1
    assert counts["mb_track"] == 1
    assert counts["mb_recording"] == 1
    assert counts["mb_isrc"] == 1
    assert counts["mb_work"] == 1
    assert counts["mb_recording_work"] == 1
    assert counts["mb_genre"] == 2
    assert counts["mb_genre_edge"] == 1
    assert counts["mb_artist_artist"] == 1
    assert counts["mb_tag"] == 1
    assert counts["mb_artist_tag"] == 1
    assert counts["mb_release_group_tag"] == 1
    assert counts["mb_recording_tag"] == 1
    assert result["row_counts"]["mb_artist"] == 3
    conn = await asyncpg.connect(db)
    try:
        alias = await conn.fetchval("SELECT name FROM mb_artist_alias")
        assert alias == "Кино"
        types = await conn.fetchval("SELECT secondary_types FROM mb_release_group")
        assert "Soundtrack" in list(types)
        iso = await conn.fetchval("SELECT iso3166 FROM mb_area WHERE name = 'Russia'")
        assert iso == "RU"
        kino_area = await conn.fetchval("SELECT area_mbid FROM mb_artist WHERE name = 'Kino'")
        assert str(kino_area) == AREA_SU
        kino_begin = await conn.fetchval("SELECT begin_area_mbid FROM mb_artist WHERE name = 'Kino'")
        assert str(kino_begin) == AREA_RU
        edge = await conn.fetchrow("SELECT child_mbid::text AS child, parent_mbid::text AS parent, kind FROM mb_genre_edge")
        # rock (entity0) has subgenre alternative rock (entity1). Reversed on 30.09 in production:
        # the climb went down into subgenres and 125 419 artists fell into worldwide.
        assert (edge["child"], edge["parent"], edge["kind"]) == (GENRE_ALT, GENRE_ROCK, "subgenre")
        dump_date = await conn.fetchval("SELECT dump_date FROM mb_loads")
        assert dump_date == date(2026, 9, 19)
        seq = await conn.fetchval("SELECT replication_sequence FROM mb_loads")
        assert seq == 189107
        comment = await conn.fetchval("SELECT comment FROM mb_recording")
        assert comment == "album version"
        attrs = await conn.fetchval("SELECT attributes FROM mb_recording_work")
        assert "live" in list(attrs or [])
        space = await conn.fetchval("SELECT tablespace FROM mb_loads")
        assert space in {"mb", "pg_default"}
        size = await conn.fetchval("SELECT size_bytes FROM mb_loads")
        assert size is not None and size > 0
    finally:
        await conn.close()


async def test_reload_does_not_duplicate(db: str, dump_file: Path) -> None:
    await _load(db, files=[str(dump_file)])
    first = await _counts(db)
    await _load(db, files=[str(dump_file)])
    assert await _counts(db) == first
    conn = await asyncpg.connect(db)
    try:
        loads = int(await conn.fetchval("SELECT count(*) FROM mb_loads") or 0)
    finally:
        await conn.close()
    assert loads == 2


async def test_wrong_schema_keeps_previous_copy(db: str, dump_file: Path, tmp_path: Path) -> None:
    await _load(db, files=[str(dump_file)])
    before = await _counts(db)
    bad = tmp_path / "bad.tar.bz2"
    pack_dump(bad, schema=1)
    with pytest.raises(SchemaMismatch, match="схема дампа 1, загрузчик ждёт 31"):
        await _load(db, files=[str(bad)])
    assert await _counts(db) == before
    assert await _leftover_new(db) == []


async def test_crash_during_swap_keeps_previous_copy_and_drops_new(
    db: str, dump_file: Path
) -> None:
    await _load(db, files=[str(dump_file)])
    before = await _counts(db)
    import app.mbcopy as mbcopy

    async def boom() -> None:
        raise RuntimeError("injected")

    mbcopy._swap_hook = boom
    try:
        with pytest.raises(RuntimeError, match="injected"):
            await _load(db, files=[str(dump_file)])
    finally:
        mbcopy._swap_hook = None
    assert await _counts(db) == before
    assert await _leftover_new(db) == []


async def test_unknown_members_are_skipped(db: str, tmp_path: Path) -> None:
    extra = format_copy_row(
        "artist",
        {
            "id": 99,
            "gid": "cafecafe-cafe-cafe-cafe-cafecafecafe",
            "name": "Extra",
            "sort_name": "Extra",
            "ended": False,
        },
    ).encode()
    path = tmp_path / "extra.tar.bz2"
    pack_dump(path, extra=("mbdump/editor", extra))
    result = await _load(db, files=[str(path)])
    assert result["row_counts"]["mb_artist"] == 3


def test_saturday_dump_is_loaded_once() -> None:
    saturday = date(2026, 9, 19)
    wednesday = date(2026, 9, 16)
    assert should_load(saturday, None)
    assert not should_load(saturday, saturday)
    assert not should_load(wednesday, None)
    assert dump_date_from_latest("20260919-002047") == saturday


def test_robot_stays_off_without_the_switch() -> None:
    assert mbcopy_from_env({}, "postgresql://music@127.0.0.1/none") is None
    assert mbcopy_from_env({"MBCOPY_ENABLED": "1"}, None) is None
    assert mbcopy_from_env({"MBCOPY_ENABLED": "1"}, "postgresql://music@127.0.0.1/none") is not None


def test_failed_load_waits_a_day() -> None:
    assert next_attempt_ok(100.0, None)
    assert not next_attempt_ok(100.0, 99.0)
    assert not next_attempt_ok(100.0 + RETRY_AFTER_FAIL_S - 1, 100.0)
    assert next_attempt_ok(100.0 + RETRY_AFTER_FAIL_S, 100.0)


async def test_without_tablespace_refuses(db: str, dump_file: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    await _load(db, files=[str(dump_file)])
    before = await _counts(db)

    async def no_ts(_conn: asyncpg.Connection) -> bool:
        return False

    monkeypatch.setattr("app.mbcopy.ensure_tablespace", no_ts)
    with pytest.raises(TablespaceRequired, match="tablespace mb"):
        await load(db, files=[str(dump_file)])
    assert await _counts(db) == before
    assert await _leftover_new(db) == []


class _Stop(Exception):
    """Sentinel for the recording wrapper: stop the load at one statement."""


class _RecordingConn:
    """asyncpg connection wrapper: records SQL and can fake path answers."""

    def __init__(
        self, conn: Any, *, paths: dict[str, str], stop_before: str | None
    ) -> None:
        self._conn = conn
        self.sql: list[str] = []
        self.paths = paths
        self.stop_before = stop_before

    def __getattr__(self, name: str) -> Any:
        return getattr(self._conn, name)

    async def execute(self, query: str, *args: Any, **kwargs: Any) -> str:
        self.sql.append(query)
        if self.stop_before is not None and self.stop_before in query:
            raise _Stop(query)
        return await self._conn.execute(query, *args, **kwargs)

    async def fetchval(self, query: str, *args: Any, **kwargs: Any) -> Any:
        self.sql.append(query)
        for marker, value in self.paths.items():
            if marker in query:
                return value
        return await self._conn.fetchval(query, *args, **kwargs)


def _record(
    monkeypatch: pytest.MonkeyPatch,
    *,
    paths: dict[str, str] | None = None,
    stop_before: str | None = None,
) -> list[_RecordingConn]:
    made: list[_RecordingConn] = []
    real_connect = asyncpg.connect

    async def connect(*args: Any, **kwargs: Any) -> Any:
        wrapper = _RecordingConn(
            await real_connect(*args, **kwargs),
            paths=paths or {},
            stop_before=stop_before,
        )
        made.append(wrapper)
        return wrapper

    monkeypatch.setattr(asyncpg, "connect", connect)
    return made


def _force_mb(monkeypatch: pytest.MonkeyPatch) -> None:
    async def has_mb(_conn: asyncpg.Connection) -> bool:
        return True

    monkeypatch.setattr("app.mbcopy.ensure_tablespace", has_mb)


async def _state(url: str) -> tuple[list[str], int]:
    conn = await asyncpg.connect(url)
    try:
        schemas = await conn.fetch(
            "SELECT nspname FROM pg_namespace WHERE nspname LIKE 'catalog_gen_%'"
        )
        return (
            sorted(str(row["nspname"]) for row in schemas),
            int(await conn.fetchval("SELECT count(*) FROM mb_loads") or 0),
        )
    finally:
        await conn.close()


@pytest.fixture(autouse=True)
def _ample_disk_space(monkeypatch: pytest.MonkeyPatch) -> None:
    # In CI Postgres is another container: the paths it reports exist only
    # there. The loader measures disk space through this one seam, so the load
    # tests never stat Postgres-side paths.
    monkeypatch.setattr("app.mbcopy._free_bytes", lambda _path: 2**50)


async def test_short_tablespace_filesystem_refuses_before_create(
    db: str, dump_file: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _force_mb(monkeypatch)
    _record(
        monkeypatch,
        paths={"pg_tablespace_location": "/fake/mb", "SHOW data_directory": "/fake/data"},
    )
    monkeypatch.setattr(
        "app.mbcopy._free_bytes", lambda path: 0 if path == "/fake/mb" else 2**50
    )
    before_schemas, before_loads = await _state(db)
    with pytest.raises(InsufficientSpace) as excinfo:
        await _load(db, files=[str(dump_file)])
    assert str(excinfo.value) == "insufficient free space for catalog tables and indexes"
    after_schemas, after_loads = await _state(db)
    assert after_schemas == before_schemas  # no new catalog_gen_* schema
    assert after_loads == before_loads


async def test_short_wal_reserve_refuses_before_create(
    db: str, dump_file: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _force_mb(monkeypatch)
    _record(
        monkeypatch,
        paths={"pg_tablespace_location": "/fake/mb", "SHOW data_directory": "/fake/data"},
    )
    monkeypatch.setattr(
        "app.mbcopy._free_bytes", lambda path: 0 if path == "/fake/data" else 2**50
    )
    before_schemas, before_loads = await _state(db)
    with pytest.raises(InsufficientSpace) as excinfo:
        await _load(db, files=[str(dump_file)])
    assert str(excinfo.value) == "insufficient free space for WAL"
    after_schemas, after_loads = await _state(db)
    assert after_schemas == before_schemas  # no new catalog_gen_* schema
    assert after_loads == before_loads


async def test_unstatable_path_refuses_closed(
    db: str, dump_file: Path, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _force_mb(monkeypatch)
    _record(
        monkeypatch,
        paths={
            "pg_tablespace_location": str(tmp_path / "missing-mb"),
            "SHOW data_directory": str(tmp_path / "missing-data"),
        },
    )
    # Not patched: the real measurement runs and must refuse what it cannot stat.
    monkeypatch.setattr("app.mbcopy._free_bytes", real_free_bytes)
    before_schemas, before_loads = await _state(db)
    with pytest.raises(InsufficientSpace, match="Postgres volumes are not mounted"):
        await _load(db, files=[str(dump_file)])
    after_schemas, after_loads = await _state(db)
    assert after_schemas == before_schemas  # no new catalog_gen_* schema
    assert after_loads == before_loads


async def test_index_sorts_go_to_tablespace_mb(
    db: str, dump_file: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _force_mb(monkeypatch)
    made = _record(monkeypatch, stop_before="SET temp_tablespaces")
    with pytest.raises(_Stop):
        await _load(db, files=[str(dump_file)])
    sql = [query for conn in made for query in conn.sql]
    assert "SET temp_tablespaces = mb" in sql
    assert sql.index("SET temp_tablespaces = mb") > sql.index(
        f"SET maintenance_work_mem = '{MAINTENANCE_WORK_MEM}'"
    )
    assert not any("CREATE INDEX" in query for query in sql)


async def test_release_country_and_date_choice(db: str, tmp_path: Path) -> None:
    r1 = "44444444-4444-4444-4444-444444444441"
    r2 = "44444444-4444-4444-4444-444444444442"
    r3 = "44444444-4444-4444-4444-444444444443"
    area3 = "33333333-3333-3333-3333-333333333333"
    path = tmp_path / "choice.tar.bz2"
    pack_dump(
        path,
        table_overrides={
            "area": [
                {"id": 1, "gid": AREA_RU, "name": "Russia", "type": 1, "ended": False, "comment": ""},
                {"id": 2, "gid": AREA_SU, "name": "Soviet Union", "type": 1, "ended": True, "comment": ""},
                {"id": 3, "gid": area3, "name": "Country 3", "type": 1, "ended": False, "comment": ""},
            ],
            "iso_3166_1": [
                {"area": 1, "code": "RU"},
                {"area": 2, "code": "SU"},
                {"area": 3, "code": "DE"},
            ],
            "release": [
                {"id": 1, "gid": r1, "name": "R1", "artist_credit": 1, "release_group": 1, "status": 1, "comment": "", "edits_pending": 0, "quality": -1},
                {"id": 2, "gid": r2, "name": "R2", "artist_credit": 1, "release_group": 1, "status": 1, "comment": "", "edits_pending": 0, "quality": -1},
                {"id": 3, "gid": r3, "name": "R3", "artist_credit": 1, "release_group": 1, "status": 1, "comment": "", "edits_pending": 0, "quality": -1},
            ],
            "release_country": [
                {"release": 1, "country": 2, "date_year": 2001, "date_month": 5, "date_day": 1},
                {"release": 1, "country": 1, "date_year": 1999, "date_month": 3, "date_day": 2},
                {"release": 1, "country": 3, "date_year": None, "date_month": None, "date_day": None},
                {"release": 2, "country": 2, "date_year": 1999, "date_month": 11, "date_day": 1},
                {"release": 2, "country": 3, "date_year": 1999, "date_month": 2, "date_day": 1},
            ],
            "release_unknown_country": [
                {"release": 3, "date_year": 2005, "date_month": 6, "date_day": 7},
            ],
        },
    )
    await _load(db, files=[str(path)])
    conn = await asyncpg.connect(db)
    try:
        rows = await conn.fetch("SELECT mbid, country, date FROM mb_release")
        by_mbid = {str(r["mbid"]): (r["country"], r["date"]) for r in rows}
        assert by_mbid[r1] == ("RU", "1999-03-02")
        assert by_mbid[r2] == ("DE", "1999-02-01")
        assert by_mbid[r3] == (None, "2005-06-07")
    finally:
        await conn.close()


async def test_release_country_scale(db: str) -> None:
    conn = await asyncpg.connect(db)
    schema = f"scale_test_{uuid4().hex}"
    try:
        await conn.execute(f'CREATE SCHEMA "{schema}"')
        await conn.execute(f'SET search_path TO "{schema}", public')
        await _create_staging(conn, False)
        await _create_new(conn, False)
        n = 30000
        sample_gid = UUID(int=1)
        r_gids = [UUID(int=i) for i in range(1, n + 1)]
        g_gids = [UUID(int=n + i) for i in range(1, n + 1)]
        rg_records = [(i, g_gids[i - 1], f"g{i}", None, None) for i in range(1, n + 1)]
        rel_records = [(i, r_gids[i - 1], f"r{i}", i, None) for i in range(1, n + 1)]
        rc_records = []
        for i in range(1, n + 1):
            rc_records.append((i, 2, 2020, 5, 10))
            rc_records.append((i, 1, 2005, 3, 1))
            rc_records.append((i, 3, 2012, 11, 20))
        await conn.copy_records_to_table(
            "mb_stg_release_group",
            records=rg_records,
            columns=[c.split()[0] for c in STG_SQL["release_group"].split(", ")],
        )
        await conn.copy_records_to_table(
            "mb_stg_release",
            records=rel_records,
            columns=[c.split()[0] for c in STG_SQL["release"].split(", ")],
        )
        await conn.copy_records_to_table(
            "mb_stg_release_country",
            records=rc_records,
            columns=[c.split()[0] for c in STG_SQL["release_country"].split(", ")],
        )
        await conn.execute("ANALYZE mb_stg_release_group")
        await conn.execute("ANALYZE mb_stg_release")
        await conn.execute("ANALYZE mb_stg_release_country")
        await conn.execute("SET statement_timeout = '15s'")
        await _fill_new(conn)
        assert await conn.fetchval("SELECT count(*) FROM mb_release_new") == n
        assert (
            await conn.fetchval(
                "SELECT date FROM mb_release_new WHERE mbid = $1", sample_gid
            )
            == "2005-03-01"
        )
    finally:
        try:
            await conn.execute(f'DROP SCHEMA IF EXISTS "{schema}" CASCADE')
        finally:
            await conn.close()


async def test_drop_abandoned_generations_on_load(db: str, dump_file: Path) -> None:
    conn = await asyncpg.connect(db)
    abandoned_schema = f"catalog_gen_{uuid4().hex}"
    listed_schema = f"catalog_gen_{uuid4().hex}"
    listed_id = uuid4()
    try:
        await conn.execute(f'CREATE SCHEMA "{abandoned_schema}"')
        await conn.execute(f'CREATE TABLE "{abandoned_schema}".dummy (id int)')
        await conn.execute(f'CREATE SCHEMA "{listed_schema}"')
        await conn.execute(f'CREATE TABLE "{listed_schema}".dummy (id int)')
        await conn.execute(
            "INSERT INTO public.catalog_generation (generation_id, schema_name, is_current) VALUES ($1, $2, false)",
            listed_id,
            listed_schema,
        )
    finally:
        await conn.close()

    try:
        await _load(db, files=[str(dump_file)])
        conn = await asyncpg.connect(db)
        try:
            assert not await conn.fetchval(
                "SELECT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname = $1)",
                abandoned_schema,
            )
            assert await conn.fetchval(
                "SELECT EXISTS(SELECT 1 FROM pg_tables WHERE schemaname = $1 AND tablename = 'dummy')",
                listed_schema,
            )
        finally:
            await conn.close()
    finally:
        conn = await asyncpg.connect(db)
        try:
            await conn.execute(f'DROP SCHEMA IF EXISTS "{listed_schema}" CASCADE')
            await conn.execute(
                "DELETE FROM public.catalog_generation WHERE generation_id = $1",
                listed_id,
            )
            await conn.execute(f'DROP SCHEMA IF EXISTS "{abandoned_schema}" CASCADE')
        finally:
            await conn.close()


async def test_load_session_notices_its_client_is_gone(
    db: str, dump_file: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    seen: list[str] = []
    fill_new = mbcopy._fill_new

    async def recording(conn: asyncpg.Connection) -> dict[str, int]:
        seen.append(await conn.fetchval("SHOW client_connection_check_interval"))
        return await fill_new(conn)

    monkeypatch.setattr("app.mbcopy._fill_new", recording)
    await _load(db, files=[str(dump_file)])
    assert seen == ["10s"]


async def _expected_hot_required(conn: asyncpg.Connection) -> int:
    """Same formula as `mbcopy.hot_fits_main_volume`, computed independently."""
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
    return wal_required + hot_bytes + mbcopy.MAIN_VOLUME_RESERVE_BYTES


async def test_hot_fits_main_volume_boundary(db: str, monkeypatch: pytest.MonkeyPatch) -> None:
    conn = await asyncpg.connect(db)
    try:
        data_path = str(await conn.fetchval("SHOW data_directory"))
        required = await _expected_hot_required(conn)
        monkeypatch.setattr(
            "app.mbcopy._free_bytes", lambda path: required if path == data_path else 0
        )
        assert await mbcopy.hot_fits_main_volume(conn, has_mb=True) is True
        monkeypatch.setattr(
            "app.mbcopy._free_bytes", lambda path: required - 1 if path == data_path else 0
        )
        assert await mbcopy.hot_fits_main_volume(conn, has_mb=True) is False
    finally:
        await conn.close()


async def test_hot_fits_main_volume_ignores_same_name_in_other_schema(
    db: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    # A generation schema (catalog_gen_*) holds tables named exactly like the
    # hot ones (song, mb_artist, …) while a load is in flight; their size must
    # not count towards the main-volume requirement.
    conn = await asyncpg.connect(db)
    schema = f"catalog_gen_{uuid4().hex}"
    try:
        data_path = str(await conn.fetchval("SHOW data_directory"))
        required = await _expected_hot_required(conn)
        await conn.execute(f'CREATE SCHEMA "{schema}"')
        await conn.execute(f'CREATE TABLE "{schema}".song (id bigint, filler text)')
        await conn.execute(
            f'INSERT INTO "{schema}".song '
            "SELECT g, repeat('x', 2000) FROM generate_series(1, 5000) g"
        )
        monkeypatch.setattr(
            "app.mbcopy._free_bytes", lambda path: required if path == data_path else 0
        )
        assert await mbcopy.hot_fits_main_volume(conn, has_mb=True) is True
        monkeypatch.setattr(
            "app.mbcopy._free_bytes", lambda path: required - 1 if path == data_path else 0
        )
        assert await mbcopy.hot_fits_main_volume(conn, has_mb=True) is False
    finally:
        await conn.execute(f'DROP SCHEMA IF EXISTS "{schema}" CASCADE')
        await conn.close()
