"""FT-729 (draft Pd-2 server + Pd-5): episodes "from the first" and new episodes of subscriptions.

Episodes are served in pages of 50, so "from the first episode" cannot be obtained
by reversing the page on the phone: the first page from the other end is needed.
"New episodes" is a combined feed across all user subscriptions for top of section.

Contract of `app/podcast_new.py` module:
- `episodes_ordered(conn, user_id, feed_url, *, order, limit=50, offset=0)
  -> list[StoredEpisode] | None` — `order` from `ORDERS = ("newest", "oldest")`,
  other value — `ValueError`; `None` — user not subscribed (like
  `podcasts.episodes`); `newest` yields exact same as `podcasts.episodes`;
  `oldest` — from the oldest, undated episodes at the end; pages without duplicates;
  `limit` clamped to 1…200, `offset` clamped to minimum 0.
- `new_episodes(conn, user_id, *, since, limit=30) -> list[NewEpisode]` —
  episodes from user subscriptions with date strictly after `since` (`None` — without
  lower bound), newest first, at most `PER_FEED = 3` per podcast,
  undated episodes excluded; `limit` clamped to 1…`MAX_NEW = 100`.
  `NewEpisode` — all `StoredEpisode` fields plus `feed_url` and `feed_title`.
- Module writes nothing to logs (episode titles and feed URLs are private).

What tests do not prove: that `/v1/podcasts/…` endpoints exist (wired by lead)
and that phone UI displays this.
"""

from __future__ import annotations

import asyncio
import dataclasses
import logging
from datetime import UTC, datetime, timedelta
from typing import Any
from uuid import UUID

import asyncpg
import pytest

from app import podcast_new
from app.migrate import apply
from app.podcast_feed import Episode, Podcast
from app.podcast_new import (
    MAX_NEW,
    ORDERS,
    PER_FEED,
    NewEpisode,
    episodes_ordered,
    new_episodes,
)
from app.podcasts import StoredEpisode, episodes, save_feed, subscribe

NOW = datetime(2026, 10, 10, 12, 0, tzinfo=UTC)
ANN = UUID("aaaaaaaa-0000-4000-8000-000000000729")
BOB = UUID("bbbbbbbb-0000-4000-8000-000000000729")
FEED = "https://pod.example.org/feed.xml"
OTHER = "https://other.example.org/rss"
THIRD = "https://third.example.org/rss"


def _run(url: str, work: Any) -> Any:
    async def go() -> Any:
        conn = await asyncpg.connect(url)
        try:
            return await work(conn)
        finally:
            await conn.close()

    return asyncio.run(go())


@pytest.fixture
def base(postgres_url: str) -> str:
    asyncio.run(apply(postgres_url))

    async def prepare(conn: asyncpg.Connection) -> None:
        await conn.execute(
            "TRUNCATE podcast_subscriptions, podcast_episodes, podcast_feeds"
        )
        for user, name in ((ANN, "ann-ft729"), (BOB, "bob-ft729")):
            await conn.execute(
                "INSERT INTO users (id, username) VALUES ($1, $2) ON CONFLICT (id) DO NOTHING",
                user,
                name,
            )

    _run(postgres_url, prepare)
    return postgres_url


def ep(n: int, *, at: datetime | None) -> Episode:
    return Episode(
        guid=f"g{n}",
        title=f"Выпуск {n}",
        description=f"Описание {n}",
        audio_url=f"https://cdn.example.org/{n}.mp3",
        audio_type="audio/mpeg",
        audio_bytes=1000 + n,
        duration_ms=60_000 * (n + 1),
        published=at,
        image=None,
        season=None,
        number=n,
        explicit=False,
    )


def day(n: int) -> datetime:
    return datetime(2026, 9, 1, tzinfo=UTC) + timedelta(days=n)


def pod(*eps: Episode, title: str = "Подкаст") -> Podcast:
    return Podcast(
        title=title,
        author="Автор",
        description="О чём",
        image="https://cdn.example.org/cover.jpg",
        link=None,
        episodes=list(eps),
    )


def store(url: str, feed: str, podcast: Podcast, *users: UUID) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        assert await save_feed(conn, feed, podcast, now=NOW)
        for user in users:
            assert await subscribe(conn, user, feed, now=NOW) == "ok"

    _run(url, work)


def guids(items: list[Any]) -> list[str]:
    return [e.guid for e in items]


# --- episode order ---


def test_orders_constant() -> None:
    assert ORDERS == ("newest", "oldest")


def test_oldest_starts_from_the_first_episode(base: str) -> None:
    store(base, FEED, pod(*(ep(n, at=day(n)) for n in range(1, 8))), ANN)
    got = _run(base, lambda c: episodes_ordered(c, ANN, FEED, order="oldest", limit=3))
    assert guids(got) == ["g1", "g2", "g3"]


def test_newest_matches_existing_episodes(base: str) -> None:
    eps = [ep(n, at=day(n)) for n in range(1, 8)] + [ep(9, at=None), ep(8, at=day(3))]
    store(base, FEED, pod(*eps), ANN)

    async def work(conn: asyncpg.Connection) -> tuple[list[Any], list[Any]]:
        mine = await episodes_ordered(conn, ANN, FEED, order="newest", limit=50)
        old = await episodes(conn, ANN, FEED, limit=50)
        return mine, old

    mine, old = _run(base, work)
    assert mine == old
    assert all(type(e) is StoredEpisode for e in mine)


def test_oldest_puts_undated_last(base: str) -> None:
    store(base, FEED, pod(ep(5, at=None), ep(2, at=day(2)), ep(1, at=day(1))), ANN)
    got = _run(base, lambda c: episodes_ordered(c, ANN, FEED, order="oldest"))
    assert guids(got) == ["g1", "g2", "g5"]


def test_oldest_pages_without_duplicates(base: str) -> None:
    # Three episodes on same day: page must neither lose nor duplicate them.
    eps = [ep(n, at=day(n // 3)) for n in range(1, 31)]
    store(base, FEED, pod(*eps), ANN)

    async def work(conn: asyncpg.Connection) -> list[str]:
        seen: list[str] = []
        for offset in range(0, 30, 7):
            page = await episodes_ordered(
                conn, ANN, FEED, order="oldest", limit=7, offset=offset
            )
            assert page is not None
            seen += guids(page)
        return seen

    seen = _run(base, work)
    assert len(seen) == 30
    assert len(set(seen)) == 30
    days = {f"g{n}": n // 3 for n in range(1, 31)}
    assert [days[g] for g in seen] == sorted(days[g] for g in seen)


def test_oldest_is_reverse_of_newest_for_dated(base: str) -> None:
    eps = [ep(n, at=day(n % 5)) for n in range(1, 16)]
    store(base, FEED, pod(*eps), ANN)

    async def work(conn: asyncpg.Connection) -> tuple[list[str], list[str]]:
        new = await episodes_ordered(conn, ANN, FEED, order="newest", limit=200)
        old = await episodes_ordered(conn, ANN, FEED, order="oldest", limit=200)
        return guids(new), guids(old)

    new, old = _run(base, work)
    assert old == list(reversed(new))


def test_not_subscribed_is_none(base: str) -> None:
    store(base, FEED, pod(ep(1, at=day(1))), ANN)
    for order in ORDERS:
        got = _run(base, lambda c, o=order: episodes_ordered(c, BOB, FEED, order=o))
        assert got is None


def test_bad_feed_url_is_none(base: str) -> None:
    got = _run(base, lambda c: episodes_ordered(c, ANN, "not a url", order="oldest"))
    assert got is None


@pytest.mark.parametrize("order", ["asc", "", "OLDEST", "desc"])
def test_unknown_order_raises(base: str, order: str) -> None:
    store(base, FEED, pod(ep(1, at=day(1))), ANN)
    with pytest.raises(ValueError):
        _run(base, lambda c: episodes_ordered(c, ANN, FEED, order=order))


def test_limit_and_offset_are_clamped(base: str) -> None:
    store(base, FEED, pod(*(ep(n, at=day(n)) for n in range(1, 6))), ANN)

    async def work(conn: asyncpg.Connection) -> tuple[list[str], list[str]]:
        zero = await episodes_ordered(conn, ANN, FEED, order="oldest", limit=0)
        neg = await episodes_ordered(
            conn, ANN, FEED, order="oldest", limit=2, offset=-5
        )
        return guids(zero), guids(neg)

    zero, neg = _run(base, work)
    assert zero == ["g1"]
    assert neg == ["g1", "g2"]


# --- new episodes of subscriptions ---


def test_no_subscriptions_is_empty(base: str) -> None:
    store(base, FEED, pod(ep(1, at=day(1))), BOB)
    assert _run(base, lambda c: new_episodes(c, ANN, since=None)) == []


def test_subscription_without_episodes_is_empty(base: str) -> None:
    store(base, FEED, pod(), ANN)
    assert _run(base, lambda c: new_episodes(c, ANN, since=None)) == []


def test_new_across_feeds_newest_first_with_feed_fields(base: str) -> None:
    store(base, FEED, pod(ep(1, at=day(1)), ep(4, at=day(4)), title="Первый"), ANN)
    store(base, OTHER, pod(ep(2, at=day(2)), ep(3, at=day(3)), title="Второй"), ANN)
    got = _run(base, lambda c: new_episodes(c, ANN, since=None))
    assert [(e.feed_url, e.guid) for e in got] == [
        (FEED, "g4"),
        (OTHER, "g3"),
        (OTHER, "g2"),
        (FEED, "g1"),
    ]
    assert all(type(e) is NewEpisode for e in got)
    assert got[0].feed_title == "Первый"
    assert got[1].feed_title == "Второй"
    assert got[0].title == "Выпуск 4"
    assert got[0].audio_url == "https://cdn.example.org/4.mp3"
    assert got[0].duration_ms == 300_000


def test_new_episode_has_all_stored_fields() -> None:
    stored = {f.name for f in dataclasses.fields(StoredEpisode)}
    new = {f.name for f in dataclasses.fields(NewEpisode)}
    assert stored | {"feed_url", "feed_title"} == new


def test_since_is_strict(base: str) -> None:
    store(base, FEED, pod(*(ep(n, at=day(n)) for n in range(1, 6))), ANN)
    got = _run(base, lambda c: new_episodes(c, ANN, since=day(3)))
    assert guids(got) == ["g5", "g4"]


def test_since_in_future_is_empty(base: str) -> None:
    store(base, FEED, pod(*(ep(n, at=day(n)) for n in range(1, 6))), ANN)
    got = _run(base, lambda c: new_episodes(c, ANN, since=NOW + timedelta(days=365)))
    assert got == []


def test_undated_episodes_are_not_new(base: str) -> None:
    store(base, FEED, pod(ep(1, at=None), ep(2, at=day(2))), ANN)
    got = _run(base, lambda c: new_episodes(c, ANN, since=None))
    assert guids(got) == ["g2"]


def test_at_most_per_feed_from_one_podcast(base: str) -> None:
    assert PER_FEED == 3
    store(base, FEED, pod(*(ep(n, at=day(10 + n)) for n in range(1, 11))), ANN)
    store(base, OTHER, pod(ep(50, at=day(1))), ANN)
    got = _run(base, lambda c: new_episodes(c, ANN, since=None))
    assert [(e.feed_url, e.guid) for e in got] == [
        (FEED, "g10"),
        (FEED, "g9"),
        (FEED, "g8"),
        (OTHER, "g50"),
    ]


def test_other_peoples_subscriptions_are_hidden(base: str) -> None:
    store(base, FEED, pod(ep(1, at=day(1))), ANN)
    store(base, OTHER, pod(ep(2, at=day(2))), BOB)
    got = _run(base, lambda c: new_episodes(c, ANN, since=None))
    assert [e.feed_url for e in got] == [FEED]


def test_limit_is_clamped(base: str) -> None:
    assert MAX_NEW == 100
    for i in range(40):
        feed = f"https://f{i}.example.org/rss"
        store(
            base,
            feed,
            pod(*(ep(n, at=day(n) + timedelta(minutes=i)) for n in range(1, 4))),
            ANN,
        )

    async def work(conn: asyncpg.Connection) -> tuple[int, int, int, int]:
        default = await new_episodes(conn, ANN, since=None)
        zero = await new_episodes(conn, ANN, since=None, limit=0)
        big = await new_episodes(conn, ANN, since=None, limit=10_000)
        five = await new_episodes(conn, ANN, since=None, limit=5)
        return len(default), len(zero), len(big), len(five)

    assert _run(base, work) == (30, 1, MAX_NEW, 5)


def test_many_subscriptions_one_query(base: str) -> None:
    feeds = [f"https://m{i}.example.org/rss" for i in range(200)]
    for i, feed in enumerate(feeds):
        store(base, feed, pod(ep(i, at=day(1) + timedelta(minutes=i))), ANN)

    class Counting:
        """Connection that counts queries to the database."""

        def __init__(self, conn: asyncpg.Connection) -> None:
            self.conn = conn
            self.calls = 0

        def __getattr__(self, name: str) -> Any:
            real = getattr(self.conn, name)
            if name not in ("fetch", "fetchrow", "fetchval", "execute", "executemany"):
                return real

            async def counted(*args: Any, **kwargs: Any) -> Any:
                self.calls += 1
                return await real(*args, **kwargs)

            return counted

    async def work(conn: asyncpg.Connection) -> tuple[list[Any], int]:
        counting = Counting(conn)
        got = await new_episodes(counting, ANN, since=None, limit=100)  # type: ignore[arg-type]
        return got, counting.calls

    got, calls = _run(base, work)
    assert calls == 1
    assert len(got) == 100
    assert got[0].feed_url == feeds[-1]


def test_module_writes_nothing_to_log(
    base: str, caplog: pytest.LogCaptureFixture
) -> None:
    store(base, FEED, pod(ep(1, at=day(1)), title="Секретный подкаст"), ANN)
    caplog.set_level(logging.DEBUG)

    async def work(conn: asyncpg.Connection) -> None:
        await new_episodes(conn, ANN, since=None)
        await episodes_ordered(conn, ANN, FEED, order="oldest")

    _run(base, work)
    assert not [r for r in caplog.records if r.name.startswith(podcast_new.__name__)]
    assert "Секретный" not in caplog.text
    assert FEED not in caplog.text
