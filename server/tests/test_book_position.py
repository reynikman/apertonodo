"""FT-673 (R-A99, contract D5): resume position in audiobook on server.

Phone stores position locally (FT-670) and sends it here in batches; server stores one
entry per book per user and serves it to other devices of the same user. Between
two records for the same book, the newer one wins — by the same rule as on
the phone. The record is personal, survives removing book from shelf, and is only
dropped together with the user or with the book itself.

Contract of module `app/book_position.py`:
- `Position(part, position_ms, finished, updated_at)`, `Entry(book_id, position)` — immutable;
- `newer(a, b) -> Position`;
- `from_wire(raw) -> list[Entry] | None`, `to_wire(entries) -> dict`;
- `put(conn, user_id, entries, *, now=None) -> list[Entry]`;
- `changes(conn, user_id, *, after=0, limit=500) -> (list[Entry], int)`;
- `of_books(conn, user_id, book_ids) -> dict[UUID, Position]`;
- constants `MAX_BATCH = 500`, `MAX_ROWS = 5000`, `MAX_PART = 3000`,
  `MAX_POSITION_MS = 30 days`, `FUTURE_SLACK = 5 minutes`.

What tests do not prove: that endpoints exist (wiring by lead), that phone
sends and applies response (subsequent cards), that book playback speed is stored on
server (it is not stored — it lives on the phone).
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

from app import book_position
from app.book_position import (
    FUTURE_SLACK,
    MAX_BATCH,
    MAX_PART,
    MAX_POSITION_MS,
    MAX_ROWS,
    Entry,
    Position,
    changes,
    from_wire,
    newer,
    of_books,
    put,
    to_wire,
)
from app.migrate import apply

NOW = datetime(2026, 10, 7, 12, 0, tzinfo=UTC)
ANN = UUID("aaaaaaaa-0000-4000-8000-000000000001")
BOB = UUID("bbbbbbbb-0000-4000-8000-000000000002")
GONE = UUID("cccccccc-0000-4000-8000-000000000003")
NO_BOOK = UUID("dddddddd-0000-4000-8000-00000000dead")


def book(n: int) -> UUID:
    """Book number `n`; the larger `n`, the further it is in numerical order."""
    return UUID(f"00000000-0000-4000-8000-{n:012d}")


A, B, C = book(1), book(2), book(3)


def _run(url: str, work: Any) -> Any:
    async def go() -> Any:
        conn = await asyncpg.connect(url)
        try:
            return await work(conn)
        finally:
            await conn.close()

    return asyncio.run(go())


async def _add_books(conn: asyncpg.Connection, first: int, last: int) -> None:
    await conn.execute(
        """
        INSERT INTO books (id, asset_key, asset_hint, title, total_bytes, part_count, added_at)
        SELECT ('00000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
               'bt:' || lpad(to_hex(n), 40, '0'), 'hint-' || n, 'Book ' || n, 1000, 3, $3
        FROM generate_series($1::int, $2::int) AS n
        ON CONFLICT DO NOTHING
        """,
        first,
        last,
        NOW,
    )


@pytest.fixture
def base(postgres_url: str) -> str:
    asyncio.run(apply(postgres_url))

    async def prepare(conn: asyncpg.Connection) -> None:
        await conn.execute("TRUNCATE books CASCADE")
        for user, name in ((ANN, "ann-ft673"), (BOB, "bob-ft673")):
            await conn.execute(
                "INSERT INTO users (id, username) VALUES ($1, $2) ON CONFLICT (id) DO NOTHING",
                user,
                name,
            )
        await _add_books(conn, 1, 9)

    _run(postgres_url, prepare)
    return postgres_url


def at(part: int, ms: int = 0, *, finished: bool = False, minute: int = 0) -> Position:
    return Position(
        part, ms, finished, NOW - timedelta(hours=1) + timedelta(minutes=minute)
    )


def entry(book_id: UUID, part: int, ms: int = 0, **kw: Any) -> Entry:
    return Entry(book_id, at(part, ms, **kw))


def wire(**over: Any) -> dict[str, Any]:
    item: dict[str, Any] = {
        "book_id": str(A),
        "part": 2,
        "position_ms": 60_000,
        "finished": False,
        "updated_at": "2026-10-07T11:00:00.000Z",
    }
    item.update(over)
    return item


async def _count(conn: asyncpg.Connection) -> int:
    return int(await conn.fetchval("SELECT count(*) FROM book_position"))


# --- which record is newer (same rule as on phone, FT-670) ---


def test_constants() -> None:
    assert MAX_BATCH == 500
    assert MAX_ROWS == 5000
    assert MAX_PART == 3000
    assert MAX_POSITION_MS == 30 * 24 * 3600 * 1000
    assert timedelta(minutes=5) == FUTURE_SLACK


def test_later_wins() -> None:
    old, new = at(9, 900_000, finished=True, minute=0), at(1, 5, minute=1)
    assert newer(old, new) is new
    assert newer(new, old) is new


def test_same_time_finished_wins_then_further_part_then_further_place_then_first() -> (
    None
):
    done, going = at(1, 5, finished=True), at(9, 900)
    assert newer(done, going) is done
    assert newer(going, done) is done
    far, near = at(3, 0), at(2, 999_999)
    assert newer(far, near) is far
    assert newer(near, far) is far
    late, early = at(3, 900), at(3, 5)
    assert newer(late, early) is late
    assert newer(early, late) is late
    a, b = at(3, 7), at(3, 7)
    assert newer(a, b) is a


def test_time_is_compared_as_a_moment() -> None:
    msk = timezone(timedelta(hours=3))
    same = Position(1, 5, False, datetime(2026, 10, 7, 14, 0, tzinfo=msk))
    assert newer(at(1, 9), same) == at(1, 9)
    later = Position(1, 5, False, datetime(2026, 10, 7, 14, 1, tzinfo=msk))
    assert newer(at(1, 9), later) is later


# --- wire: what phone sent ---


def test_wire_round_trip_matches_the_phone() -> None:
    [e] = from_wire({"items": [wire()]}) or []
    assert e == Entry(
        A, Position(2, 60_000, False, datetime(2026, 10, 7, 11, tzinfo=UTC))
    )
    assert to_wire([e]) == {"items": [wire()]}
    json.dumps(to_wire([e]))


def test_wire_time_is_utc_with_z_and_milliseconds() -> None:
    msk = timezone(timedelta(hours=3))
    e = Entry(A, Position(1, 1, True, datetime(2026, 10, 7, 14, 0, 0, 123456, msk)))
    assert to_wire([e])["items"][0]["updated_at"] == "2026-10-07T11:00:00.123Z"


def test_wire_book_number_goes_out_in_lower_case() -> None:
    upper = "ABCDEF12-0000-4000-8000-00000000ABCD"
    [e] = from_wire({"items": [wire(book_id=upper)]}) or []
    assert e.book_id == UUID(upper)
    assert to_wire([e])["items"][0]["book_id"] == upper.lower()


@pytest.mark.parametrize(
    "raw",
    [None, [], "x", 5, {}, {"items": None}, {"items": {}}, {"items": "ab"}],
)
def test_wire_not_a_batch_is_none(raw: Any) -> None:
    assert from_wire(raw) is None


def test_wire_empty_batch_is_empty() -> None:
    assert from_wire({"items": []}) == []


def test_wire_batch_is_bounded() -> None:
    full = [wire(book_id=str(book(n))) for n in range(MAX_BATCH)]
    assert len(from_wire({"items": full}) or []) == MAX_BATCH
    assert from_wire({"items": [wire()] * (MAX_BATCH + 1)}) is None


@pytest.mark.parametrize(
    "bad",
    [
        None,
        "x",
        [],
        wire(book_id=""),
        wire(book_id=None),
        wire(book_id=7),
        wire(book_id="not-a-book"),
        wire(book_id=str(A).replace("-", "")),
        wire(book_id="{" + str(A) + "}"),
        wire(book_id="urn:uuid:" + str(A)),
        wire(book_id=str(A) + " "),
        wire(book_id=str(A)[:-1] + "g"),
        wire(book_id=str(A)[:-1] + "١"),
        wire(part=0),
        wire(part=-1),
        wire(part=MAX_PART + 1),
        wire(part=2.0),
        wire(part="2"),
        wire(part=True),
        wire(part=None),
        wire(position_ms=-1),
        wire(position_ms=MAX_POSITION_MS + 1),
        wire(position_ms=1.0),
        wire(position_ms="5"),
        wire(position_ms=True),
        wire(position_ms=None),
        wire(finished=1),
        wire(finished="true"),
        wire(finished=None),
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
    ],
)
def test_wire_bad_item_is_skipped_and_the_rest_stays(bad: Any) -> None:
    got = from_wire({"items": [wire(book_id=str(B)), bad, wire(book_id=str(C))]})
    assert [e.book_id for e in got or []] == [B, C]


def test_wire_bounds_are_inclusive() -> None:
    got = from_wire(
        {
            "items": [
                wire(part=MAX_PART, position_ms=MAX_POSITION_MS),
                wire(
                    part=1,
                    position_ms=0,
                    finished=True,
                    updated_at="2000-01-01T00:00:00Z",
                ),
            ]
        }
    )
    assert got is not None and len(got) == 2


# --- write and read ---


def test_put_and_read_back(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        stored = await put(conn, ANN, [entry(B, 2, 2000), entry(A, 1, 1000)], now=NOW)
        assert stored == [entry(A, 1, 1000), entry(B, 2, 2000)]
        assert await of_books(conn, ANN, [A, B, C]) == {A: at(1, 1000), B: at(2, 2000)}
        assert await of_books(conn, ANN, [C]) == {}
        assert await of_books(conn, ANN, []) == {}

    _run(base, work)


def test_reading_takes_any_iterable_and_repeats(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await put(conn, ANN, [entry(A, 1, 1000)], now=NOW)
        assert await of_books(conn, ANN, iter([A, A, NO_BOOK])) == {A: at(1, 1000)}

    _run(base, work)


def test_the_longest_part_fits_the_database(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        far = entry(A, MAX_PART, MAX_POSITION_MS)
        assert await put(conn, ANN, [far], now=NOW) == [far]

    _run(base, work)


def test_older_report_does_not_win_and_the_answer_is_what_is_stored(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await put(conn, ANN, [entry(A, 5, 900_000, minute=10)], now=NOW)
        answer = await put(conn, ANN, [entry(A, 9, 5, minute=3)], now=NOW)
        assert answer == [entry(A, 5, 900_000, minute=10)]
        answer = await put(conn, ANN, [entry(A, 1, 7, minute=11)], now=NOW)
        assert answer == [entry(A, 1, 7, minute=11)]

    _run(base, work)


def test_same_time_tie_breaks_hold_in_the_database(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        async def stored(book_id: UUID) -> Position:
            return (await of_books(conn, ANN, [book_id]))[book_id]

        # finished wins regardless of direction
        await put(conn, ANN, [entry(A, 9, 900)], now=NOW)
        await put(conn, ANN, [entry(A, 1, 5, finished=True)], now=NOW)
        assert await stored(A) == at(1, 5, finished=True)
        await put(conn, ANN, [entry(A, 9, 900)], now=NOW)
        assert await stored(A) == at(1, 5, finished=True)
        # then further part
        await put(conn, ANN, [entry(B, 2, 999_999)], now=NOW)
        await put(conn, ANN, [entry(B, 3, 0)], now=NOW)
        assert await stored(B) == at(3, 0)
        await put(conn, ANN, [entry(B, 2, 999_999)], now=NOW)
        assert await stored(B) == at(3, 0)
        # then further position
        await put(conn, ANN, [entry(C, 3, 5)], now=NOW)
        await put(conn, ANN, [entry(C, 3, 900)], now=NOW)
        await put(conn, ANN, [entry(C, 3, 5)], now=NOW)
        assert await stored(C) == at(3, 900)

    _run(base, work)


def test_the_same_report_again_is_not_a_change(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await put(conn, ANN, [entry(A, 1, 5)], now=NOW)
        _, mark = await changes(conn, ANN)
        assert await put(conn, ANN, [entry(A, 1, 5)], now=NOW) == [entry(A, 1, 5)]
        assert await changes(conn, ANN, after=mark) == ([], mark)

    _run(base, work)


def test_answer_has_only_what_was_sent(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await put(conn, ANN, [entry(B, 1, 1), entry(C, 1, 2)], now=NOW)
        assert await put(conn, ANN, [entry(A, 1, 3)], now=NOW) == [entry(A, 1, 3)]

    _run(base, work)


def test_same_book_twice_in_one_batch_is_one_row_newest_kept(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        answer = await put(
            conn,
            ANN,
            [
                entry(A, 1, 5, minute=2),
                entry(A, 2, 9, minute=7),
                entry(A, 3, 7, minute=4),
            ],
            now=NOW,
        )
        assert answer == [entry(A, 2, 9, minute=7)]
        assert await _count(conn) == 1

    _run(base, work)


def test_a_book_the_server_does_not_know_is_skipped(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        answer = await put(conn, ANN, [entry(NO_BOOK, 1, 5), entry(A, 1, 9)], now=NOW)
        assert answer == [entry(A, 1, 9)]
        assert await put(conn, ANN, [entry(NO_BOOK, 1, 5)], now=NOW) == []
        assert await _count(conn) == 1

    _run(base, work)


def test_each_person_has_their_own(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await put(conn, ANN, [entry(A, 1, 5, minute=1)], now=NOW)
        answer = await put(conn, BOB, [entry(A, 2, 9, minute=0)], now=NOW)
        assert answer == [entry(A, 2, 9, minute=0)]
        assert await of_books(conn, ANN, [A]) == {A: at(1, 5, minute=1)}
        assert await of_books(conn, BOB, [A]) == {A: at(2, 9, minute=0)}
        got, _ = await changes(conn, BOB)
        assert got == [entry(A, 2, 9, minute=0)]

    _run(base, work)


def test_empty_batch_and_unknown_person_write_nothing(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        assert await put(conn, ANN, [], now=NOW) == []
        assert await put(conn, GONE, [entry(A, 1, 5)], now=NOW) == []
        assert await _count(conn) == 0

    _run(base, work)


def test_deleted_person_takes_positions_along(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await conn.execute(
            "INSERT INTO users (id, username) VALUES ($1, 'gone-ft673')", GONE
        )
        await put(conn, GONE, [entry(A, 1, 5)], now=NOW)
        await put(conn, ANN, [entry(A, 1, 5)], now=NOW)
        await conn.execute("DELETE FROM users WHERE id = $1", GONE)
        assert await _count(conn) == 1

    _run(base, work)


def test_deleted_book_takes_its_positions_along(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await put(conn, ANN, [entry(A, 1, 5), entry(B, 1, 5)], now=NOW)
        await conn.execute("DELETE FROM books WHERE id = $1", A)
        assert await of_books(conn, ANN, [A, B]) == {B: at(1, 5)}

    _run(base, work)


def test_taking_the_book_off_the_shelf_keeps_the_position(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await conn.execute(
            "INSERT INTO book_shelf (user_id, book_id, added_at) VALUES ($1, $2, $3)",
            ANN,
            A,
            NOW,
        )
        await put(conn, ANN, [entry(A, 2, 5)], now=NOW)
        await conn.execute("DELETE FROM book_shelf WHERE user_id = $1", ANN)
        assert await of_books(conn, ANN, [A]) == {A: at(2, 5)}

    _run(base, work)


def test_time_from_the_future_becomes_now(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        far = Position(2, 5, False, datetime(2099, 1, 1, tzinfo=UTC))
        [stored] = await put(conn, ANN, [Entry(A, far)], now=NOW)
        assert stored.position == Position(2, 5, False, NOW)
        # Honest report a minute later wins.
        fair = Position(1, 9, False, NOW + timedelta(minutes=1))
        [stored] = await put(
            conn, ANN, [Entry(A, fair)], now=NOW + timedelta(minutes=1)
        )
        assert stored.position == fair

    _run(base, work)


def test_small_clock_drift_is_kept_as_is(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        edge = Position(1, 5, False, NOW + FUTURE_SLACK)
        over = Position(1, 5, False, NOW + FUTURE_SLACK + timedelta(seconds=1))
        stored = await put(conn, ANN, [Entry(A, edge), Entry(B, over)], now=NOW)
        assert [e.position.updated_at for e in stored] == [NOW + FUTURE_SLACK, NOW]

    _run(base, work)


def test_time_without_zone_is_not_stored(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        naive = Position(1, 5, False, datetime(2026, 10, 7, 11, 0))
        assert await put(conn, ANN, [Entry(A, naive)], now=NOW) == []
        assert await put(conn, ANN, [Entry(A, naive), entry(B, 1, 5)], now=NOW) == [
            entry(B, 1, 5)
        ]
        assert await _count(conn) == 1

    _run(base, work)


def test_batch_over_the_bound_is_refused_whole(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await _add_books(conn, 10, MAX_BATCH + 1)
        many = [entry(book(n), 1, n) for n in range(1, MAX_BATCH + 2)]
        with pytest.raises(ValueError, match="too_many"):
            await put(conn, ANN, many, now=NOW)
        assert await _count(conn) == 0
        assert len(await put(conn, ANN, many[:MAX_BATCH], now=NOW)) == MAX_BATCH

    _run(base, work)


def test_repeats_do_not_count_towards_the_bound(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        many = [entry(A, 1, n) for n in range(MAX_BATCH + 50)]
        assert await put(conn, ANN, many, now=NOW) == [entry(A, 1, MAX_BATCH + 49)]

    _run(base, work)


def test_full_batch_is_saved_fast(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await _add_books(conn, 10, MAX_BATCH)
        many = [entry(book(n), 1, n) for n in range(1, MAX_BATCH + 1)]
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
        await put(conn, ANN, [entry(B, 1, 1)], now=NOW)
        await put(conn, ANN, [entry(A, 1, 2)], now=NOW)
        first, mark = await changes(conn, ANN)
        assert [e.book_id for e in first] == [B, A]
        assert mark > 0
        assert await changes(conn, ANN, after=mark) == ([], mark)
        await put(conn, ANN, [entry(B, 2, 3, minute=5)], now=NOW)
        second, mark2 = await changes(conn, ANN, after=mark)
        assert second == [entry(B, 2, 3, minute=5)]
        assert mark2 > mark
        # Record that did not win is not considered a change.
        await put(conn, ANN, [entry(A, 9, 1, minute=-30)], now=NOW)
        assert await changes(conn, ANN, after=mark2) == ([], mark2)

    _run(base, work)


def test_changes_come_in_pages(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await put(conn, ANN, [entry(book(n), 1, n) for n in range(1, 8)], now=NOW)
        seen: list[UUID] = []
        mark = 0
        for _ in range(4):
            page, mark = await changes(conn, ANN, after=mark, limit=3)
            assert len(page) <= 3
            seen += [e.book_id for e in page]
        assert sorted(seen) == [book(n) for n in range(1, 8)]
        assert len(seen) == 7

    _run(base, work)


def test_pages_follow_the_order_of_arrival_not_the_phone_clock(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await put(conn, ANN, [entry(A, 1, 1, minute=50)], now=NOW)
        await put(conn, ANN, [entry(B, 1, 2, minute=1)], now=NOW)
        first, mark = await changes(conn, ANN, limit=1)
        second, mark = await changes(conn, ANN, after=mark, limit=1)
        assert [e.book_id for e in first + second] == [A, B]
        assert await changes(conn, ANN, after=mark) == ([], mark)

    _run(base, work)


def test_changes_page_is_bounded(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await _add_books(conn, 10, 1200)
        for start in (1, 401, 801):
            batch = [entry(book(n), 1, n) for n in range(start, start + 400)]
            await put(conn, ANN, batch, now=NOW)
        assert len((await changes(conn, ANN, limit=10**9))[0]) == 1000
        assert len((await changes(conn, ANN, limit=0))[0]) == 1
        assert len((await changes(conn, ANN, limit=-5))[0]) == 1
        assert len((await changes(conn, ANN))[0]) == 500
        assert len((await changes(conn, ANN, after=-7, limit=2))[0]) == 2
        assert await changes(conn, ANN, after=10**30) == ([], 2**63 - 1)
        assert await changes(conn, BOB, after=-7) == ([], 0)

    _run(base, work)


def test_two_writers_at_once_lose_nothing_for_the_reader(base: str) -> None:
    """Change number increases in commit order: while user's first record
    is uncommitted, the second gets no number."""

    async def work(conn: asyncpg.Connection) -> None:
        slow = await asyncpg.connect(base)
        try:
            tx = slow.transaction()
            await tx.start()
            await put(slow, ANN, [entry(A, 1, 1)], now=NOW)
            fast = asyncio.create_task(put(conn, ANN, [entry(B, 1, 2)], now=NOW))
            await asyncio.sleep(0.3)
            assert not fast.done()
            await tx.commit()
            await fast
        finally:
            await slow.close()
        got, _ = await changes(conn, ANN)
        assert [e.book_id for e in got] == [A, B]

    _run(base, work)


def test_other_person_is_not_held_up(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        slow = await asyncpg.connect(base)
        try:
            tx = slow.transaction()
            await tx.start()
            await put(slow, ANN, [entry(A, 1, 1)], now=NOW)
            await asyncio.wait_for(put(conn, BOB, [entry(A, 1, 2)], now=NOW), 2)
            await tx.rollback()
        finally:
            await slow.close()

    _run(base, work)


def test_same_book_from_two_phones_at_once_keeps_the_newest(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        other = await asyncpg.connect(base)
        try:
            await asyncio.gather(
                put(conn, ANN, [entry(A, 1, 5, minute=1)], now=NOW),
                put(other, ANN, [entry(A, 2, 9, minute=2)], now=NOW),
            )
        finally:
            await other.close()
        assert await of_books(conn, ANN, [A]) == {A: at(2, 9, minute=2)}

    _run(base, work)


def test_put_does_not_wait_for_a_writer_of_the_same_person(base: str) -> None:
    """Position write does not wait on adjacent write holding ref to user (shelf, playback)."""

    async def go() -> None:
        other = await asyncpg.connect(base)
        conn = await asyncpg.connect(base)
        try:
            tx = other.transaction()
            await tx.start()
            await other.execute("SELECT 1 FROM users WHERE id = $1 FOR KEY SHARE", ANN)
            stored = await asyncio.wait_for(
                put(conn, ANN, [entry(A, 1, 1000)], now=NOW), 5
            )
            assert stored == [entry(A, 1, 1000)]
            await tx.rollback()
        finally:
            await conn.close()
            await other.close()

    asyncio.run(go())


def test_the_person_stays_locked_until_the_whole_write_is_done(base: str) -> None:
    """User lock is held until end of write, not until end of first query:
    otherwise neighbor would get change number earlier than this write commits."""

    async def go() -> None:
        holder = await asyncpg.connect(base)
        conn = await asyncpg.connect(base)
        probe = await asyncpg.connect(base)
        try:
            await put(conn, ANN, [entry(A, 1, 1)], now=NOW)
            tx = holder.transaction()
            await tx.start()
            await holder.execute(
                "SELECT 1 FROM book_position WHERE user_id = $1 FOR UPDATE", ANN
            )
            writer = asyncio.create_task(
                put(conn, ANN, [entry(A, 2, 2, minute=3)], now=NOW)
            )
            await asyncio.sleep(0.3)
            assert not writer.done()
            with pytest.raises(asyncpg.LockNotAvailableError):
                await probe.execute(
                    "SELECT 1 FROM users WHERE id = $1 FOR NO KEY UPDATE NOWAIT", ANN
                )
            await tx.rollback()
            assert await asyncio.wait_for(writer, 5) == [entry(A, 2, 2, minute=3)]
        finally:
            await probe.close()
            await conn.close()
            await holder.close()

    asyncio.run(go())


# --- volume ---


def test_rows_per_person_are_bounded_oldest_go(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await _add_books(conn, 10, MAX_ROWS + 2)
        await conn.execute(
            """
            INSERT INTO book_position
                (user_id, book_id, part, position_ms, finished, updated_at, seq)
            SELECT $1, ('00000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid, 1, n, false,
                   $2::timestamptz - n * interval '1 minute', nextval('book_position_seq')
            FROM generate_series(1, $3::int) AS n
            """,
            ANN,
            NOW - timedelta(days=1),
            MAX_ROWS,
        )
        # Another user has the same book that will be dropped for this one.
        old = Position(1, 1, False, NOW - timedelta(days=30))
        await put(conn, BOB, [Entry(book(MAX_ROWS), old)], now=NOW)
        new1, new2 = book(MAX_ROWS + 1), book(MAX_ROWS + 2)
        answer = await put(conn, ANN, [entry(new1, 1, 1), entry(new2, 1, 2)], now=NOW)
        assert [e.book_id for e in answer] == [new1, new2]
        assert (
            await conn.fetchval(
                "SELECT count(*) FROM book_position WHERE user_id = $1", ANN
            )
            == MAX_ROWS
        )
        edge = [book(MAX_ROWS), book(MAX_ROWS - 1), book(MAX_ROWS - 2), book(1)]
        assert set(await of_books(conn, ANN, edge)) == {book(MAX_ROWS - 2), book(1)}
        assert await of_books(conn, BOB, [book(MAX_ROWS)]) == {book(MAX_ROWS): old}

    _run(base, work)


# --- contract ---


def test_values_are_frozen() -> None:
    p = at(1, 5)
    with pytest.raises(dataclasses.FrozenInstanceError):
        p.position_ms = 6  # type: ignore[misc]
    e = entry(A, 1, 5)
    with pytest.raises(dataclasses.FrozenInstanceError):
        e.book_id = B  # type: ignore[misc]
    assert [f.name for f in dataclasses.fields(Position)] == [
        "part",
        "position_ms",
        "finished",
        "updated_at",
    ]
    assert [f.name for f in dataclasses.fields(Entry)] == ["book_id", "position"]


def test_nothing_is_logged(base: str, caplog: pytest.LogCaptureFixture) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        await put(conn, ANN, [entry(A, 1, 5)], now=NOW)
        await changes(conn, ANN)
        await of_books(conn, ANN, [A])

    with caplog.at_level(logging.DEBUG):
        from_wire({"items": [wire(), wire(finished=7)]})
        _run(base, work)
    assert not [r for r in caplog.records if r.name.startswith("app.book_position")]
    assert str(A) not in caplog.text


def test_module_stays_out_of_network_and_shared_files() -> None:
    src = Path(book_position.__file__).read_text(encoding="utf-8")
    for word in ("httpx", "logging", "print(", "app.main", "app.library", "app.books"):
        assert word not in src


def test_migration_is_safe_to_repeat(base: str) -> None:
    sql = (
        Path(__file__).resolve().parents[1] / "migrations" / "056_book_position.sql"
    ).read_text(encoding="utf-8")

    async def work(conn: asyncpg.Connection) -> None:
        await put(conn, ANN, [entry(A, 1, 5)], now=NOW)
        await conn.execute(sql)
        await conn.execute(sql)
        assert await _count(conn) == 1
        for part, place in ((0, 5), (1, -1)):
            with pytest.raises(asyncpg.CheckViolationError):
                await conn.execute(
                    "INSERT INTO book_position VALUES ($1, $2, $3, $4, false, now(), 1)",
                    ANN,
                    B,
                    part,
                    place,
                )

    _run(base, work)
