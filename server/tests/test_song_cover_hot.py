"""Song cover lookup avoids HDD reads: recording -> medium index is on NVMe and includes the medium id (FT-512).

Prod, 02.10.2026: artist page "Popular" covers (FT-501) on warm db — 10 out of 10, on cold db —
0: query "recording -> mb_track -> mb_medium -> mb_release -> group" does not fit in its 1 second budget. mb_medium,
mb_release and mb_release_group are already on NVMe (FT-506); on HDD remained mb_track_new_recording index (1.4 GB) and
the mb_track table itself (5.6 GB) — each doing random reads per row. We do not move table to NVMe (test_artist_page_hot.py,
test_tracks_stay_cold): index with `INCLUDE (medium_id)` answers itself, without heap (index-only scan; visibility map
for loaded table is complete), and takes ~2 GB instead of 7.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from app import search_indexes
from tests.test_hot_tablespace import _all_sql, _creates, _record
from tests.test_mbcopy import _load, db, dump_file  # noqa: F401

INDEX = "mb_track_new_recording"


def test_song_cover_index_is_hot() -> None:
    assert search_indexes.relation_tablespace(INDEX, has_mb=True, hot_on_main=True) == ""
    assert search_indexes.relation_tablespace(INDEX, has_mb=True, hot_on_main=False) == " TABLESPACE mb"
    # Index is created directly under its final name — disk space is calculated for it as well.
    assert search_indexes.live_name(INDEX) == INDEX


async def test_loader_builds_covering_index_on_main_volume(
    db: str, dump_file: Path, monkeypatch: pytest.MonkeyPatch  # noqa: F811
) -> None:
    monkeypatch.setattr("app.mbcopy._free_bytes", lambda _path: 2**50)
    made = _record(monkeypatch)
    await _load(db, files=[str(dump_file)])
    found = _creates(_all_sql(made), INDEX)
    assert found, "index is not created by loader"
    assert all(" TABLESPACE mb" not in query for query in found), "index ended up on HDD"
    assert all("INCLUDE (medium_id)" in query for query in found), "without medium_id query reads heap mb_track from HDD"
    cold = _creates(_all_sql(made), "mb_track_new")
    assert cold and all(" TABLESPACE mb" in query for query in cold), "mb_track table must remain on HDD"
