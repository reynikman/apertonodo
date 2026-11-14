"""The hot search portion is built on the main volume (NVMe), the rest — in tablespace mb (HDD).

Cold search in production 30.09.2026: 12 out of 34 queries took up to 1.5 s —
360–450 random heap reads of song/song_version/mb_recording from HDD at ~3.4 ms each.
These tables and search indexes were moved to the main volume manually; the loader
must put them there during weekly replica updates, otherwise everything returns to HDD.
If the main volume lacks space — slower search is better than failed
update: hot data falls back to mb, producing a single log line.
"""

from __future__ import annotations

import logging
import re
from pathlib import Path
from typing import Any

import asyncpg
import pytest

from tests.test_mbcopy import _load, _RecordingConn, db, dump_file  # noqa: F401

HOT = (
    "mb_artist_new",
    "mb_artist_alias_new",
    "mb_recording_new",
    "song_load",
    "song_version_load",
    "mb_artist_new_name_lower",
    "mb_artist_new_name_trgm",
    "mb_artist_alias_new_name_lower",
    "mb_recording_new_title_lower",
    "song_version_load_song",
    "song_artist",
    "song_title_lower",
    "song_title_trgm",
    # Artist page (FT-506): discography and release format on the card.
    "mb_release_group_new",
    "mb_release_new",
    "mb_medium_new",
    "mb_release_group_new_artist",
    "mb_release_new_group_mbid",
    "mb_medium_new_release",
)
# Cold data stays on HDD: an "erase mb everywhere" check will fail.
COLD = ("mb_area_new", "mb_track_new", "song_work")

GIB = 2**30
# Order matters: _RecordingConn responds to the first matching marker.
# Second marker — "is tablespace mb present": it's absent in test DB, but we test selection when it is.
PATHS = {
    "pg_tablespace_location": "/fake/mb",
    "SHOW data_directory": "/fake/data",
    "spcname = 'mb'": 1,
}


class _NoMbConn(_RecordingConn):
    """Writes SQL as is, but executes without tablespace mb: absent in test DB."""

    async def execute(self, query: str, *args: Any, **kwargs: Any) -> str:
        self.sql.append(query)
        real = query.replace(" TABLESPACE mb", "")
        if real.lstrip().startswith("SET temp_tablespaces"):
            real = "SELECT 1"
        return await self._conn.execute(real, *args, **kwargs)


def _record(monkeypatch: pytest.MonkeyPatch) -> list[_NoMbConn]:
    made: list[_NoMbConn] = []
    real_connect = asyncpg.connect

    async def connect(*args: Any, **kwargs: Any) -> Any:
        wrapper = _NoMbConn(await real_connect(*args, **kwargs), paths=PATHS, stop_before=None)  # type: ignore[arg-type]
        made.append(wrapper)
        return wrapper

    async def has_mb(_conn: asyncpg.Connection) -> bool:
        return True

    monkeypatch.setattr(asyncpg, "connect", connect)
    monkeypatch.setattr("app.mbcopy.ensure_tablespace", has_mb)
    return made


def _creates(sql: list[str], name: str) -> list[str]:
    pattern = re.compile(rf"CREATE\s+(UNLOGGED\s+)?(TABLE|INDEX)\s+(IF NOT EXISTS\s+)?(\w+\.)?{name}\b")
    return [query for query in sql if pattern.search(query)]


def _all_sql(made: list[_NoMbConn]) -> list[str]:
    return [query for conn in made for query in conn.sql]


async def test_hot_search_relations_are_built_on_main_volume(
    db: str, dump_file: Path, monkeypatch: pytest.MonkeyPatch  # noqa: F811
) -> None:
    monkeypatch.setattr("app.mbcopy._free_bytes", lambda _path: 2**50)
    made = _record(monkeypatch)
    await _load(db, files=[str(dump_file)])
    sql = _all_sql(made)
    for name in HOT:
        found = _creates(sql, name)
        assert found, f"{name}: not created by loader"
        assert all(" TABLESPACE mb" not in query for query in found), f"{name}: ended up on HDD"
    for name in COLD:
        found = _creates(sql, name)
        assert found, f"{name}: not created by loader"
        assert all(" TABLESPACE mb" in query for query in found), f"{name}: must remain on HDD"


async def test_hot_relations_fall_back_to_mb_when_main_volume_is_short(
    db: str, dump_file: Path, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture  # noqa: F811
) -> None:
    # Main volume has enough for WAL, but not for hot data with 10 GB headroom.
    free = {"/fake/data": 5 * GIB, "/fake/mb": 2**50}
    monkeypatch.setattr("app.mbcopy._free_bytes", lambda path: free[str(path)])
    made = _record(monkeypatch)
    with caplog.at_level(logging.WARNING):
        await _load(db, files=[str(dump_file)])
    sql = _all_sql(made)
    for name in HOT:
        found = _creates(sql, name)
        assert found, f"{name}: not created by loader"
        assert all(" TABLESPACE mb" in query for query in found), f"{name}: out of space, but not on HDD"
    assert any("hot" in record.getMessage() and "mb" in record.getMessage() for record in caplog.records)
