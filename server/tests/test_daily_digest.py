"""FT-872: the daily digest — one page a day from what the server already records.

The owner wants every morning: how many Plays, how long a song took to start from the cache and from
scratch, how many failed and why, which artists failed, what people reported. `build(data)` is a pure
function over rows already read from the tables; `render(digest)` turns it into the page. No database here.

What these tests do not prove: that the SELECTs read the right day on production (the first real page does).
"""

from __future__ import annotations

from datetime import datetime, timezone

from app import daily_digest

DAY = datetime(2026, 10, 14, tzinfo=timezone.utc)


def _timing(
    outcome: str,
    cached: bool,
    first_byte: int | None,
    source: str = "ext-a",
    prepared: bool = False,
) -> dict:
    return {
        "at": DAY,
        "track_id": "t",
        "source": source,
        "prepared": prepared,
        "outcome": outcome,
        "find_ms": 100,
        "prepare_ms": 900,
        "token_ms": 950,
        "first_byte_ms": first_byte,
        "first_256k_ms": None if first_byte is None else first_byte + 500,
        "peers": 3,
        "speed_bps": 100_000,
        "have_pct": 100,
        "via": "cache" if cached else "link",
    }


def _data() -> dict:
    timing = (
        [_timing("played", True, 200)] * 6  # from the cache: fast
        + [_timing("played", False, 5000)] * 3  # new songs: slow
        + [_timing("played", False, 28000)]  # one very slow new song
        + [
            _timing("played", False, 4000, prepared=True)
        ]  # prepared ahead, bytes still from the link: not cache
        + [_timing("not_ready", False, None)] * 2
    )
    failures = [
        {
            "at": DAY,
            "user_id": "u1",
            "kind": "no_source",
            "track_id": "a",
            "artist": "Bach",
            "title": "x",
            "ref": None,
        },
        {
            "at": DAY,
            "user_id": "u1",
            "kind": "no_source",
            "track_id": "b",
            "artist": "Bach",
            "title": "y",
            "ref": None,
        },
        {
            "at": DAY,
            "user_id": "u2",
            "kind": "low_confidence",
            "track_id": "c",
            "artist": "Booba",
            "title": "z",
            "ref": None,
        },
    ]
    reports = [
        {
            "created_at": DAY,
            "user_id": "u1",
            "reason": "wrong_song",
            "place": "player",
            "track_id": None,
            "album_id": None,
            "playlist_id": None,
            "artist": "Bach",
            "text": "играет не та часть",
            "app_version": "1.0",
        }
    ]
    listens = [{"played_at": DAY, "user_id": "u1"}] * 9 + [
        {"played_at": DAY, "user_id": "u2"}
    ] * 2
    return {
        "day": DAY.date(),
        "timing": timing,
        "failures": failures,
        "reports": reports,
        "listens": listens,
    }


def test_counts_plays_and_splits_cache_from_new_songs():
    digest = daily_digest.build(_data())
    assert digest["plays"]["total"] == 13
    assert digest["plays"]["played"] == 11
    assert digest["plays"]["cache"]["count"] == 6
    assert digest["plays"]["cache"]["first_byte_median_ms"] == 200
    assert digest["plays"]["new"]["count"] == 5
    assert digest["plays"]["new"]["first_byte_median_ms"] == 5000
    assert digest["plays"]["new"]["first_byte_max_ms"] == 28000


def test_groups_failures_by_kind_and_names_the_artists_that_failed_most():
    digest = daily_digest.build(_data())
    assert digest["failures"]["by_kind"] == {"no_source": 2, "low_confidence": 1}
    assert digest["failures"]["artists"][0] == ("Bach", 2)


def test_lists_reports_with_their_text_and_counts_listeners():
    digest = daily_digest.build(_data())
    assert digest["reports"][0]["text"] == "играет не та часть"
    assert digest["listens"] == {"total": 11, "people": 2}


def test_the_page_names_every_section_and_the_numbers_a_reader_needs():
    page = daily_digest.render(daily_digest.build(_data()))
    for needle in (
        "2026-10-14",
        "Play",
        "кэш",
        "нов",
        "no_source",
        "Bach",
        "играет не та часть",
        "28",
    ):
        assert needle in page, needle


def test_an_empty_day_still_renders_without_errors():
    empty = {
        "day": DAY.date(),
        "timing": [],
        "failures": [],
        "reports": [],
        "listens": [],
    }
    page = daily_digest.render(daily_digest.build(empty))
    assert "2026-10-14" in page
