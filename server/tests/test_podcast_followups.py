"""FT-705 — second-look fixes: Apple empty response is held for minutes, podcast crawl log — in common logger.

Lead check; executor does not modify this file.
"""

from __future__ import annotations

import asyncio
import logging

import pytest

from app import podcast_catalog, podcast_wiring
from app.log_config import LOGGING_CONFIG
from app.podcast_catalog import FoundPodcast, PodcastSearchUnavailable, TopCache


class Clock:
    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now


def podcast(n: int) -> FoundPodcast:
    return FoundPodcast(f"t{n}", "a", f"https://feed{n}.example/rss", None, None)


class Answers:
    """Responds in turn with given lists; `None` — directory unavailable."""

    def __init__(self, *answers: list[FoundPodcast] | None) -> None:
        self.answers = list(answers)
        self.calls = 0

    async def __call__(self) -> list[FoundPodcast]:
        answer = self.answers[min(self.calls, len(self.answers) - 1)]
        self.calls += 1
        if answer is None:
            raise PodcastSearchUnavailable()
        return answer


def get(
    cache: TopCache, fetch: Answers, key: tuple[str, int | None] = ("ru", 1533)
) -> list[FoundPodcast]:
    return asyncio.run(cache.get(key, fetch))


def test_empty_hold_is_short() -> None:
    assert 60 <= podcast_catalog.EMPTY_FRESH_S <= 15 * 60
    assert podcast_catalog.EMPTY_FRESH_S < podcast_catalog.FRESH_S


def test_empty_answer_is_held_minutes_not_hours() -> None:
    clock = Clock()
    cache = TopCache(clock=clock)
    fetch = Answers([], [podcast(1)])
    assert get(cache, fetch) == []
    clock.now += podcast_catalog.EMPTY_FRESH_S - 1
    assert get(cache, fetch) == []
    assert fetch.calls == 1
    clock.now += 2
    assert get(cache, fetch) == [podcast(1)]
    assert fetch.calls == 2


def test_full_answer_is_still_held_hours() -> None:
    clock = Clock()
    cache = TopCache(clock=clock)
    fetch = Answers([podcast(1)], [podcast(2)])
    get(cache, fetch)
    clock.now += podcast_catalog.FRESH_S - 1
    assert get(cache, fetch) == [podcast(1)]
    assert fetch.calls == 1


def test_empty_answer_does_not_replace_recent_full_one() -> None:
    clock = Clock()
    cache = TopCache(clock=clock)
    fetch = Answers([podcast(1)], [], [podcast(3)])
    get(cache, fetch)
    clock.now += podcast_catalog.FRESH_S + 1  # full response is stale, but younger than STALE_S
    assert get(cache, fetch) == [podcast(1)]  # empty response — old full list
    assert fetch.calls == 2
    clock.now += (
        podcast_catalog.EMPTY_FRESH_S + 1
    )  # after minutes we ask again, not after hours
    assert get(cache, fetch) == [podcast(3)]
    assert fetch.calls == 3


def test_empty_answer_after_stale_limit_is_shown_empty() -> None:
    clock = Clock()
    cache = TopCache(clock=clock)
    fetch = Answers([podcast(1)], [])
    get(cache, fetch)
    clock.now += podcast_catalog.STALE_S + 1
    assert get(cache, fetch) == []


def test_unavailable_after_empty_hold_still_raises_without_full_copy() -> None:
    clock = Clock()
    cache = TopCache(clock=clock)
    fetch = Answers([], None)
    assert get(cache, fetch) == []
    clock.now += podcast_catalog.EMPTY_FRESH_S + 1
    # empty response is not a "fallback list": unavailability is honestly visible
    with pytest.raises(PodcastSearchUnavailable):
        get(cache, fetch)


def test_unavailable_keeps_serving_full_copy() -> None:
    clock = Clock()
    cache = TopCache(clock=clock)
    fetch = Answers([podcast(1)], None)
    get(cache, fetch)
    clock.now += podcast_catalog.FRESH_S + 1
    assert get(cache, fetch) == [podcast(1)]


def test_keys_do_not_share_empty_hold() -> None:
    clock = Clock()
    cache = TopCache(clock=clock)
    empty, full = Answers([]), Answers([podcast(7)])
    assert get(cache, empty, ("ru", 1533)) == []
    assert get(cache, full, ("ru", 1487)) == [podcast(7)]


def test_crawl_logger_is_the_configured_one() -> None:
    assert podcast_wiring.logger.name in LOGGING_CONFIG["loggers"]
    assert podcast_wiring.logger.name == "apertonodo"


def test_crawl_lines_are_written_under_apertonodo(
    caplog: pytest.LogCaptureFixture,
) -> None:
    caplog.set_level(logging.INFO, logger="apertonodo")
    podcast_wiring.logger.info("podcasts: crawl saved=%d", 3)
    assert any(
        r.name == "apertonodo" and "crawl saved=3" in r.getMessage()
        for r in caplog.records
    )


def test_eviction_keeps_both_maps_bounded_and_drops_fallback(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(podcast_catalog, "MAX_KEYS", 2)
    clock = Clock()
    cache = TopCache(clock=clock)
    get(cache, Answers([podcast(1)]), ("ru", 1))
    get(cache, Answers([podcast(2)]), ("ru", 2))
    get(cache, Answers([podcast(3)]), ("ru", 3))  # evicts ("ru", 1)
    assert len(cache._entries) == 2
    assert len(cache._full) == 2
    clock.now += podcast_catalog.FRESH_S + 1
    with pytest.raises(
        PodcastSearchUnavailable
    ):  # evicted key has no fallback list
        get(cache, Answers(None), ("ru", 1))


def test_empty_answer_path_is_also_bounded(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(podcast_catalog, "MAX_KEYS", 2)
    clock = Clock()
    cache = TopCache(clock=clock)
    get(cache, Answers([podcast(1)]), ("ru", 1))
    get(cache, Answers([podcast(2)]), ("ru", 2))
    clock.now += podcast_catalog.FRESH_S + 1
    get(cache, Answers([]), ("ru", 1))  # empty response while full copy is alive
    get(cache, Answers([podcast(3)]), ("ru", 3))
    assert len(cache._entries) <= 2
    assert set(cache._full) <= set(cache._entries)
