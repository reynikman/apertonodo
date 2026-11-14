"""FT-657 (R-A93, block B-5): podcast feeds, episodes, and subscriptions in database.

Feed parser (FT-654) yields values; here they are stored in database. Subscription is
personal and stores feed URL, not a foreign key to feed row: personal copy
can be restored even on a server where feeds do not exist yet — feed will be fetched automatically.
Feed and its episodes are shared across all subscribers.

Contract of `app/podcasts.py` module:
- `normalize_feed_url(raw) -> str | None` — unified URL form for comparison;
- `subscribe(conn, user_id, feed_url, *, now=None) -> "ok" | "exists" | "limit" | "bad_url"`;
- `unsubscribe(conn, user_id, feed_url) -> bool`;
- `subscriptions(conn, user_id) -> list[Subscription]`;
- `episodes(conn, user_id, feed_url, *, limit=50, offset=0) -> list[StoredEpisode] | None`;
- `save_feed(conn, feed_url, podcast, *, now=None) -> bool`;
- `mark_failed(conn, feed_url, *, now=None)`;
- `due(conn, *, now=None, limit=20) -> list[str]`;
- `purge_orphans(conn) -> int`;
- `backoff(failures) -> timedelta`; constants `MAX_SUBSCRIPTIONS = 500`,
  `MAX_STORED_EPISODES = 2000`, `REFRESH_EVERY = 1 hour`,
  `BACKOFF = (1 h, 3 h, 12 h, 24 h)`.

What tests do not prove: that someone fetches the feed (crawler is next
card), that endpoints exist (wired by lead), and that playback position
is stored on server (separate card).
"""

from __future__ import annotations

import asyncio
import dataclasses
import logging
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any
from uuid import UUID

import asyncpg
import pytest

from app import podcasts
from app.migrate import apply
from app.podcast_feed import Episode, Podcast
from app.podcasts import (
    BACKOFF,
    MAX_STORED_EPISODES,
    MAX_SUBSCRIPTIONS,
    REFRESH_EVERY,
    StoredEpisode,
    Subscription,
    backoff,
    due,
    episodes,
    mark_failed,
    normalize_feed_url,
    purge_orphans,
    save_feed,
    subscribe,
    subscriptions,
    unsubscribe,
)

NOW = datetime(2026, 10, 7, 12, 0, tzinfo=UTC)
ANN = UUID("aaaaaaaa-0000-4000-8000-000000000001")
BOB = UUID("bbbbbbbb-0000-4000-8000-000000000002")
FEED = "https://pod.example.org/feed.xml"
OTHER = "https://other.example.org/rss"


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
        for user, name in ((ANN, "ann-ft657"), (BOB, "bob-ft657")):
            await conn.execute(
                "INSERT INTO users (id, username) VALUES ($1, $2) ON CONFLICT (id) DO NOTHING",
                user,
                name,
            )

    _run(postgres_url, prepare)
    return postgres_url


def ep(n: int, *, day: int | None = None, **over: Any) -> Episode:
    values: dict[str, Any] = {
        "guid": f"g{n}",
        "title": f"Выпуск {n}",
        "description": f"Описание {n}",
        "audio_url": f"https://cdn.example.org/{n}.mp3",
        "audio_type": "audio/mpeg",
        "audio_bytes": 1000 + n,
        "duration_ms": 60_000 * n if n else None,
        "published": datetime(2026, 9, day, tzinfo=UTC) if day else None,
        "image": None,
        "season": None,
        "number": n or None,
        "explicit": False,
    }
    values.update(over)
    return Episode(**values)


def pod(*eps: Episode, title: str = "Подкаст", **over: Any) -> Podcast:
    values: dict[str, Any] = {
        "title": title,
        "author": "Автор",
        "description": "О чём",
        "image": "https://cdn.example.org/cover.jpg",
        "link": "https://site.example.org",
        "episodes": list(eps),
    }
    values.update(over)
    return Podcast(**values)


# --- feed URL ---


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("https://pod.example.org/feed.xml", "https://pod.example.org/feed.xml"),
        ("  https://pod.example.org/feed.xml \n", "https://pod.example.org/feed.xml"),
        ("HTTPS://Pod.Example.ORG/Feed.xml", "https://pod.example.org/Feed.xml"),
        ("https://pod.example.org:443/feed.xml", "https://pod.example.org/feed.xml"),
        ("http://pod.example.org:80/feed.xml", "http://pod.example.org/feed.xml"),
        (
            "https://pod.example.org:8443/feed.xml",
            "https://pod.example.org:8443/feed.xml",
        ),
        ("https://pod.example.org", "https://pod.example.org/"),
        ("https://pod.example.org/feed.xml#top", "https://pod.example.org/feed.xml"),
        (
            "https://pod.example.org/feed?id=7&b=2",
            "https://pod.example.org/feed?id=7&b=2",
        ),
        ("http://[2001:DB8::1]:8080/f", "http://[2001:db8::1]:8080/f"),
    ],
)
def test_feed_url_has_one_form(raw: str, expected: str) -> None:
    assert normalize_feed_url(raw) == expected
    assert normalize_feed_url(expected) == expected


@pytest.mark.parametrize(
    "raw",
    [
        "",
        "   ",
        None,
        7,
        b"https://pod.example.org/feed.xml",
        "pod.example.org/feed.xml",
        "ftp://pod.example.org/feed.xml",
        "file:///etc/passwd",
        "https:///feed.xml",
        "https://user:pass@pod.example.org/feed.xml",
        "https://user@pod.example.org/feed.xml",
        "https://pod.example.org/a b.xml",
        "https://pod.example.org/a\tb.xml",
        "https://pod.example.org/a\x00b.xml",
        "https://pod.example.org/‮b.xml",
        "https://pod.example.org:99999/feed.xml",
        "https://pod.example.org:port/feed.xml",
        "https://[::1/feed.xml",
        "https://pod.example.org/" + "a" * 2100,
    ],
)
def test_bad_feed_url_is_none(raw: Any) -> None:
    assert normalize_feed_url(raw) is None


def test_http_and_https_are_different_feeds() -> None:
    assert normalize_feed_url("http://pod.example.org/f") != normalize_feed_url(
        "https://pod.example.org/f"
    )


# --- subscription ---


def test_subscribe_and_list_before_the_feed_is_fetched(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        assert await subscribe(conn, ANN, FEED, now=NOW) == "ok"
        assert await subscriptions(conn, ANN) == [
            Subscription(
                feed_url=FEED,
                title=None,
                author="",
                image=None,
                episodes=0,
                newest_at=None,
                added_at=NOW,
            )
        ]
        assert await subscriptions(conn, BOB) == []

    _run(base, work)


def test_subscribe_twice_is_one_subscription_in_any_spelling(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        assert await subscribe(conn, ANN, FEED, now=NOW) == "ok"
        later = NOW + timedelta(days=1)
        assert await subscribe(
            conn, ANN, "HTTPS://POD.example.org:443/feed.xml#x", now=later
        ) == ("exists")
        [only] = await subscriptions(conn, ANN)
        assert only.added_at == NOW

    _run(base, work)


def test_subscription_is_stored_in_the_one_form(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        assert (
            await subscribe(
                conn, ANN, " HTTPS://POD.example.org:443/feed.xml#x ", now=NOW
            )
            == "ok"
        )
        [only] = await subscriptions(conn, ANN)
        assert only.feed_url == FEED
        assert await subscribe(conn, ANN, FEED, now=NOW) == "exists"
        await save_feed(conn, FEED, pod(ep(1, day=3)), now=NOW)
        [shown] = await subscriptions(conn, ANN)
        assert (shown.title, shown.episodes) == ("Подкаст", 1)

    _run(base, work)


def test_bad_url_is_not_subscribed(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        assert (
            await subscribe(conn, ANN, "ftp://pod.example.org/f", now=NOW) == "bad_url"
        )
        assert await conn.fetchval("SELECT count(*) FROM podcast_subscriptions") == 0

    _run(base, work)


def test_subscription_limit_per_person(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await conn.executemany(
            "INSERT INTO podcast_subscriptions (user_id, feed_url, added_at) VALUES ($1, $2, $3)",
            [
                (ANN, f"https://p{n}.example.org/f", NOW)
                for n in range(MAX_SUBSCRIPTIONS - 1)
            ],
        )
        assert await subscribe(conn, ANN, FEED, now=NOW) == "ok"
        assert await subscribe(conn, ANN, OTHER, now=NOW) == "limit"
        # Re-adding an existing one is not a "limit" violation.
        assert await subscribe(conn, ANN, FEED, now=NOW) == "exists"
        # Each user has their own limit.
        assert await subscribe(conn, BOB, OTHER, now=NOW) == "ok"
        assert await conn.fetchval(
            "SELECT count(*) FROM podcast_subscriptions WHERE user_id = $1", ANN
        ) == (MAX_SUBSCRIPTIONS)

    _run(base, work)


def test_two_subscribes_at_once_do_not_pass_the_limit(base: str) -> None:
    async def go() -> None:
        first = await asyncpg.connect(base)
        second = await asyncpg.connect(base)
        try:
            await first.executemany(
                "INSERT INTO podcast_subscriptions (user_id, feed_url, added_at)"
                " VALUES ($1, $2, $3)",
                [
                    (ANN, f"https://p{n}.example.org/f", NOW)
                    for n in range(MAX_SUBSCRIPTIONS - 1)
                ],
            )
            for attempt in range(5):
                await first.execute(
                    "DELETE FROM podcast_subscriptions WHERE feed_url = ANY($1::text[])",
                    [FEED, OTHER],
                )
                got = await asyncio.gather(
                    subscribe(first, ANN, FEED, now=NOW),
                    subscribe(second, ANN, OTHER, now=NOW),
                )
                assert sorted(got) == ["limit", "ok"], attempt
                assert await first.fetchval(
                    "SELECT count(*) FROM podcast_subscriptions WHERE user_id = $1", ANN
                ) == (MAX_SUBSCRIPTIONS)
        finally:
            await first.close()
            await second.close()

    asyncio.run(go())


def test_same_feed_at_once_is_one_row_and_no_error(base: str) -> None:
    async def go() -> None:
        first = await asyncpg.connect(base)
        second = await asyncpg.connect(base)
        try:
            for attempt in range(5):
                await first.execute("TRUNCATE podcast_subscriptions")
                got = await asyncio.gather(
                    subscribe(first, ANN, FEED, now=NOW),
                    subscribe(second, ANN, FEED, now=NOW),
                )
                assert sorted(got) == ["exists", "ok"], attempt
        finally:
            await first.close()
            await second.close()

    asyncio.run(go())


def test_unsubscribe_is_mine_only(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await subscribe(conn, ANN, FEED, now=NOW)
        await subscribe(conn, BOB, FEED, now=NOW)
        assert await unsubscribe(conn, ANN, "HTTPS://pod.example.org/feed.xml") is True
        assert await unsubscribe(conn, ANN, FEED) is False
        assert await unsubscribe(conn, ANN, "not a url") is False
        assert await subscriptions(conn, ANN) == []
        assert [s.feed_url for s in await subscriptions(conn, BOB)] == [FEED]

    _run(base, work)


def test_deleted_person_takes_subscriptions_along(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        gone = UUID("cccccccc-0000-4000-8000-000000000003")
        await conn.execute(
            "INSERT INTO users (id, username) VALUES ($1, 'gone-ft657')", gone
        )
        await subscribe(conn, gone, FEED, now=NOW)
        await conn.execute("DELETE FROM users WHERE id = $1", gone)
        assert await conn.fetchval("SELECT count(*) FROM podcast_subscriptions") == 0

    _run(base, work)


# --- feed and episodes ---


def test_save_feed_and_read_back(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await subscribe(conn, ANN, FEED, now=NOW)
        first = ep(
            1, day=1, image="https://cdn.example.org/e1.jpg", season=2, explicit=True
        )
        assert await save_feed(conn, FEED, pod(ep(2, day=2), first), now=NOW) is True
        [sub] = await subscriptions(conn, ANN)
        assert sub == Subscription(
            feed_url=FEED,
            title="Подкаст",
            author="Автор",
            image="https://cdn.example.org/cover.jpg",
            episodes=2,
            newest_at=datetime(2026, 9, 2, tzinfo=UTC),
            added_at=NOW,
        )
        got = await episodes(conn, ANN, FEED)
        assert got is not None
        assert [e.guid for e in got] == ["g2", "g1"]
        assert got[1] == StoredEpisode(
            guid="g1",
            title="Выпуск 1",
            description="Описание 1",
            audio_url="https://cdn.example.org/1.mp3",
            audio_type="audio/mpeg",
            audio_bytes=1001,
            duration_ms=60_000,
            published=datetime(2026, 9, 1, tzinfo=UTC),
            image="https://cdn.example.org/e1.jpg",
            season=2,
            number=1,
            explicit=True,
        )
        row = await conn.fetchrow(
            "SELECT * FROM podcast_feeds WHERE feed_url = $1", FEED
        )
        assert row["description"] == "О чём"
        assert row["link"] == "https://site.example.org"
        assert row["fetched_at"] == NOW
        assert row["failures"] == 0
        assert row["next_fetch_at"] == NOW + REFRESH_EVERY

    _run(base, work)


def test_save_feed_under_any_spelling_is_one_feed(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await save_feed(
            conn, "HTTPS://POD.example.org:443/feed.xml#a", pod(ep(1, day=1)), now=NOW
        )
        await save_feed(conn, FEED, pod(ep(1, day=1)), now=NOW)
        assert await conn.fetchval("SELECT count(*) FROM podcast_feeds") == 1
        assert await conn.fetchval("SELECT feed_url FROM podcast_feeds") == FEED
        assert await save_feed(conn, "ftp://x.example.org/f", pod(), now=NOW) is False
        assert await conn.fetchval("SELECT count(*) FROM podcast_feeds") == 1

    _run(base, work)


def test_episodes_only_for_a_subscriber(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await save_feed(conn, FEED, pod(ep(1, day=1)), now=NOW)
        assert await episodes(conn, ANN, FEED) is None
        await subscribe(conn, BOB, FEED, now=NOW)
        assert await episodes(conn, ANN, FEED) is None
        assert await episodes(conn, ANN, "not a url") is None
        got = await episodes(conn, BOB, "HTTPS://pod.example.org/feed.xml")
        assert got is not None and len(got) == 1
        # Subscribed, but feed not yet fetched — empty list, not "no subscription".
        await subscribe(conn, ANN, OTHER, now=NOW)
        assert await episodes(conn, ANN, OTHER) == []

    _run(base, work)


def test_order_newest_first_undated_last_in_feed_order(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await subscribe(conn, ANN, FEED, now=NOW)
        feed = pod(ep(5, day=3), ep(4, day=3), ep(9, day=7), ep(7), ep(6), ep(1, day=1))
        await save_feed(conn, FEED, feed, now=NOW)
        got = await episodes(conn, ANN, FEED)
        assert got is not None
        assert [e.guid for e in got] == ["g9", "g5", "g4", "g1", "g7", "g6"]

    _run(base, work)


def test_pages(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await subscribe(conn, ANN, FEED, now=NOW)
        await save_feed(conn, FEED, pod(*[ep(n, day=n) for n in range(1, 8)]), now=NOW)

        async def page(**kw: Any) -> list[str]:
            got = await episodes(conn, ANN, FEED, **kw)
            assert got is not None
            return [e.guid for e in got]

        assert await page(limit=3) == ["g7", "g6", "g5"]
        assert await page(limit=3, offset=3) == ["g4", "g3", "g2"]
        assert await page(limit=3, offset=6) == ["g1"]
        assert await page(limit=3, offset=70) == []
        assert await page(limit=0) == ["g7"]
        assert await page(limit=-5, offset=-5) == ["g7"]
        assert len(await page()) == 7

    _run(base, work)


def test_page_is_bounded(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await subscribe(conn, ANN, FEED, now=NOW)
        many = [ep(n, published=NOW - timedelta(hours=n)) for n in range(1, 260)]
        await save_feed(conn, FEED, pod(*many), now=NOW)
        got = await episodes(conn, ANN, FEED, limit=100_000)
        assert got is not None and len(got) == 200
        default = await episodes(conn, ANN, FEED)
        assert default is not None and len(default) == 50

    _run(base, work)


def test_refresh_updates_and_keeps_what_left_the_feed(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await subscribe(conn, ANN, FEED, now=NOW)
        await save_feed(conn, FEED, pod(ep(2, day=2), ep(1, day=1)), now=NOW)
        later = NOW + timedelta(hours=2)
        changed = ep(
            2, day=2, title="Исправлено", audio_url="https://cdn.example.org/2b.mp3"
        )
        await save_feed(
            conn,
            FEED,
            pod(ep(3, day=3), changed, title="Новое имя", image=None),
            now=later,
        )
        got = await episodes(conn, ANN, FEED)
        assert got is not None
        # g1 was removed from feed, but retained: playback position may be set on it.
        assert [(e.guid, e.title) for e in got] == [
            ("g3", "Выпуск 3"),
            ("g2", "Исправлено"),
            ("g1", "Выпуск 1"),
        ]
        assert got[1].audio_url == "https://cdn.example.org/2b.mp3"
        [sub] = await subscriptions(conn, ANN)
        assert (sub.title, sub.image, sub.episodes) == ("Новое имя", None, 3)
        seen = dict(
            await conn.fetch(
                "SELECT guid, first_seen_at FROM podcast_episodes ORDER BY guid"
            )
        )
        assert seen == {"g1": NOW, "g2": NOW, "g3": later}
        row = await conn.fetchrow("SELECT * FROM podcast_feeds")
        assert (row["fetched_at"], row["next_fetch_at"]) == (
            later,
            later + REFRESH_EVERY,
        )

    _run(base, work)


def test_undated_episodes_that_left_the_feed_go_after_current_ones(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await subscribe(conn, ANN, FEED, now=NOW)
        await save_feed(conn, FEED, pod(ep(1), ep(2)), now=NOW)
        await save_feed(conn, FEED, pod(ep(3), ep(4)), now=NOW + timedelta(hours=1))
        await save_feed(conn, FEED, pod(ep(5), ep(3)), now=NOW + timedelta(hours=2))
        got = await episodes(conn, ANN, FEED)
        assert got is not None
        current, gone = [e.guid for e in got[:2]], sorted(e.guid for e in got[2:])
        assert current == ["g5", "g3"]
        assert gone == ["g1", "g2", "g4"]

    _run(base, work)


def test_empty_feed_keeps_old_episodes(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await subscribe(conn, ANN, FEED, now=NOW)
        await save_feed(conn, FEED, pod(ep(1, day=1)), now=NOW)
        assert await save_feed(conn, FEED, pod(), now=NOW + timedelta(hours=1)) is True
        got = await episodes(conn, ANN, FEED)
        assert got is not None and [e.guid for e in got] == ["g1"]

    _run(base, work)


def test_stored_episodes_are_bounded_oldest_go(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await subscribe(conn, ANN, FEED, now=NOW)
        start = datetime(2020, 1, 1, tzinfo=UTC)
        old = [
            ep(n, published=start + timedelta(days=n))
            for n in range(MAX_STORED_EPISODES)
        ]
        await save_feed(conn, FEED, pod(*reversed(old)), now=NOW)
        fresh = [
            ep(n, published=start + timedelta(days=n))
            for n in range(MAX_STORED_EPISODES, MAX_STORED_EPISODES + 30)
        ]
        await save_feed(conn, FEED, pod(*reversed(fresh)), now=NOW + timedelta(hours=1))
        assert (
            await conn.fetchval("SELECT count(*) FROM podcast_episodes")
            == MAX_STORED_EPISODES
        )
        left = {
            r["guid"] for r in await conn.fetch("SELECT guid FROM podcast_episodes")
        }
        assert {f"g{n}" for n in range(30)}.isdisjoint(left)
        assert {f"g{n}" for n in range(30, MAX_STORED_EPISODES + 30)} == left

    _run(base, work)


def test_longer_feed_than_the_bound_is_cut(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        many = [ep(n) for n in range(MAX_STORED_EPISODES + 5)]
        await save_feed(conn, FEED, pod(*many), now=NOW)
        assert (
            await conn.fetchval("SELECT count(*) FROM podcast_episodes")
            == MAX_STORED_EPISODES
        )
        assert await conn.fetchval(
            "SELECT count(*) FROM podcast_episodes WHERE guid = $1",
            f"g{MAX_STORED_EPISODES}",
        ) == (0)

    _run(base, work)


def test_dated_feed_longer_than_the_bound_keeps_its_first_part(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        start = datetime(2020, 1, 1, tzinfo=UTC)
        many = [
            ep(n, published=start + timedelta(days=n))
            for n in range(MAX_STORED_EPISODES + 5)
        ]
        await save_feed(conn, FEED, pod(*many), now=NOW)
        left = {
            r["guid"] for r in await conn.fetch("SELECT guid FROM podcast_episodes")
        }
        assert left == {f"g{n}" for n in range(MAX_STORED_EPISODES)}

    _run(base, work)


def test_saving_one_feed_leaves_the_other_alone(base: str) -> None:
    async def rows(conn: asyncpg.Connection) -> list[tuple[Any, ...]]:
        return [
            tuple(r.values())
            for r in await conn.fetch(
                "SELECT * FROM podcast_episodes WHERE feed_url = $1 ORDER BY guid",
                OTHER,
            )
        ]

    async def work(conn: asyncpg.Connection) -> None:
        start = datetime(2020, 1, 1, tzinfo=UTC)
        # Another feed has the same episode GUIDs that will be evicted from this one.
        await save_feed(conn, OTHER, pod(ep(0), ep(1), ep(2, day=5)), now=NOW)
        before = await rows(conn)
        assert len(before) == 3
        old = [
            ep(n, published=start + timedelta(days=n))
            for n in range(MAX_STORED_EPISODES)
        ]
        await save_feed(conn, FEED, pod(*reversed(old)), now=NOW)
        fresh = [
            ep(n, published=start + timedelta(days=n))
            for n in range(MAX_STORED_EPISODES, MAX_STORED_EPISODES + 30)
        ]
        await save_feed(conn, FEED, pod(*reversed(fresh)), now=NOW + timedelta(hours=1))
        assert await rows(conn) == before

    _run(base, work)


def test_file_size_over_two_gigabytes_is_stored(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await subscribe(conn, ANN, FEED, now=NOW)
        await save_feed(conn, FEED, pod(ep(1, audio_bytes=5 * 1024**3)), now=NOW)
        page = await episodes(conn, ANN, FEED)
        assert page is not None
        assert page[0].audio_bytes == 5 * 1024**3

    _run(base, work)


def test_save_is_all_or_nothing(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await save_feed(conn, FEED, pod(ep(1, day=1), title="Старое"), now=NOW)
        broken = ep(2, day=2, audio_bytes=2**70)
        with pytest.raises((asyncpg.PostgresError, asyncpg.DataError, OverflowError)):
            await save_feed(
                conn, FEED, pod(ep(3, day=3), broken, title="Новое"), now=NOW
            )
        assert await conn.fetchval("SELECT title FROM podcast_feeds") == "Старое"
        assert [
            r["guid"] for r in await conn.fetch("SELECT guid FROM podcast_episodes")
        ] == ["g1"]

    _run(base, work)


def test_big_feed_is_saved_fast(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        many = [
            ep(n, published=NOW - timedelta(hours=n))
            for n in range(MAX_STORED_EPISODES)
        ]
        started = asyncio.get_running_loop().time()
        await save_feed(conn, FEED, pod(*many), now=NOW)
        await save_feed(conn, FEED, pod(*many), now=NOW + timedelta(hours=1))
        assert asyncio.get_running_loop().time() - started < 20

    _run(base, work)


def test_feeds_of_two_people_are_shared_but_lists_are_not(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await subscribe(conn, ANN, FEED, now=NOW)
        await subscribe(conn, BOB, FEED, now=NOW + timedelta(minutes=1))
        await subscribe(conn, BOB, OTHER, now=NOW)
        await save_feed(conn, FEED, pod(ep(1, day=1)), now=NOW)
        await save_feed(conn, OTHER, pod(ep(1, day=9), title="Другой"), now=NOW)
        assert [s.title for s in await subscriptions(conn, ANN)] == ["Подкаст"]
        assert [s.title for s in await subscriptions(conn, BOB)] == [
            "Другой",
            "Подкаст",
        ]
        # Same guid in two feeds — two episodes.
        assert await conn.fetchval("SELECT count(*) FROM podcast_episodes") == 2

    _run(base, work)


def test_list_order_fresh_episodes_first_then_unfetched_by_time(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        feeds = [f"https://p{n}.example.org/f" for n in range(5)]
        for n, feed in enumerate(feeds):
            await subscribe(conn, ANN, feed, now=NOW + timedelta(minutes=n))
        await save_feed(conn, feeds[0], pod(ep(1, day=5), title="A"), now=NOW)
        await save_feed(conn, feeds[1], pod(ep(1, day=9), title="B"), now=NOW)
        await save_feed(conn, feeds[2], pod(ep(1), title="C"), now=NOW)
        got = [s.feed_url for s in await subscriptions(conn, ANN)]
        assert got == [feeds[1], feeds[0], feeds[4], feeds[3], feeds[2]]

    _run(base, work)


# --- crawling ---


def test_due_new_subscription_first_then_oldest(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        a, b, c, d = (f"https://p{n}.example.org/f" for n in range(4))
        for feed in (a, b, c):
            await subscribe(conn, ANN, feed, now=NOW)
        await subscribe(conn, BOB, a, now=NOW)
        await save_feed(conn, a, pod(), now=NOW - timedelta(hours=3))
        await save_feed(conn, b, pod(), now=NOW - timedelta(hours=5))
        # d was fetched, but nobody is subscribed to it.
        await save_feed(conn, d, pod(), now=NOW - timedelta(hours=9))
        assert await due(conn, now=NOW) == [c, b, a]
        assert await due(conn, now=NOW, limit=2) == [c, b]
        assert await due(conn, now=NOW, limit=0) == [c]
        await save_feed(conn, c, pod(), now=NOW)
        assert await due(conn, now=NOW) == [b, a]
        # Exactly on time — due; one second before — not due.
        at = NOW - timedelta(hours=3) + REFRESH_EVERY
        assert a in await due(conn, now=at)
        assert a not in await due(conn, now=at - timedelta(seconds=1))

    _run(base, work)


def test_due_is_bounded(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await conn.executemany(
            "INSERT INTO podcast_subscriptions (user_id, feed_url, added_at) VALUES ($1, $2, $3)",
            [(ANN, f"https://p{n:03}.example.org/f", NOW) for n in range(130)],
        )
        assert len(await due(conn, now=NOW, limit=10_000)) == 100
        assert len(await due(conn, now=NOW)) == 20

    _run(base, work)


def test_backoff_steps() -> None:
    assert BACKOFF == (
        timedelta(hours=1),
        timedelta(hours=3),
        timedelta(hours=12),
        timedelta(hours=24),
    )
    assert [backoff(n) for n in (1, 2, 3, 4, 5, 1000)] == [
        *BACKOFF,
        BACKOFF[-1],
        BACKOFF[-1],
    ]
    assert backoff(0) == BACKOFF[0]
    assert backoff(-3) == BACKOFF[0]


def test_failures_back_off_and_success_resets(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await subscribe(conn, ANN, FEED, now=NOW)
        await save_feed(conn, FEED, pod(ep(1, day=1)), now=NOW)
        at = NOW
        for n, step in enumerate(BACKOFF, start=1):
            await mark_failed(conn, FEED, now=at)
            row = await conn.fetchrow("SELECT * FROM podcast_feeds")
            assert (row["failures"], row["next_fetch_at"]) == (n, at + step)
            assert await due(conn, now=at + step - timedelta(seconds=1)) == []
            assert await due(conn, now=at + step) == [FEED]
            at += step
        await mark_failed(conn, FEED, now=at)
        assert (await conn.fetchval("SELECT next_fetch_at FROM podcast_feeds")) == (
            at + BACKOFF[-1]
        )
        # Failure does not alter already fetched content.
        got = await episodes(conn, ANN, FEED)
        assert got is not None and len(got) == 1
        assert await conn.fetchval("SELECT title FROM podcast_feeds") == "Подкаст"
        assert await conn.fetchval("SELECT fetched_at FROM podcast_feeds") == NOW
        await save_feed(conn, FEED, pod(ep(1, day=1)), now=at)
        row = await conn.fetchrow("SELECT * FROM podcast_feeds")
        assert (row["failures"], row["next_fetch_at"]) == (0, at + REFRESH_EVERY)

    _run(base, work)


def test_failure_of_a_never_fetched_feed_is_remembered(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await subscribe(conn, ANN, FEED, now=NOW)
        await mark_failed(conn, "HTTPS://pod.example.org/feed.xml", now=NOW)
        assert await due(conn, now=NOW + timedelta(minutes=59)) == []
        assert await due(conn, now=NOW + BACKOFF[0]) == [FEED]
        await mark_failed(conn, FEED, now=NOW + BACKOFF[0])
        assert await conn.fetchval("SELECT failures FROM podcast_feeds") == 2
        # A feed never fetched is in list without title, not with empty string.
        [sub] = await subscriptions(conn, ANN)
        assert sub.title is None
        assert sub.episodes == 0
        await mark_failed(conn, "not a url", now=NOW)
        assert await conn.fetchval("SELECT count(*) FROM podcast_feeds") == 1

    _run(base, work)


def test_purge_orphans_keeps_subscribed(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await subscribe(conn, ANN, FEED, now=NOW)
        await save_feed(conn, FEED, pod(ep(1, day=1)), now=NOW)
        await save_feed(conn, OTHER, pod(ep(1, day=1), ep(2, day=2)), now=NOW)
        assert await purge_orphans(conn) == 1
        assert await conn.fetchval("SELECT count(*) FROM podcast_feeds") == 1
        assert await conn.fetchval("SELECT count(*) FROM podcast_episodes") == 1
        assert await purge_orphans(conn) == 0
        await unsubscribe(conn, ANN, FEED)
        assert await purge_orphans(conn) == 1
        assert await conn.fetchval("SELECT count(*) FROM podcast_episodes") == 0

    _run(base, work)


# --- contract and privacy ---


def test_values_are_frozen() -> None:
    assert [f.name for f in dataclasses.fields(Subscription)] == [
        "feed_url",
        "title",
        "author",
        "image",
        "episodes",
        "newest_at",
        "added_at",
        "language",
    ]
    assert [f.name for f in dataclasses.fields(StoredEpisode)] == [
        f.name for f in dataclasses.fields(Episode)
    ]
    sub = Subscription(FEED, None, "", None, 0, None, NOW)
    with pytest.raises(dataclasses.FrozenInstanceError):
        sub.title = "x"  # type: ignore[misc]


def test_nothing_is_logged(base: str, caplog: pytest.LogCaptureFixture) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await subscribe(conn, ANN, FEED, now=NOW)
        await save_feed(conn, FEED, pod(ep(1, day=1), title="Тайное название"), now=NOW)
        await mark_failed(conn, FEED, now=NOW)
        await subscriptions(conn, ANN)
        await episodes(conn, ANN, FEED)
        await due(conn, now=NOW)
        await purge_orphans(conn)

    with caplog.at_level(logging.DEBUG):
        _run(base, work)
    text = caplog.text
    assert "Тайное" not in text
    assert "pod.example.org" not in text


def test_module_stays_out_of_network_and_shared_files() -> None:
    source = Path(podcasts.__file__).read_text(encoding="utf-8")
    for word in ("httpx", "import os", "logging", "print(", "app.main", "news_fetch"):
        assert word not in source, word


def test_migration_is_safe_to_repeat(base: str) -> None:
    asyncio.run(apply(base))
    asyncio.run(apply(base))

    async def work(conn: asyncpg.Connection) -> None:
        cols = {
            r["column_name"]
            for r in await conn.fetch(
                "SELECT column_name FROM information_schema.columns"
                " WHERE table_name = 'podcast_subscriptions'"
            )
        }
        assert cols == {"user_id", "feed_url", "added_at"}
        # Subscription does not reference feed row: personal copy survives without shared tables.
        fks = await conn.fetch(
            """
            SELECT confrelid::regclass::text AS target FROM pg_constraint
            WHERE conrelid = 'podcast_subscriptions'::regclass AND contype = 'f'
            """
        )
        assert [r["target"] for r in fks] == ["users"]

    _run(base, work)


# --- second look: long key must not crash insertion ---


def _noise(count: int, *, wide: bool) -> str:
    import random

    rnd = random.Random(657)
    if wide:
        return "".join(chr(rnd.randrange(0x4E00, 0x9FA5)) for _ in range(count))
    return "".join(
        rnd.choice("abcdefghijklmnopqrstuvwxyz0123456789") for _ in range(count)
    )


def test_feed_url_is_bounded_in_bytes_not_characters() -> None:
    assert normalize_feed_url("https://pod.example.org/" + _noise(900, wide=False))
    assert (
        normalize_feed_url("https://pod.example.org/" + _noise(1100, wide=False))
        is None
    )
    assert (
        normalize_feed_url("https://pod.example.org/" + _noise(600, wide=True)) is None
    )


def test_longest_url_with_longest_guid_is_saved(base: str) -> None:
    feed = "https://pod.example.org/" + _noise(990, wide=False)
    wide_guid = _noise(1000, wide=True)

    async def work(conn: asyncpg.Connection) -> None:
        assert await subscribe(conn, ANN, feed, now=NOW) == "ok"
        saved = await save_feed(
            conn,
            feed,
            pod(
                ep(1, day=1),
                ep(2, day=2, guid=wide_guid),
                ep(3, day=3, guid=_noise(1000, wide=False)),
            ),
            now=NOW,
        )
        assert saved is True
        page = await episodes(conn, ANN, feed)
        assert page is not None
        # Episode whose GUID does not fit into index key is skipped; rest remain.
        assert [e.title for e in page] == ["Выпуск 3", "Выпуск 1"]

    _run(base, work)
