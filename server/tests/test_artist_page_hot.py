"""Artist page reads discography from main volume (NVMe), not HDD.

Production, 02.10.2026: cold page — 7–37 s (Pink Floyd 35.7 s, Iron Maiden: groups 4.9 s, edition format on
the card 24 s), warm — 0.3 s. Time is spent on random reads of mb_release_group, mb_release, and mb_medium
from HDD (tablespace mb). The app waits 35 s: Linkin Park took 39 s the first time — error for a user.
Tables are moved to main volume manually once; loader during weekly copy replacement must place them
in the same place (test_hot_tablespace.py), and space estimate must count them under live names.
"""

from __future__ import annotations

from app import search_indexes

# Build-time name -> production name after swap. Indexes are created directly under final name.
ARTIST_PAGE = {
    "mb_release_group_new": "mb_release_group",
    "mb_release_new": "mb_release",
    "mb_medium_new": "mb_medium",
    "mb_release_group_new_artist": "mb_release_group_new_artist",
    "mb_release_new_group_mbid": "mb_release_new_group_mbid",
    "mb_medium_new_release": "mb_medium_new_release",
}


def test_artist_page_relations_are_hot() -> None:
    for name in ARTIST_PAGE:
        assert search_indexes.relation_tablespace(name, has_mb=True, hot_on_main=True) == "", name
        assert search_indexes.relation_tablespace(name, has_mb=True, hot_on_main=False) == " TABLESPACE mb", name


def test_space_estimate_counts_artist_page_tables_under_live_names() -> None:
    for name, live in ARTIST_PAGE.items():
        assert search_indexes.live_name(name) == live, name


def test_tracks_stay_cold() -> None:
    # mb_track — 5.6 GB: no place on NVMe, artist page does not need it.
    assert search_indexes.relation_tablespace("mb_track_new", has_mb=True, hot_on_main=True) == " TABLESPACE mb"
