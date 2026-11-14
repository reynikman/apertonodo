"""FT-658 (R-A93, block B-5): podcast episode playback position on server.

The phone tracks position locally (FT-656) and sends it in batches; server stores one
record per episode and serves it to other devices of the same user. Between two
records for the same episode, the newer one wins — by same rule as on
phone. Record is personal and stores feed URL and episode GUID, not references:
progress survives unsubscribe and episode removal from feed.

Contract of `app/podcast_progress.py` module:
- `Progress(position_ms, done, updated_at)`, `Entry(feed_url, guid, progress)` — immutable;
- `newer(a, b) -> Progress`;
- `from_wire(raw) -> list[Entry] | None`, `to_wire(entries) -> dict`;
- `put(conn, user_id, entries, *, now=None) -> list[Entry]`;
- `changes(conn, user_id, *, after=0, limit=500) -> (list[Entry], int)`;
- `of_feed(conn, user_id, feed_url) -> dict[str, Progress]`;
- constants `MAX_BATCH = 500`, `MAX_ROWS = 20_000`,
  `MAX_POSITION_MS = 7 days`, `FUTURE_SLACK = 5 minutes`.

What tests do not prove: that endpoints exist (wired by lead), that phone
sends and applies response (subsequent cards), that podcast speed is stored
on server (not stored — it lives on phone).
"""

from __future__ import annotations

import asyncio
import dataclasses
import json
import logging
from datetime import UTC, datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from uuid import UUID

import asyncpg
import pytest

from app import podcast_progress
from app.migrate import apply
from app.podcast_progress import (
    FUTURE_SLACK,
    MAX_BATCH,
    MAX_POSITION_MS,
    MAX_ROWS,
    Entry,
    Progress,
    changes,
    from_wire,
    newer,
    of_feed,
    put,
    to_wire,
)

NOW = datetime(2026, 10, 7, 12, 0, tzinfo=UTC)
ANN = UUID("aaaaaaaa-0000-4000-8000-000000000001")
BOB = UUID("bbbbbbbb-0000-4000-8000-000000000002")
GONE = UUID("cccccccc-0000-4000-8000-000000000003")
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
        await conn.execute("TRUNCATE podcast_progress")
        for user, name in ((ANN, "ann-ft658"), (BOB, "bob-ft658")):
            await conn.execute(
                "INSERT INTO users (id, username) VALUES ($1, $2) ON CONFLICT (id) DO NOTHING",
                user,
                name,
            )

    _run(postgres_url, prepare)
    return postgres_url


def at(ms: int, *, done: bool = False, minute: int = 0) -> Progress:
    return Progress(ms, done, NOW - timedelta(hours=1) + timedelta(minutes=minute))


def entry(guid: str, ms: int, *, feed: str = FEED, **kw: Any) -> Entry:
    return Entry(feed, guid, at(ms, **kw))


def wire(**over: Any) -> dict[str, Any]:
    item: dict[str, Any] = {
        "feed_url": FEED,
        "guid": "ep-1",
        "position_ms": 60_000,
        "done": False,
        "updated_at": "2026-10-07T11:00:00.000Z",
    }
    item.update(over)
    return item


# --- which record is newer (same rule as on phone) ---


def test_later_wins() -> None:
    old, new = at(900_000, done=True, minute=0), at(5, minute=1)
    assert newer(old, new) is new
    assert newer(new, old) is new


def test_same_time_done_wins_then_bigger_position_then_first() -> None:
    assert newer(at(900), at(5, done=True)) == at(5, done=True)
    assert newer(at(5, done=True), at(900)) == at(5, done=True)
    assert newer(at(5), at(900)) == at(900)
    assert newer(at(900), at(5)) == at(900)
    a, b = at(7), at(7)
    assert newer(a, b) is a


def test_time_is_compared_as_a_moment() -> None:
    msk = timezone(timedelta(hours=3))
    same = Progress(5, False, datetime(2026, 10, 7, 14, 0, tzinfo=msk))
    assert newer(at(9), same) == at(9)
    later = Progress(5, False, datetime(2026, 10, 7, 14, 1, tzinfo=msk))
    assert newer(at(9), later) is later


# --- wire: what phone sent ---


def test_wire_round_trip_matches_the_phone() -> None:
    [e] = from_wire({"items": [wire()]}) or []
    assert e == Entry(
        FEED, "ep-1", Progress(60_000, False, datetime(2026, 10, 7, 11, tzinfo=UTC))
    )
    assert to_wire([e]) == {"items": [wire()]}
    json.dumps(to_wire([e]))


def test_wire_time_is_utc_with_z_and_milliseconds() -> None:
    msk = timezone(timedelta(hours=3))
    e = Entry(
        FEED, "g", Progress(1, True, datetime(2026, 10, 7, 14, 0, 0, 123456, msk))
    )
    assert to_wire([e])["items"][0]["updated_at"] == "2026-10-07T11:00:00.123Z"  # type: ignore[index]


@pytest.mark.parametrize(
    "raw",
    [None, [], "x", 5, {}, {"items": None}, {"items": {}}, {"items": "ab"}],
)
def test_wire_not_a_batch_is_none(raw: Any) -> None:
    assert from_wire(raw) is None


def test_wire_empty_batch_is_empty() -> None:
    assert from_wire({"items": []}) == []


def test_wire_batch_is_bounded() -> None:
    assert len(
        from_wire({"items": [wire(guid=f"g{n}") for n in range(MAX_BATCH)]}) or []
    ) == (MAX_BATCH)
    assert from_wire({"items": [wire()] * (MAX_BATCH + 1)}) is None


@pytest.mark.parametrize(
    "bad",
    [
        None,
        "x",
        [],
        wire(feed_url=""),
        wire(feed_url=None),
        wire(feed_url=7),
        wire(feed_url="h" * 1025),
        wire(feed_url="https://pod.example.org/" + "ж" * 501),
        wire(feed_url="https://pod.example.org/a\nb"),
        wire(feed_url="https://pod.example.org/\x00"),
        wire(feed_url="https://pod.example.org/\ud800"),
        wire(guid=""),
        wire(guid=None),
        wire(guid=7),
        wire(guid="g" * 1025),
        wire(guid="家" * 342),
        wire(guid="a\x07b"),
        wire(position_ms=-1),
        wire(position_ms=MAX_POSITION_MS + 1),
        wire(position_ms=1.0),
        wire(position_ms="5"),
        wire(position_ms=True),
        wire(position_ms=None),
        wire(done=1),
        wire(done="true"),
        wire(done=None),
        wire(updated_at=None),
        wire(updated_at=1791370800),
        wire(updated_at=""),
        wire(updated_at="вчера"),
        wire(updated_at="2026-10-07T11:00:00"),
        wire(updated_at="2026-10-07T11:00:00+03:00"),
        wire(updated_at="2026-10-07T11:00:00.0001"),
        wire(updated_at="2026-10-07T11:00:00." + "0" * 40 + "Z"),
        wire(updated_at="1999-12-31T23:59:59Z"),
        wire(updated_at="2026-13-45T11:00:00Z"),
        wire(updated_at="2026-10-07T11:00:00" + "0" * 40 + "Z"),
    ],
)
def test_wire_bad_item_is_skipped_and_the_rest_stays(bad: Any) -> None:
    got = from_wire({"items": [wire(guid="first"), bad, wire(guid="last")]})
    assert [e.guid for e in got or []] == ["first", "last"]


def test_wire_bounds_are_inclusive() -> None:
    got = from_wire(
        {
            "items": [
                wire(feed_url="h" * 1024, guid="家" * 341, position_ms=MAX_POSITION_MS),
                wire(position_ms=0, done=True, updated_at="2000-01-01T00:00:00Z"),
            ]
        }
    )
    assert got is not None and len(got) == 2
    assert MAX_POSITION_MS == 7 * 24 * 3600 * 1000


def test_wire_guid_may_be_any_printable_text() -> None:
    [e] = (
        from_wire({"items": [wire(guid="Выпуск №5 — «Ёж» 🎙 tag:x,2026:/a?b=c")]}) or []
    )
    assert e.guid == "Выпуск №5 — «Ёж» 🎙 tag:x,2026:/a?b=c"


# --- write and read ---


def test_put_and_read_back(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        stored = await put(conn, ANN, [entry("b", 2000), entry("a", 1000)], now=NOW)
        assert stored == [entry("a", 1000), entry("b", 2000)]
        assert await of_feed(conn, ANN, FEED) == {"a": at(1000), "b": at(2000)}
        assert await of_feed(conn, ANN, OTHER) == {}

    _run(base, work)


def test_older_report_does_not_win_and_the_answer_is_what_is_stored(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await put(conn, ANN, [entry("a", 900_000, minute=10)], now=NOW)
        answer = await put(conn, ANN, [entry("a", 5, minute=3)], now=NOW)
        assert answer == [entry("a", 900_000, minute=10)]
        assert (await of_feed(conn, ANN, FEED))["a"] == at(900_000, minute=10)
        answer = await put(conn, ANN, [entry("a", 7, minute=11)], now=NOW)
        assert answer == [entry("a", 7, minute=11)]

    _run(base, work)


def test_same_time_done_wins_then_bigger_position_in_the_database(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await put(conn, ANN, [entry("a", 900)], now=NOW)
        await put(conn, ANN, [entry("a", 5, done=True)], now=NOW)
        assert (await of_feed(conn, ANN, FEED))["a"] == at(5, done=True)
        await put(conn, ANN, [entry("a", 900)], now=NOW)
        assert (await of_feed(conn, ANN, FEED))["a"] == at(5, done=True)
        await put(conn, ANN, [entry("b", 5)], now=NOW)
        await put(conn, ANN, [entry("b", 900)], now=NOW)
        await put(conn, ANN, [entry("b", 5)], now=NOW)
        assert (await of_feed(conn, ANN, FEED))["b"] == at(900)

    _run(base, work)


def test_the_same_report_again_is_not_a_change(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await put(conn, ANN, [entry("a", 5)], now=NOW)
        _, mark = await changes(conn, ANN)
        assert await put(conn, ANN, [entry("a", 5)], now=NOW) == [entry("a", 5)]
        assert await changes(conn, ANN, after=mark) == ([], mark)

    _run(base, work)


def test_answer_has_only_what_was_sent(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await put(conn, ANN, [entry("a", 1, feed=OTHER), entry("b", 2)], now=NOW)
        assert await put(conn, ANN, [entry("a", 3)], now=NOW) == [entry("a", 3)]

    _run(base, work)


def test_same_episode_twice_in_one_batch_is_one_row_newest_kept(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        answer = await put(
            conn,
            ANN,
            [entry("a", 5, minute=2), entry("a", 9, minute=7), entry("a", 7, minute=4)],
            now=NOW,
        )
        assert answer == [entry("a", 9, minute=7)]
        assert await conn.fetchval("SELECT count(*) FROM podcast_progress") == 1

    _run(base, work)


def test_same_guid_in_two_feeds_is_two_episodes(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await put(conn, ANN, [entry("a", 5), entry("a", 9, feed=OTHER)], now=NOW)
        assert (await of_feed(conn, ANN, FEED))["a"].position_ms == 5
        assert (await of_feed(conn, ANN, OTHER))["a"].position_ms == 9

    _run(base, work)


def test_each_person_has_their_own(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await put(conn, ANN, [entry("a", 5, minute=1)], now=NOW)
        answer = await put(conn, BOB, [entry("a", 9, minute=0)], now=NOW)
        assert answer == [entry("a", 9, minute=0)]
        assert (await of_feed(conn, ANN, FEED))["a"].position_ms == 5
        assert (await of_feed(conn, BOB, FEED))["a"].position_ms == 9
        got, _ = await changes(conn, BOB)
        assert got == [entry("a", 9, minute=0)]

    _run(base, work)


def test_empty_batch_and_unknown_person_write_nothing(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        assert await put(conn, ANN, [], now=NOW) == []
        assert await put(conn, GONE, [entry("a", 5)], now=NOW) == []
        assert await conn.fetchval("SELECT count(*) FROM podcast_progress") == 0

    _run(base, work)


def test_deleted_person_takes_progress_along(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await conn.execute(
            "INSERT INTO users (id, username) VALUES ($1, 'gone-ft658')", GONE
        )
        await put(conn, GONE, [entry("a", 5)], now=NOW)
        await put(conn, ANN, [entry("a", 5)], now=NOW)
        await conn.execute("DELETE FROM users WHERE id = $1", GONE)
        assert await conn.fetchval("SELECT count(*) FROM podcast_progress") == 1

    _run(base, work)


def test_time_from_the_future_becomes_now(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        far = Progress(5, False, datetime(2099, 1, 1, tzinfo=UTC))
        [stored] = await put(conn, ANN, [Entry(FEED, "a", far)], now=NOW)
        assert stored.progress == Progress(5, False, NOW)
        # Honest report after a minute wins.
        fair = Progress(9, False, NOW + timedelta(minutes=1))
        [stored] = await put(
            conn, ANN, [Entry(FEED, "a", fair)], now=NOW + timedelta(minutes=1)
        )
        assert stored.progress == fair

    _run(base, work)


def test_small_clock_drift_is_kept_as_is(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        edge = Progress(5, False, NOW + FUTURE_SLACK)
        over = Progress(5, False, NOW + FUTURE_SLACK + timedelta(seconds=1))
        stored = await put(
            conn, ANN, [Entry(FEED, "a", edge), Entry(FEED, "b", over)], now=NOW
        )
        assert [e.progress.updated_at for e in stored] == [NOW + FUTURE_SLACK, NOW]
        assert timedelta(minutes=5) == FUTURE_SLACK

    _run(base, work)


def test_time_without_zone_is_not_stored(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        naive = Progress(5, False, datetime(2026, 10, 7, 11, 0))
        assert await put(conn, ANN, [Entry(FEED, "a", naive)], now=NOW) == []
        assert await conn.fetchval("SELECT count(*) FROM podcast_progress") == 0

    _run(base, work)


def test_batch_over_the_bound_is_refused_whole(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        many = [entry(f"g{n}", n) for n in range(MAX_BATCH + 1)]
        with pytest.raises(ValueError, match="too_many"):
            await put(conn, ANN, many, now=NOW)
        assert await conn.fetchval("SELECT count(*) FROM podcast_progress") == 0
        assert len(await put(conn, ANN, many[:MAX_BATCH], now=NOW)) == MAX_BATCH

    _run(base, work)


def test_full_batch_is_saved_fast(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        many = [entry(f"g{n}", n) for n in range(MAX_BATCH)]
        started = asyncio.get_running_loop().time()
        await put(conn, ANN, many, now=NOW)
        await put(conn, ANN, many, now=NOW)
        assert asyncio.get_running_loop().time() - started < 2.0

    _run(base, work)


# --- "what changed since last time" ---


def test_changes_go_in_order_and_resume_from_the_mark(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        assert await changes(conn, ANN) == ([], 0)
        assert await changes(conn, ANN, after=41) == ([], 41)
        await put(conn, ANN, [entry("a", 1)], now=NOW)
        await put(conn, ANN, [entry("b", 2)], now=NOW)
        first, mark = await changes(conn, ANN)
        assert [e.guid for e in first] == ["a", "b"]
        assert mark > 0
        assert await changes(conn, ANN, after=mark) == ([], mark)
        await put(conn, ANN, [entry("a", 3, minute=5)], now=NOW)
        second, mark2 = await changes(conn, ANN, after=mark)
        assert second == [entry("a", 3, minute=5)]
        assert mark2 > mark
        # A record that didn't win is not counted as a change.
        await put(conn, ANN, [entry("b", 1, minute=-30)], now=NOW)
        assert await changes(conn, ANN, after=mark2) == ([], mark2)

    _run(base, work)


def test_changes_come_in_pages(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await put(conn, ANN, [entry(f"g{n}", n) for n in range(7)], now=NOW)
        seen: list[str] = []
        mark = 0
        for _ in range(4):
            page, mark = await changes(conn, ANN, after=mark, limit=3)
            assert len(page) <= 3
            seen += [e.guid for e in page]
        assert sorted(seen) == [f"g{n}" for n in range(7)]
        assert len(seen) == 7

    _run(base, work)


def test_pages_follow_the_order_of_arrival_not_the_phone_clock(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await put(conn, ANN, [entry("late-clock", 1, minute=50)], now=NOW)
        await put(conn, ANN, [entry("early-clock", 2, minute=1)], now=NOW)
        first, mark = await changes(conn, ANN, limit=1)
        second, mark = await changes(conn, ANN, after=mark, limit=1)
        assert [e.guid for e in first + second] == ["late-clock", "early-clock"]
        assert await changes(conn, ANN, after=mark) == ([], mark)

    _run(base, work)


def test_changes_page_is_bounded(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        for part in range(3):
            await put(
                conn,
                ANN,
                [entry(f"g{part}-{n}", n) for n in range(MAX_BATCH)],
                now=NOW,
            )
        assert len((await changes(conn, ANN, limit=10**9))[0]) == 1000
        assert len((await changes(conn, ANN, limit=0))[0]) == 1
        assert len((await changes(conn, ANN, limit=-5))[0]) == 1
        assert len((await changes(conn, ANN))[0]) == 500
        assert len((await changes(conn, ANN, after=-7, limit=2))[0]) == 2
        assert await changes(conn, ANN, after=10**30) == ([], 2**63 - 1)

    _run(base, work)


def test_two_writers_at_once_lose_nothing_for_the_reader(base: str) -> None:
    """Change sequence increments in commit order: until first record of a user
    is committed, second receives no sequence number."""

    async def work(conn: asyncpg.Connection) -> None:
        slow = await asyncpg.connect(base)
        try:
            tx = slow.transaction()
            await tx.start()
            await put(slow, ANN, [entry("slow", 1)], now=NOW)
            fast = asyncio.create_task(put(conn, ANN, [entry("fast", 2)], now=NOW))
            await asyncio.sleep(0.3)
            assert not fast.done()
            await tx.commit()
            await fast
        finally:
            await slow.close()
        got, _ = await changes(conn, ANN)
        assert [e.guid for e in got] == ["slow", "fast"]

    _run(base, work)


def test_other_person_is_not_held_up(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        slow = await asyncpg.connect(base)
        try:
            tx = slow.transaction()
            await tx.start()
            await put(slow, ANN, [entry("a", 1)], now=NOW)
            await asyncio.wait_for(put(conn, BOB, [entry("a", 2)], now=NOW), 2)
            await tx.rollback()
        finally:
            await slow.close()

    _run(base, work)


def test_same_episode_from_two_phones_at_once_keeps_the_newest(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        other = await asyncpg.connect(base)
        try:
            await asyncio.gather(
                put(conn, ANN, [entry("a", 5, minute=1)], now=NOW),
                put(other, ANN, [entry("a", 9, minute=2)], now=NOW),
            )
        finally:
            await other.close()
        assert (await of_feed(conn, ANN, FEED))["a"] == at(9, minute=2)

    _run(base, work)


# --- volume ---


def test_rows_per_person_are_bounded_oldest_go(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await conn.execute(
            """
            INSERT INTO podcast_progress
                (user_id, feed_url, guid, position_ms, done, updated_at, seq)
            SELECT $1, $2, 'old' || n, n, false, $3::timestamptz - n * interval '1 minute',
                   nextval('podcast_progress_seq')
            FROM generate_series(1, $4) AS n
            """,
            ANN,
            FEED,
            NOW - timedelta(days=1),
            MAX_ROWS,
        )
        # Another user has the same episode that will be evicted for this one.
        old = Progress(1, False, NOW - timedelta(days=30))
        await put(conn, BOB, [Entry(FEED, f"old{MAX_ROWS}", old)], now=NOW)
        answer = await put(conn, ANN, [entry("new1", 1), entry("new2", 2)], now=NOW)
        assert [e.guid for e in answer] == ["new1", "new2"]
        assert (
            await conn.fetchval(
                "SELECT count(*) FROM podcast_progress WHERE user_id = $1", ANN
            )
            == MAX_ROWS
        )
        left = await of_feed(conn, ANN, FEED)
        assert f"old{MAX_ROWS}" not in left
        assert f"old{MAX_ROWS - 1}" not in left
        assert f"old{MAX_ROWS - 2}" in left
        assert "old1" in left
        assert await of_feed(conn, BOB, FEED) == {f"old{MAX_ROWS}": old}

    _run(base, work)


# --- contract ---


def test_values_are_frozen() -> None:
    p = at(5)
    with pytest.raises(dataclasses.FrozenInstanceError):
        p.position_ms = 6  # type: ignore[misc]
    e = entry("a", 5)
    with pytest.raises(dataclasses.FrozenInstanceError):
        e.guid = "b"  # type: ignore[misc]


def test_nothing_is_logged(base: str, caplog: pytest.LogCaptureFixture) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await put(conn, ANN, [entry("secret-guid", 5)], now=NOW)
        await changes(conn, ANN)
        await of_feed(conn, ANN, FEED)

    with caplog.at_level(logging.DEBUG):
        from_wire({"items": [wire(guid="secret-guid"), wire(done=7)]})
        _run(base, work)
    assert not [r for r in caplog.records if r.name.startswith("app.podcast_progress")]
    assert "secret-guid" not in caplog.text
    assert "pod.example.org" not in caplog.text


def test_module_stays_out_of_network_and_shared_files() -> None:
    src = Path(podcast_progress.__file__).read_text(encoding="utf-8")
    for word in (
        "httpx",
        "logging",
        "print(",
        "app.main",
        "app.library",
        "app.podcasts",
    ):
        assert word not in src


def test_migration_is_safe_to_repeat(base: str) -> None:
    sql = (
        Path(__file__).resolve().parents[1] / "migrations" / "054_podcast_progress.sql"
    ).read_text(encoding="utf-8")

    async def work(conn: asyncpg.Connection) -> None:
        await put(conn, ANN, [entry("a", 5)], now=NOW)
        await conn.execute(sql)
        await conn.execute(sql)
        assert await conn.fetchval("SELECT count(*) FROM podcast_progress") == 1
        with pytest.raises(asyncpg.CheckViolationError):
            await conn.execute(
                "INSERT INTO podcast_progress VALUES ($1, 'f', 'g', -1, false, now(), 1)",
                ANN,
            )

    _run(base, work)


# --- acceptance: second look and lead review ---


def _noise(count: int, *, wide: bool) -> str:
    import random

    rnd = random.Random(658)
    if wide:
        return "".join(chr(rnd.randrange(0x4E00, 0x9FA5)) for _ in range(count))
    return "".join(
        rnd.choice("abcdefghijklmnopqrstuvwxyz0123456789") for _ in range(count)
    )


def test_longest_keys_fit_the_index(base: str) -> None:
    """URL and guid are index key, index limit is 2704 bytes; incompressible key must succeed."""
    feed = "https://pod.example.org/" + _noise(1000, wide=False)
    guid = _noise(341, wide=True)
    got = from_wire({"items": [wire(feed_url=feed, guid=guid)]})
    assert got is not None and len(got) == 1

    async def work(conn: asyncpg.Connection) -> None:
        stored = await put(conn, ANN, got, now=NOW)
        assert len(stored) == 1
        assert list(await of_feed(conn, ANN, feed)) == [guid]

    _run(base, work)


def test_put_does_not_wait_for_a_writer_of_the_same_person(base: str) -> None:
    """Writing progress does not wait on adjacent record holding reference to user (listen, subscription)."""

    async def go() -> None:
        other = await asyncpg.connect(base)
        conn = await asyncpg.connect(base)
        try:
            tx = other.transaction()
            await tx.start()
            await other.execute("SELECT 1 FROM users WHERE id = $1 FOR KEY SHARE", ANN)
            stored = await asyncio.wait_for(
                put(conn, ANN, [entry("a", 1000)], now=NOW), 5
            )
            assert stored == [entry("a", 1000)]
            await tx.rollback()
        finally:
            await conn.close()
            await other.close()

    asyncio.run(go())


def test_wire_guid_with_odd_spaces_is_kept() -> None:
    """Non-breaking space, zero-width joiner, and ideographic space in episode guid are not reasons to lose progress."""
    for guid in ("Выпуск\u00a05", "a\u200db", "第\u30005話"):
        [e] = from_wire({"items": [wire(guid=guid)]}) or []
        assert e.guid == guid
