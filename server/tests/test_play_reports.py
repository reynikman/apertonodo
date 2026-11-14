"""FT-639 (Р-A96, Contract D1): playback with its own ID and dispatch queue.

Today playback has no ID: the server distinguishes one from another by "same song in a row", and
sends to ListenBrainz in a single request that is lost on network failure. Here is report intake under Contract D1:
phone provides playback ID (`listen_id`), server stores the highest number of played milliseconds and
once, in the same transaction, inserts an "enqueue to service" row.

Guarded:
- repeated reports, reports in reverse order, and concurrent reports yield one playback with maximum
  played ms and one enqueue row per service;
- external services have their own threshold (half song or 4 minutes; shorter than 30 seconds — never),
  checked on each report, not only the first;
- launch time is assigned once; phone clock drifting forward or two weeks behind does not
  leak outside;
- playback row and dispatch row appear together or not at all;
- "do not record" — nothing is recorded; when pause is toggled, pending rows are removed, while in-progress and
  completed ones are kept;
- dispatch row tracks connection revision: new key (even the same one) — new revision, pending
  rows of previous revision are removed;
- invalid token and unknown service do not enter queue;
- another user's playback with the same ID is separate.

What tests do not prove: that `POST /v1/history` calls intake (lead integration, B6), that rows are actually
dispatched (next card — sender), and that phone sends the ID (P6c).
"""

from __future__ import annotations

import asyncio
import logging
from datetime import UTC, datetime, timedelta
from typing import Any
from uuid import UUID, uuid4

import asyncpg
import pytest

from app.migrate import apply
from app.play_reports import (
    SERVICES,
    Reported,
    drop_outdated,
    drop_waiting,
    external_due,
    purge,
    report,
    settle_started_at,
)

NOW = datetime(2026, 10, 6, 12, 0, tzinfo=UTC)
STARTED = NOW - timedelta(minutes=3)
ANN = UUID("aaaaaaaa-0000-4000-8000-000000000001")
BOB = UUID("bbbbbbbb-0000-4000-8000-000000000002")
SONG = "33333333-3333-4333-8333-333333333333"
OTHER = "44444444-4444-4444-8444-444444444444"
FOUR_MIN = 240_000


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
    _run(
        postgres_url,
        lambda conn: conn.execute(
            "TRUNCATE play_reports, play_deliveries, scrobble_accounts"
        ),
    )
    return postgres_url


async def _connect(
    conn: asyncpg.Connection,
    user: UUID = ANN,
    service: str = "listenbrainz",
    bad: bool = False,
) -> int:
    return int(
        await conn.fetchval(
            """
            INSERT INTO scrobble_accounts (user_id, service, token, bad) VALUES ($1, $2, 'token-one', $3)
            ON CONFLICT (user_id, service) DO UPDATE SET token = EXCLUDED.token, bad = EXCLUDED.bad
            RETURNING revision
            """,
            user,
            service,
            bad,
        )
    )


async def _say(
    conn: asyncpg.Connection, listen: UUID, ms: int, **over: Any
) -> Reported | None:
    args: dict[str, Any] = {
        "listen_id": listen,
        "track_id": SONG,
        "started_at": STARTED,
        "listened_ms": ms,
        "duration_ms": 200_000,
        "paused": False,
        "now": NOW,
    }
    user = over.pop("user", ANN)
    args.update(over)
    return await report(conn, user, **args)


async def _deliveries(conn: asyncpg.Connection) -> list[tuple[Any, ...]]:
    rows = await conn.fetch(
        "SELECT user_id, listen_id, service, state, account_revision FROM play_deliveries ORDER BY user_id, service"
    )
    return [tuple(row.values()) for row in rows]


async def _reports(conn: asyncpg.Connection) -> list[tuple[Any, ...]]:
    rows = await conn.fetch(
        "SELECT user_id, listen_id, track_id, listened_ms, started_at FROM play_reports ORDER BY user_id, listen_id"
    )
    return [tuple(row.values()) for row in rows]


async def _put(conn: asyncpg.Connection, listen: UUID, state: str, *, service: str = "listenbrainz",
               user: UUID = ANN, revision: int = 1, created: datetime = NOW) -> None:  # fmt: skip
    await conn.execute(
        "INSERT INTO play_reports VALUES ($1, $2, $3, $4, 150000, 200000, $4) ON CONFLICT DO NOTHING",
        user, listen, SONG, created,
    )  # fmt: skip
    await conn.execute(
        "INSERT INTO play_deliveries (user_id, listen_id, service, account_revision, state, next_try_at, created_at)"
        " VALUES ($1, $2, $3, $4, $5, $6, $6)",
        user, listen, service, revision, state, created,
    )  # fmt: skip


# --- external services threshold -------------------------------------------------


@pytest.mark.parametrize(
    ("listened", "duration", "due"),
    [
        (99_999, 200_000, False),
        (100_000, 200_000, True),  # exactly half
        (100_000, 200_001, False),  # half of odd length is not rounded down
        (100_001, 200_001, True),
        (239_999, 600_000, False),
        (240_000, 600_000, True),  # four minutes of a long song
        (240_000, 1_200_000, True),
        (29_999, 29_999, False),  # shorter than 30 seconds is never sent
        (500_000, 29_999, False),
        (15_000, 30_000, True),  # exactly 30 seconds is already a song
        (14_999, 30_000, False),
        (239_999, 0, False),  # length unknown — only four minutes
        (240_000, 0, True),
        (240_000, -5, True),
        (0, 0, False),
    ],
)
def test_external_threshold(listened: int, duration: int, due: bool) -> None:
    assert external_due(listened, duration) is due


def test_services_are_the_two_we_know() -> None:
    assert set(SERVICES) == {"listenbrainz", "lastfm"}


# --- launch time ----------------------------------------------------------


@pytest.mark.parametrize(
    ("offset", "kept"),
    [
        (timedelta(minutes=-3), True),
        (timedelta(0), True),
        (timedelta(minutes=5), True),  # phone clock ahead within tolerance
        (timedelta(minutes=5, seconds=1), False),
        (timedelta(days=2), False),
        (timedelta(days=-14), True),  # report from phone buffer, 14 days is still valid
        (timedelta(days=-14, seconds=-1), False),
        (timedelta(days=-400), False),
    ],
)
def test_started_at_from_a_wrong_clock_becomes_the_time_of_receipt(
    offset: timedelta, kept: bool
) -> None:
    said = NOW + offset
    assert settle_started_at(said, NOW) == (said if kept else NOW)


def test_started_at_without_a_zone_is_not_trusted() -> None:
    assert settle_started_at(datetime(2026, 10, 6, 11, 59), NOW) == NOW


# --- report intake ----------------------------------------------------------


def test_first_report_below_threshold_is_stored_and_not_queued(base: str) -> None:
    listen = uuid4()

    async def work(conn: asyncpg.Connection) -> Any:
        await _connect(conn)
        said = await _say(conn, listen, 40_000)
        return said, await _reports(conn), await _deliveries(conn)

    said, reports, deliveries = _run(base, work)
    assert said == Reported(
        listened_ms=40_000, started_at=STARTED, first=True, queued=()
    )
    assert reports == [(ANN, listen, SONG, 40_000, STARTED)]
    assert deliveries == []


def test_report_past_threshold_queues_one_delivery_with_the_account_revision(
    base: str,
) -> None:
    listen = uuid4()

    async def work(conn: asyncpg.Connection) -> Any:
        revision = await _connect(conn)
        said = await _say(conn, listen, 100_000)
        row = await conn.fetchrow(
            "SELECT attempts, next_try_at, created_at FROM play_deliveries"
        )
        return revision, said, await _deliveries(conn), tuple(row.values())

    revision, said, deliveries, row = _run(base, work)
    assert said is not None
    assert said.queued == ("listenbrainz",)
    assert deliveries == [(ANN, listen, "listenbrainz", "waiting", revision)]
    assert row == (0, NOW, NOW), "new row can be picked up immediately"


def test_threshold_is_checked_on_every_report_not_only_the_first(base: str) -> None:
    listen = uuid4()

    async def work(conn: asyncpg.Connection) -> Any:
        await _connect(conn)
        first = await _say(conn, listen, 40_000)
        middle = await _say(conn, listen, 99_000)
        crossing = await _say(conn, listen, 120_000)
        after = await _say(conn, listen, 200_000)
        return (
            first,
            middle,
            crossing,
            after,
            len(await _deliveries(conn)),
            len(await _reports(conn)),
        )

    first, middle, crossing, after, deliveries, reports = _run(base, work)
    assert (first.queued, middle.queued) == ((), ())
    assert crossing.queued == ("listenbrainz",), "threshold crossed on third report"
    assert crossing.first is False
    assert after.queued == (), "duplicate report does not create second row"
    assert (deliveries, reports) == (1, 1)


def test_reports_out_of_order_keep_the_largest_number(base: str) -> None:
    listen = uuid4()

    async def work(conn: asyncpg.Connection) -> Any:
        await _connect(conn)
        late = await _say(conn, listen, 150_000)
        early = await _say(conn, listen, 60_000)
        return late, early, await _reports(conn), len(await _deliveries(conn))

    late, early, reports, deliveries = _run(base, work)
    assert late.listened_ms == 150_000
    assert early.listened_ms == 150_000, (
        "response returns what was stored, not what was sent"
    )
    assert early.first is False
    assert reports == [(ANN, listen, SONG, 150_000, STARTED)]
    assert deliveries == 1


def test_same_report_twice_changes_nothing(base: str) -> None:
    listen = uuid4()

    async def work(conn: asyncpg.Connection) -> Any:
        await _connect(conn)
        await _say(conn, listen, 150_000)
        again = await _say(conn, listen, 150_000, now=NOW + timedelta(hours=1))
        row = await conn.fetchrow("SELECT next_try_at, created_at FROM play_deliveries")
        return again, await _reports(conn), tuple(row.values())

    again, reports, row = _run(base, work)
    assert again == Reported(
        listened_ms=150_000, started_at=STARTED, first=False, queued=()
    )
    assert reports == [(ANN, listen, SONG, 150_000, STARTED)]
    assert row == (NOW, NOW)


def test_simultaneous_reports_make_one_listen_and_one_delivery(base: str) -> None:
    listen = uuid4()

    async def go() -> Any:
        first = await asyncpg.connect(base)
        conns = [first] + [await asyncpg.connect(base) for _ in range(5)]
        try:
            await _connect(first)
            said = await asyncio.gather(
                *(
                    _say(conn, listen, 100_000 + i * 1000)
                    for i, conn in enumerate(conns)
                )
            )
            return said, await _reports(first), await _deliveries(first)
        finally:
            for conn in conns:
                await conn.close()

    said, reports, deliveries = asyncio.run(go())
    assert [r[3] for r in reports] == [105_000]
    assert len(deliveries) == 1
    assert sum(1 for s in said if s.first) == 1
    assert sum(len(s.queued) for s in said) == 1


def test_started_at_is_set_once(base: str) -> None:
    listen = uuid4()

    async def work(conn: asyncpg.Connection) -> Any:
        first = await _say(conn, listen, 10_000)
        again = await _say(
            conn, listen, 20_000, started_at=STARTED + timedelta(minutes=1)
        )
        return first, again, await _reports(conn)

    first, again, reports = _run(base, work)
    assert first.started_at == STARTED
    assert again.started_at == STARTED
    assert reports[0][4] == STARTED


def test_started_at_from_the_future_is_replaced_before_storing(base: str) -> None:
    listen = uuid4()

    async def work(conn: asyncpg.Connection) -> Any:
        said = await _say(conn, listen, 10_000, started_at=NOW + timedelta(days=3))
        return said, await _reports(conn)

    said, reports = _run(base, work)
    assert said.started_at == NOW
    assert reports[0][4] == NOW


def test_duration_of_the_first_report_decides(base: str) -> None:
    listen = uuid4()

    async def work(conn: asyncpg.Connection) -> Any:
        await _connect(conn)
        await _say(conn, listen, 10_000, duration_ms=600_000)
        # Re-report gives different duration — threshold is still from first.
        said = await _say(conn, listen, 100_000, duration_ms=200_000)
        return said.queued

    assert _run(base, work) == ()


def test_unknown_duration_is_taken_from_a_later_report(base: str) -> None:
    listen = uuid4()

    async def work(conn: asyncpg.Connection) -> Any:
        await _connect(conn)
        first = await _say(conn, listen, 10_000, duration_ms=0)
        said = await _say(conn, listen, 100_000, duration_ms=200_000)
        again = await _say(conn, listen, 100_000, duration_ms=900_000)
        stored = await conn.fetchval("SELECT duration_ms FROM play_reports")
        return first.queued, said.queued, stored, again.queued

    assert _run(base, work) == ((), ("listenbrainz",), 200_000, ()), (
        "three-minute song played to completion should not wait for four minutes"
    )


def test_short_song_is_stored_but_never_queued(base: str) -> None:
    listen = uuid4()

    async def work(conn: asyncpg.Connection) -> Any:
        await _connect(conn)
        said = await _say(conn, listen, 25_000, duration_ms=25_000)
        return said, len(await _reports(conn)), await _deliveries(conn)

    said, reports, deliveries = _run(base, work)
    assert said is not None and said.queued == ()
    assert (reports, deliveries) == (1, [])


def test_negative_duration_is_stored_as_unknown(base: str) -> None:
    listen = uuid4()

    async def work(conn: asyncpg.Connection) -> Any:
        await _say(conn, listen, 10_000, duration_ms=-7)
        return await conn.fetchval("SELECT duration_ms FROM play_reports")

    assert _run(base, work) == 0


def test_no_account_no_delivery(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> Any:
        await _connect(conn, user=BOB)
        said = await _say(conn, uuid4(), 150_000)
        return said.queued, await _deliveries(conn)

    assert _run(base, work) == ((), []), (
        "another user's connection does not dispatch for this user"
    )


def test_bad_token_is_not_queued(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> Any:
        await _connect(conn, bad=True)
        said = await _say(conn, uuid4(), 150_000)
        return said.queued, await _deliveries(conn)

    assert _run(base, work) == ((), [])


def test_each_connected_service_gets_its_own_delivery(base: str) -> None:
    listen = uuid4()

    async def work(conn: asyncpg.Connection) -> Any:
        one = await _connect(conn, service="listenbrainz")
        two = await _connect(conn, service="lastfm")
        await _connect(conn, service="somethingelse")
        said = await _say(conn, listen, 150_000)
        return one, two, said.queued, await _deliveries(conn)

    one, two, queued, deliveries = _run(base, work)
    assert queued == ("lastfm", "listenbrainz"), (
        "alphabetical; unfamiliar service is not queued"
    )
    assert deliveries == [
        (ANN, listen, "lastfm", "waiting", two),
        (ANN, listen, "listenbrainz", "waiting", one),
    ]


def test_service_connected_later_is_queued_on_the_next_report(base: str) -> None:
    listen = uuid4()

    async def work(conn: asyncpg.Connection) -> Any:
        await _connect(conn, service="listenbrainz")
        await _say(conn, listen, 150_000)
        await _connect(conn, service="lastfm")
        said = await _say(conn, listen, 160_000)
        return said.queued, len(await _deliveries(conn))

    assert _run(base, work) == (("lastfm",), 2)


def test_threshold_looks_at_what_is_stored_not_at_what_just_arrived(base: str) -> None:
    listen = uuid4()

    async def work(conn: asyncpg.Connection) -> Any:
        await _say(conn, listen, 150_000)
        await _connect(conn)
        # Delayed early report: by itself it does not pass threshold, but playback passed long ago.
        said = await _say(conn, listen, 60_000)
        return said.queued

    assert _run(base, work) == ("listenbrainz",)


def test_two_people_with_the_same_number_are_two_listens(base: str) -> None:
    listen = uuid4()

    async def work(conn: asyncpg.Connection) -> Any:
        await _connect(conn, user=ANN)
        await _connect(conn, user=BOB)
        ann = await _say(conn, listen, 150_000, user=ANN)
        bob = await _say(conn, listen, 20_000, user=BOB, track_id=OTHER)
        return ann, bob, await _reports(conn), await _deliveries(conn)

    ann, bob, reports, deliveries = _run(base, work)
    assert (ann.first, bob.first) == (True, True)
    assert [(r[0], r[2], r[3]) for r in reports] == [
        (ANN, SONG, 150_000),
        (BOB, OTHER, 20_000),
    ]
    assert [d[0] for d in deliveries] == [ANN]


def test_same_number_for_another_song_is_refused(base: str) -> None:
    listen = uuid4()

    async def work(conn: asyncpg.Connection) -> Any:
        await _connect(conn)
        await _say(conn, listen, 40_000)
        said = await _say(conn, listen, 190_000, track_id=OTHER)
        return said, await _reports(conn), await _deliveries(conn)

    said, reports, deliveries = _run(base, work)
    assert said is None, "id already taken by another song — not stored"
    assert reports == [(ANN, listen, SONG, 40_000, STARTED)]
    assert deliveries == []


def test_negative_listened_is_an_error_before_any_write(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> Any:
        with pytest.raises(ValueError):
            await _say(conn, uuid4(), -1)
        with pytest.raises(ValueError):
            await _say(conn, uuid4(), -1, paused=True)
        return await _reports(conn)

    assert _run(base, work) == []


def test_delivery_and_listen_are_written_together_or_not_at_all(base: str) -> None:
    listen = uuid4()

    async def work(conn: asyncpg.Connection) -> Any:
        await _connect(conn)
        await conn.execute("ALTER TABLE play_deliveries RENAME TO play_deliveries_away")
        try:
            with pytest.raises(asyncpg.PostgresError):
                await _say(conn, listen, 150_000)
            below = await _say(conn, uuid4(), 1_000)
        finally:
            await conn.execute(
                "ALTER TABLE play_deliveries_away RENAME TO play_deliveries"
            )
        return below, [r[1] for r in await _reports(conn)]

    below, listens = _run(base, work)
    assert below is not None
    assert listen not in listens, (
        "playback stored but dispatch lost is impossible"
    )
    assert len(listens) == 1


def test_repeat_after_a_failed_write_queues_the_delivery(base: str) -> None:
    listen = uuid4()

    async def work(conn: asyncpg.Connection) -> Any:
        await _connect(conn)
        await conn.execute("ALTER TABLE play_deliveries RENAME TO play_deliveries_away")
        try:
            with pytest.raises(asyncpg.PostgresError):
                await _say(conn, listen, 150_000)
        finally:
            await conn.execute(
                "ALTER TABLE play_deliveries_away RENAME TO play_deliveries"
            )
        said = await _say(conn, listen, 150_000)
        return said.first, said.queued

    assert _run(base, work) == (True, ("listenbrainz",))


# --- "do not record" --------------------------------------------------------


def test_paused_writes_nothing(base: str) -> None:
    listen = uuid4()

    async def work(conn: asyncpg.Connection) -> Any:
        await _connect(conn)
        said = await _say(conn, listen, 150_000, paused=True)
        return said, await _reports(conn), await _deliveries(conn)

    assert _run(base, work) == (None, [], [])


def test_report_made_before_the_pause_and_arriving_during_it_is_lost(base: str) -> None:
    listen = uuid4()

    async def work(conn: asyncpg.Connection) -> Any:
        await _connect(conn)
        await _say(conn, listen, 40_000)
        said = await _say(conn, listen, 150_000, paused=True)
        return said, await _reports(conn), await _deliveries(conn)

    said, reports, deliveries = _run(base, work)
    assert said is None
    assert reports == [(ANN, listen, SONG, 40_000, STARTED)], (
        "err on the side of 'do not record'"
    )
    assert deliveries == []


def test_pause_drops_everything_not_yet_sent(base: str) -> None:
    ids = {
        state: uuid4() for state in ("waiting", "retry", "working", "sent", "refused")
    }
    bobs = uuid4()

    async def work(conn: asyncpg.Connection) -> Any:
        for state, listen in ids.items():
            await _put(conn, listen, state)
        await _put(conn, bobs, "waiting", user=BOB)
        dropped = await drop_waiting(conn, ANN)
        left = {(d[0], d[3]) for d in await _deliveries(conn)}
        return dropped, left, len(await _reports(conn))

    dropped, left, reports = _run(base, work)
    # Work in progress is also cancelled (FT-641): pass takes up to 20 rows and sends
    # them one by one — without this they would go out after pause.
    assert dropped == 3
    assert left == {
        (ANN, "dropped"),
        (ANN, "sent"),
        (ANN, "refused"),
        (BOB, "waiting"),
    }
    assert reports == 6, "pause does not erase playback itself"


def test_dropped_delivery_is_not_queued_again_when_the_pause_is_over(base: str) -> None:
    listen = uuid4()

    async def work(conn: asyncpg.Connection) -> Any:
        await _connect(conn)
        await _say(conn, listen, 150_000)
        await drop_waiting(conn, ANN)
        # Pause off, same song still playing — phone continues reporting.
        said = await _say(conn, listen, 190_000)
        return said.queued, [d[3] for d in await _deliveries(conn)]

    assert _run(base, work) == ((), ["dropped"]), (
        "'do not record' is not revoked retroactively"
    )


# --- connection revision ---------------------------------------------------


def test_any_token_write_is_a_new_revision_and_a_bad_mark_is_not(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> Any:
        first = await _connect(conn)
        same_token = await _connect(conn)
        await conn.execute(
            "UPDATE scrobble_accounts SET bad = true, updated_at = now()"
        )
        marked = await conn.fetchval("SELECT revision FROM scrobble_accounts")
        await conn.execute("DELETE FROM scrobble_accounts")
        again = await _connect(conn)
        other = await _connect(conn, user=BOB)
        return first, same_token, marked, again, other

    first, same_token, marked, again, other = _run(base, work)
    assert same_token > first, "same key written again is a new revision"
    assert marked == same_token, "bad token mark does not change revision"
    assert again > same_token, "disconnect and reconnect is a new revision"
    assert other > again and other != again


def test_outdated_deliveries_are_dropped(base: str) -> None:
    kept, stale, gone, taken, done = uuid4(), uuid4(), uuid4(), uuid4(), uuid4()

    async def work(conn: asyncpg.Connection) -> Any:
        current = await _connect(conn)
        await _put(conn, kept, "waiting", revision=current)
        await _put(conn, stale, "retry", revision=current - 1)
        await _put(
            conn, gone, "waiting", service="lastfm", revision=current
        )  # Last.fm not connected
        await _put(conn, taken, "working", revision=current - 1)
        await _put(conn, done, "sent", revision=current - 1)
        # Bob has same revision number, but no connection.
        await _put(conn, kept, "waiting", user=BOB, revision=current)
        dropped = await drop_outdated(conn)
        return dropped, {(d[0], d[1], d[2]) for d in await _deliveries(conn)}

    dropped, left = _run(base, work)
    assert dropped == 3
    assert left == {
        (ANN, kept, "listenbrainz"),
        (ANN, taken, "listenbrainz"),
        (ANN, done, "listenbrainz"),
    }, "in-progress verifies revision in sender itself; sent is delivery history"


def test_report_after_a_new_key_uses_the_new_revision(base: str) -> None:
    listen = uuid4()

    async def work(conn: asyncpg.Connection) -> Any:
        await _connect(conn)
        await _say(conn, listen, 150_000)
        current = await _connect(conn)
        await drop_outdated(conn)
        empty = await _deliveries(conn)
        other = uuid4()
        await _say(conn, other, 150_000)
        return empty, current, await _deliveries(conn), other

    empty, current, deliveries, other = _run(base, work)
    assert empty == []
    assert deliveries == [(ANN, other, "listenbrainz", "waiting", current)]


# --- retention period ----------------------------------------------------------


def test_report_waits_for_a_key_change_in_flight_and_takes_the_new_revision(
    base: str,
) -> None:
    listen = uuid4()

    async def go() -> Any:
        person, phone = await asyncpg.connect(base), await asyncpg.connect(base)
        try:
            old = await _connect(person)
            changing = person.transaction()
            await changing.start()
            new = await _connect(person)
            saying = asyncio.ensure_future(_say(phone, listen, 150_000))
            await asyncio.sleep(0.3)
            waited = not saying.done()
            await changing.commit()
            said = await saying
            return old, new, waited, said.queued, await _deliveries(person)
        finally:
            await person.close()
            await phone.close()

    old, new, waited, queued, deliveries = asyncio.run(go())
    assert new > old
    assert waited, "report does not read connection currently being changed"
    assert queued == ("listenbrainz",)
    assert deliveries == [(ANN, listen, "listenbrainz", "waiting", new)]


def test_purge_removes_old_unsent_deliveries_and_very_old_listens(base: str) -> None:
    ids = {
        name: uuid4()
        for name in (
            "fresh", "edge", "old_sent", "old_waiting", "ancient",
            "old_refused", "old_dropped", "old_working",
        )
    }  # fmt: skip

    async def work(conn: asyncpg.Connection) -> Any:
        day = timedelta(days=1)
        second = timedelta(seconds=1)
        await _put(conn, ids["fresh"], "waiting", created=NOW - day)
        await _put(conn, ids["edge"], "retry", created=NOW - 14 * day)
        await _put(conn, ids["old_sent"], "sent", created=NOW - 14 * day - second)
        await _put(conn, ids["old_waiting"], "waiting", created=NOW - 20 * day)
        await _put(conn, ids["ancient"], "refused", created=NOW - 30 * day - second)
        await _put(conn, ids["old_refused"], "refused", created=NOW - 20 * day)
        await _put(conn, ids["old_dropped"], "dropped", created=NOW - 20 * day)
        await _put(conn, ids["old_working"], "working", created=NOW - 20 * day)
        gone = await purge(conn, now=NOW)
        return (
            gone,
            {d[1] for d in await _deliveries(conn)},
            {r[1] for r in await _reports(conn)},
        )

    gone, deliveries, reports = _run(base, work)
    names = {value: name for name, value in ids.items()}
    assert gone == 3, "waiting, dropped by pause and hung in working"
    assert {names[d] for d in deliveries} == {
        "fresh",
        "edge",
        "old_sent",
        "old_refused",
    }, (
        "sent and refused live as long as playback lives: repeat report will not resend them"
    )
    assert {names[r] for r in reports} == set(ids) - {"ancient"}, (
        "playback lives 30 days: late duplicate report must not become new"
    )


def test_late_repeat_does_not_send_a_delivered_listen_again(base: str) -> None:
    listen = uuid4()

    async def work(conn: asyncpg.Connection) -> Any:
        await _connect(conn)
        await _say(conn, listen, 150_000, now=NOW - timedelta(days=15))
        await conn.execute("UPDATE play_deliveries SET state = 'sent'")
        await purge(conn, now=NOW)
        said = await _say(conn, listen, 150_000)
        return said.queued, [d[3] for d in await _deliveries(conn)]

    assert _run(base, work) == ((), ["sent"])


def test_removing_a_listen_removes_its_deliveries(base: str) -> None:
    listen = uuid4()

    async def work(conn: asyncpg.Connection) -> Any:
        await _put(conn, listen, "waiting")
        await _put(conn, uuid4(), "sent", user=BOB)
        # That is how an entire user leaves: their rows are removed by user_id.
        await conn.execute("DELETE FROM play_reports WHERE user_id = $1", ANN)
        return [d[0] for d in await _deliveries(conn)]

    assert _run(base, work) == [BOB]


# --- log -----------------------------------------------------------------


def test_nothing_personal_in_the_log(
    base: str, caplog: pytest.LogCaptureFixture
) -> None:
    listen = uuid4()

    async def work(conn: asyncpg.Connection) -> Any:
        await _connect(conn)
        await _say(conn, listen, 150_000)
        await _say(conn, listen, 160_000, track_id=OTHER)
        await drop_waiting(conn, ANN)
        await drop_outdated(conn)
        await purge(conn, now=NOW)

    with caplog.at_level(logging.DEBUG):
        _run(base, work)
    text = caplog.text
    for secret in (str(listen), SONG, OTHER, str(ANN), "token-one"):
        assert secret not in text
