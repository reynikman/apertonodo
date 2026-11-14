"""FT-641 (Р-A96, Contract D1, clauses 10–12): playback queue sender.

FT-639 puts an "enqueue this playback to service" row. Here is the worker draining the queue:
takes rows into work, checks the key, sends, and records the outcome. Before this card ListenBrainz received
playback via a single request, and network failure lost it.

Guarded:
- row is claimed by a single sender; hung in work (server crashed mid-request) returns after 10
  minutes, rather than being lost;
- key revision is checked before request: replaced or disconnected — row is removed, nothing sent out;
- bad key is not used; "key invalid" response marks connection, but only for the same revision;
- network failure and 5xx — retry with backoff (1, 5, 30 minutes, 2 and 6 hours), not immediately and not never;
- rejection by service on substance — not retried;
- one service goes down — its remaining rows are skipped in this pass, while another service proceeds;
- song start time is sent out, identical across retries;
- late outcome does not overwrite row claimed by another pass;
- log contains only service and outcome keyword.

What tests do not prove: that server invokes the pass on schedule and provides real proxy client
(lead integration, B6); that ListenBrainz deduplicates retries (Contract D1, clause 12 — not guaranteed); Last.fm
(next card).
"""

from __future__ import annotations

import asyncio
import json
import logging
from datetime import UTC, datetime, timedelta
from typing import Any
from uuid import UUID, uuid4

import asyncpg
import httpx
import pytest

from app.migrate import apply
from app.play_sender import (
    BACKOFF,
    LEASE,
    Job,
    Song,
    backoff,
    deliver,
    listenbrainz,
    run_once,
    take,
)
from app.scrobble import LISTENBRAINZ_URL, Listen

NOW = datetime(2026, 10, 6, 12, 0, tzinfo=UTC)
STARTED = NOW - timedelta(minutes=30)
ANN = UUID("aaaaaaaa-0000-4000-8000-000000000001")
BOB = UUID("bbbbbbbb-0000-4000-8000-000000000002")
SONG = "33333333-3333-4333-8333-333333333333"
GONE = "55555555-5555-4555-8555-555555555555"
SONGS = {SONG: Song("Secret Artist", "Secret Title", 200_000)}
MINUTE = timedelta(minutes=1)


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
    token: str = "token-one",
) -> int:
    return int(
        await conn.fetchval(
            """
            INSERT INTO scrobble_accounts (user_id, service, token) VALUES ($1, $2, $3)
            ON CONFLICT (user_id, service) DO UPDATE SET token = EXCLUDED.token, bad = false
            RETURNING revision
            """,
            user,
            service,
            token,
        )
    )


async def _put(
    conn: asyncpg.Connection,
    revision: int,
    *,
    listen: UUID | None = None,
    user: UUID = ANN,
    service: str = "listenbrainz",
    state: str = "waiting",
    attempts: int = 0,
    due: datetime = NOW - MINUTE,
    created: datetime | None = None,
    track: str = SONG,
) -> UUID:
    listen = listen or uuid4()
    await conn.execute(
        "INSERT INTO play_reports VALUES ($1, $2, $3, $4, 150000, 200000, $5) ON CONFLICT DO NOTHING",
        user, listen, track, STARTED, created or due,
    )  # fmt: skip
    await conn.execute(
        "INSERT INTO play_deliveries (user_id, listen_id, service, account_revision, state, attempts,"
        " next_try_at, created_at) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
        user, listen, service, revision, state, attempts, due, created or due,
    )  # fmt: skip
    return listen


async def _rows(
    conn: asyncpg.Connection,
) -> dict[tuple[UUID, str], tuple[str, int, datetime]]:
    rows = await conn.fetch(
        "SELECT listen_id, service, state, attempts, next_try_at FROM play_deliveries"
    )
    return {
        (r["listen_id"], r["service"]): (r["state"], r["attempts"], r["next_try_at"])
        for r in rows
    }


class _Sender:
    def __init__(self, *words: str) -> None:
        self.words = list(words) or ["sent"]
        self.calls: list[tuple[str, Listen]] = []
        self.before: Any = None

    async def __call__(self, token: str, listen: Listen) -> str:
        self.calls.append((token, listen))
        if self.before is not None:
            await self.before()
        word = self.words[min(len(self.calls), len(self.words)) - 1]
        if word == "boom":
            raise RuntimeError("Secret Artist exploded")
        return word


async def _lookup(track_id: str) -> Song | None:
    return SONGS.get(track_id)


async def _pass(
    conn: asyncpg.Connection, sender: Any, *, now: datetime = NOW, **more: Any
) -> dict[str, int]:
    senders = more.pop("senders", {"listenbrainz": sender})
    return await run_once(
        conn, senders=senders, lookup=more.pop("lookup", _lookup), now=now, **more
    )


# --- backoff between retries --------------------------------------------------


def test_backoff_grows_and_stops_at_six_hours() -> None:
    assert [backoff(n) for n in range(1, 8)] == [
        timedelta(minutes=1),
        timedelta(minutes=5),
        timedelta(minutes=30),
        timedelta(hours=2),
        timedelta(hours=6),
        timedelta(hours=6),
        timedelta(hours=6),
    ]
    assert backoff(0) == timedelta(minutes=1)
    assert tuple(BACKOFF) == tuple(backoff(n) for n in range(1, 6))
    assert LEASE == timedelta(minutes=10)


# --- take into work ---------------------------------------------------------


def test_take_marks_working_counts_the_attempt_and_sets_a_lease(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> Any:
        revision = await _connect(conn)
        listen = await _put(conn, revision)
        jobs = await take(conn, now=NOW)
        return revision, listen, jobs, await _rows(conn)

    revision, listen, jobs, rows = _run(base, work)
    assert jobs == [Job(ANN, listen, "listenbrainz", revision, 1, SONG, STARTED)]
    assert rows == {(listen, "listenbrainz"): ("working", 1, NOW + LEASE)}


def test_take_skips_what_is_not_due_or_finished(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> Any:
        revision = await _connect(conn)
        due_retry = await _put(conn, revision, state="retry", attempts=2, due=NOW)
        await _put(
            conn, revision, state="retry", attempts=2, due=NOW + timedelta(seconds=1)
        )
        await _put(conn, revision, state="working", attempts=1, due=NOW + MINUTE)
        for state in ("sent", "refused", "dropped"):
            await _put(conn, revision, state=state)
        jobs = await take(conn, now=NOW)
        return due_retry, [(j.listen_id, j.attempts) for j in jobs]

    due_retry, taken = _run(base, work)
    assert taken == [(due_retry, 3)]


def test_delivery_stuck_in_work_comes_back_after_the_lease(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> Any:
        revision = await _connect(conn)
        listen = await _put(conn, revision)
        first = await take(conn, now=NOW)
        # Server crashed mid-request: outcome was not recorded.
        early = await take(conn, now=NOW + LEASE - timedelta(seconds=1))
        late = await take(conn, now=NOW + LEASE)
        return listen, first, early, [(j.listen_id, j.attempts) for j in late]

    listen, first, early, late = _run(base, work)
    assert len(first) == 1
    assert early == []
    assert late == [(listen, 2)]


def test_take_is_oldest_first_and_limited(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> Any:
        revision = await _connect(conn)
        ids = [await _put(conn, revision, due=NOW - (5 - i) * MINUTE) for i in range(5)]
        first = await take(conn, now=NOW, limit=2)
        second = await take(conn, now=NOW, limit=10)
        return ids, [j.listen_id for j in first], [j.listen_id for j in second]

    ids, first, second = _run(base, work)
    assert first == ids[:2]
    assert second == ids[2:]


def test_two_senders_never_take_the_same_delivery(base: str) -> None:
    async def go() -> Any:
        conns = [await asyncpg.connect(base) for _ in range(4)]
        try:
            revision = await _connect(conns[0])
            for _ in range(12):
                await _put(conns[0], revision)
            taken = await asyncio.gather(
                *(take(conn, now=NOW, limit=5) for conn in conns)
            )
            return [j.listen_id for jobs in taken for j in jobs]
        finally:
            for conn in conns:
                await conn.close()

    ids = asyncio.run(go())
    assert len(ids) == len(set(ids)), (
        "single row claimed twice — playback would be sent twice"
    )
    assert len(ids) == 12


# --- dispatch ---------------------------------------------------------------


def test_sent_delivery_is_marked_and_carries_the_start_time(base: str) -> None:
    sender = _Sender("sent")

    async def work(conn: asyncpg.Connection) -> Any:
        revision = await _connect(conn)
        listen = await _put(conn, revision)
        counts = await _pass(conn, sender)
        return listen, counts, await _rows(conn)

    listen, counts, rows = _run(base, work)
    assert counts == {"sent": 1}
    assert sender.calls == [
        ("token-one", Listen("Secret Artist", "Secret Title", 200_000, STARTED))
    ], "song start time is sent outside, not dispatch time"
    assert rows[(listen, "listenbrainz")][:2] == ("sent", 1)


def test_nothing_due_nothing_sent(base: str) -> None:
    sender = _Sender()

    async def work(conn: asyncpg.Connection) -> Any:
        revision = await _connect(conn)
        await _put(conn, revision, due=NOW + MINUTE)
        return await _pass(conn, sender)

    assert _run(base, work) == {}
    assert sender.calls == []


def test_sent_delivery_is_not_sent_again(base: str) -> None:
    sender = _Sender("sent")

    async def work(conn: asyncpg.Connection) -> Any:
        await _put(conn, await _connect(conn))
        await _pass(conn, sender)
        return await _pass(conn, sender, now=NOW + timedelta(days=1))

    assert _run(base, work) == {}
    assert len(sender.calls) == 1


@pytest.mark.parametrize(
    ("attempts", "pause"),
    [(0, BACKOFF[0]), (1, BACKOFF[1]), (2, BACKOFF[2]), (9, BACKOFF[4])],
)
def test_network_failure_is_retried_later_with_a_growing_pause(
    base: str, attempts: int, pause: timedelta
) -> None:
    sender = _Sender("retry")

    async def work(conn: asyncpg.Connection) -> Any:
        listen = await _put(
            conn,
            await _connect(conn),
            state="retry" if attempts else "waiting",
            attempts=attempts,
        )
        counts = await _pass(conn, sender)
        soon = await _pass(conn, sender, now=NOW + pause - timedelta(seconds=1))
        return listen, counts, soon, await _rows(conn)

    listen, counts, soon, rows = _run(base, work)
    assert counts == {"retry": 1}
    assert rows[(listen, "listenbrainz")] == ("retry", attempts + 1, NOW + pause)
    assert soon == {}, "do not query ahead of time"
    assert len(sender.calls) == 1


def test_retried_delivery_goes_out_when_due_with_the_same_time(base: str) -> None:
    sender = _Sender("retry", "sent")

    async def work(conn: asyncpg.Connection) -> Any:
        listen = await _put(conn, await _connect(conn))
        await _pass(conn, sender)
        counts = await _pass(conn, sender, now=NOW + BACKOFF[0])
        return listen, counts, await _rows(conn)

    listen, counts, rows = _run(base, work)
    assert counts == {"sent": 1}
    assert rows[(listen, "listenbrainz")][:2] == ("sent", 2)
    assert sender.calls[0] == sender.calls[1], "retry — with same data (Contract D1, clause 12)"


def test_sender_exception_and_unknown_word_are_retries(base: str) -> None:
    async def work(conn: asyncpg.Connection) -> Any:
        revision = await _connect(conn)
        one = await _put(conn, revision)
        boom = await _pass(conn, _Sender("boom"))
        two = await _put(conn, revision)
        odd = await _pass(conn, _Sender("maybe"), now=NOW + timedelta(seconds=1))
        return one, two, boom, odd, await _rows(conn)

    one, two, boom, odd, rows = _run(base, work)
    assert (boom, odd) == ({"retry": 1}, {"retry": 1})
    assert rows[(one, "listenbrainz")][0] == "retry"
    assert rows[(two, "listenbrainz")][0] == "retry"


def test_refusal_is_final(base: str) -> None:
    sender = _Sender("refused")

    async def work(conn: asyncpg.Connection) -> Any:
        listen = await _put(conn, await _connect(conn))
        counts = await _pass(conn, sender)
        later = await _pass(conn, sender, now=NOW + timedelta(days=2))
        bad = await conn.fetchval("SELECT bad FROM scrobble_accounts")
        return listen, counts, later, bad, await _rows(conn)

    listen, counts, later, bad, rows = _run(base, work)
    assert (counts, later) == ({"refused": 1}, {})
    assert rows[(listen, "listenbrainz")][0] == "refused"
    assert bad is False, "service rejected record, not key"
    assert len(sender.calls) == 1


def test_song_no_longer_known_is_refused_without_a_request(base: str) -> None:
    sender = _Sender()

    async def work(conn: asyncpg.Connection) -> Any:
        listen = await _put(conn, await _connect(conn), track=GONE)
        return listen, await _pass(conn, sender), await _rows(conn)

    listen, counts, rows = _run(base, work)
    assert counts == {"no_song": 1}
    assert rows[(listen, "listenbrainz")][0] == "refused"
    assert sender.calls == []


def test_lookup_failure_is_a_retry(base: str) -> None:
    sender = _Sender()

    async def broken(track_id: str) -> Song | None:
        raise RuntimeError("catalog is down")

    async def work(conn: asyncpg.Connection) -> Any:
        listen = await _put(conn, await _connect(conn))
        return listen, await _pass(conn, sender, lookup=broken), await _rows(conn)

    listen, counts, rows = _run(base, work)
    assert counts == {"retry": 1}
    assert rows[(listen, "listenbrainz")] == ("retry", 1, NOW + BACKOFF[0])
    assert sender.calls == []


def test_service_without_a_sender_waits(base: str) -> None:
    sender = _Sender()

    async def work(conn: asyncpg.Connection) -> Any:
        revision = await _connect(conn, service="lastfm")
        listen = await _put(conn, revision, service="lastfm")
        return listen, await _pass(conn, sender), await _rows(conn)

    listen, counts, rows = _run(base, work)
    assert counts == {"no_sender": 1}
    assert rows[(listen, "lastfm")] == ("retry", 1, NOW + BACKOFF[0]), (
        "Last.fm is not configured on this server"
    )
    assert sender.calls == []


# --- key and revision --------------------------------------------------------


def test_delivery_of_an_old_revision_is_removed_without_a_request(base: str) -> None:
    sender = _Sender()

    async def work(conn: asyncpg.Connection) -> Any:
        old = await _connect(conn)
        await _put(conn, old)
        await _connect(conn, token="token-two")
        return await _pass(conn, sender), await _rows(conn)

    assert _run(base, work) == ({"outdated": 1}, {})
    assert sender.calls == [], (
        "old work with new key does not continue (Contract D1, clause 11)"
    )


def test_delivery_of_a_disconnected_service_is_removed(base: str) -> None:
    sender = _Sender()

    async def work(conn: asyncpg.Connection) -> Any:
        await _put(conn, await _connect(conn))
        await conn.execute("DELETE FROM scrobble_accounts")
        return (
            await _pass(conn, sender),
            await _rows(conn),
            await conn.fetchval("SELECT count(*) FROM play_reports"),
        )

    assert _run(base, work) == ({"outdated": 1}, {}, 1)
    assert sender.calls == []


def test_token_of_another_person_is_never_used(base: str) -> None:
    sender = _Sender()

    async def work(conn: asyncpg.Connection) -> Any:
        ann = await _connect(conn, user=ANN, token="token-ann")
        bob = await _connect(conn, user=BOB, token="token-bob")
        await _put(conn, ann, user=ANN, due=NOW - 2 * MINUTE)
        await _put(conn, bob, user=BOB, due=NOW - MINUTE)
        return await _pass(conn, sender)

    assert _run(base, work) == {"sent": 2}
    assert [token for token, _ in sender.calls] == ["token-ann", "token-bob"]


def test_bad_token_is_not_used(base: str) -> None:
    sender = _Sender()

    async def work(conn: asyncpg.Connection) -> Any:
        listen = await _put(conn, await _connect(conn))
        await conn.execute("UPDATE scrobble_accounts SET bad = true")
        return listen, await _pass(conn, sender), await _rows(conn)

    listen, counts, rows = _run(base, work)
    assert counts == {"bad_token": 1}
    assert rows[(listen, "listenbrainz")][0] == "refused"
    assert sender.calls == []


def test_rejected_token_marks_the_account_and_stops_the_rest(base: str) -> None:
    sender = _Sender("bad_token")

    async def work(conn: asyncpg.Connection) -> Any:
        revision = await _connect(conn)
        first = await _put(conn, revision, due=NOW - 2 * MINUTE)
        second = await _put(conn, revision, due=NOW - MINUTE)
        counts = await _pass(conn, sender)
        account = await conn.fetchrow("SELECT bad, revision FROM scrobble_accounts")
        return (
            revision,
            first,
            second,
            counts,
            tuple(account.values()),
            await _rows(conn),
        )

    revision, first, second, counts, account, rows = _run(base, work)
    assert counts == {"bad_token": 2}
    assert len(sender.calls) == 1, "after key refusal second request with it is not sent"
    assert account == (True, revision), "marking does not change revision"
    assert {rows[(first, "listenbrainz")][0], rows[(second, "listenbrainz")][0]} == {
        "refused"
    }


def test_late_rejection_does_not_mark_a_freshly_replaced_key(base: str) -> None:
    sender = _Sender("bad_token")

    async def go() -> Any:
        conn, person = await asyncpg.connect(base), await asyncpg.connect(base)
        try:
            await _put(conn, await _connect(conn))

            async def replace() -> None:
                # While request with old key was in flight, user entered a new one.
                await _connect(person, token="token-two")

            sender.before = replace
            counts = await _pass(conn, sender)
            return counts, await conn.fetchval("SELECT bad FROM scrobble_accounts")
        finally:
            await conn.close()
            await person.close()

    counts, bad = asyncio.run(go())
    assert counts == {"bad_token": 1}
    assert bad is False, "refusal pertained to previous key"


# --- one goes down — others proceed -------------------------------------------------


def test_after_one_failure_the_rest_of_that_service_is_not_hammered(base: str) -> None:
    down, up = _Sender("retry"), _Sender("sent")

    async def work(conn: asyncpg.Connection) -> Any:
        lb = await _connect(conn, service="listenbrainz")
        fm = await _connect(conn, service="lastfm")
        first = await _put(conn, lb, due=NOW - 4 * MINUTE)
        other = await _put(conn, fm, service="lastfm", due=NOW - 3 * MINUTE)
        second = await _put(conn, lb, due=NOW - 2 * MINUTE, state="retry", attempts=3)
        third = await _put(conn, lb, due=NOW - MINUTE)
        counts = await _pass(conn, None, senders={"listenbrainz": down, "lastfm": up})
        return first, other, second, third, counts, await _rows(conn)

    first, other, second, third, counts, rows = _run(base, work)
    assert counts == {"retry": 1, "sent": 1, "skipped": 2}
    assert len(down.calls) == 1, "down service is not called again in this pass"
    assert len(up.calls) == 1, "failure of one recipient does not delay another"
    assert rows[(first, "listenbrainz")] == ("retry", 1, NOW + BACKOFF[0])
    assert rows[(other, "lastfm")][0] == "sent"
    assert rows[(second, "listenbrainz")] == ("retry", 3, NOW + BACKOFF[0]), (
        "skipping is not an attempt"
    )
    assert rows[(third, "listenbrainz")] == ("retry", 0, NOW + BACKOFF[0])


def test_result_that_arrives_after_the_lease_does_not_touch_a_retaken_delivery(
    base: str,
) -> None:
    async def go() -> Any:
        conn, other = await asyncpg.connect(base), await asyncpg.connect(base)
        try:
            listen = await _put(conn, await _connect(conn))
            slow = (await take(conn, now=NOW))[0]
            sender = _Sender("retry")
            taken: list[Any] = []

            async def retake() -> None:
                # Request hung longer than lease: row claimed by another pass.
                taken.extend(await take(other, now=NOW + LEASE))

            sender.before = retake
            word = await deliver(
                conn,
                slow,
                senders={"listenbrainz": sender},
                lookup=_lookup,
                now=NOW + LEASE,
            )
            return listen, taken[0].attempts, word, await _rows(conn)
        finally:
            await conn.close()
            await other.close()

    listen, attempts, word, rows = asyncio.run(go())
    assert (attempts, word) == (2, "retry")
    assert rows[(listen, "listenbrainz")] == ("working", 2, NOW + LEASE + LEASE), (
        "outcome of late pass does not overwrite row claimed by another"
    )


@pytest.mark.parametrize("word", ["retry", "sent", "refused", "bad_token"])
def test_result_does_not_revive_a_delivery_dropped_by_the_pause(
    base: str, word: str
) -> None:
    sender = _Sender(word)

    async def go() -> Any:
        conn, person = await asyncpg.connect(base), await asyncpg.connect(base)
        try:
            listen = await _put(conn, await _connect(conn))

            async def pause() -> None:
                # While request was in flight, user enabled 'do not record': attempt count unchanged.
                await person.execute("UPDATE play_deliveries SET state = 'dropped'")

            sender.before = pause
            await _pass(conn, sender)
            return listen, await _rows(conn)
        finally:
            await conn.close()
            await person.close()

    listen, rows = asyncio.run(go())
    assert rows[(listen, "listenbrainz")] == ("dropped", 1, NOW + LEASE), (
        "row dropped by pause is not restored to queue by outcome of late request"
    )


def test_skip_does_not_revive_a_delivery_dropped_by_the_pause(base: str) -> None:
    down = _Sender("retry")

    async def go() -> Any:
        conn, person = await asyncpg.connect(base), await asyncpg.connect(base)
        try:
            revision = await _connect(conn)
            await _put(conn, revision, due=NOW - 2 * MINUTE)
            second = await _put(conn, revision, due=NOW - MINUTE)

            async def pause() -> None:
                await person.execute(
                    "UPDATE play_deliveries SET state = 'dropped' WHERE listen_id = $1",
                    second,
                )

            down.before = pause
            await _pass(conn, down)
            return second, await _rows(conn)
        finally:
            await conn.close()
            await person.close()

    second, rows = asyncio.run(go())
    assert rows[(second, "listenbrainz")] == ("dropped", 1, NOW + LEASE)


def test_delivery_no_longer_ours_is_not_sent(base: str) -> None:
    sender = _Sender("sent")

    async def go() -> Any:
        conn, other = await asyncpg.connect(base), await asyncpg.connect(base)
        try:
            revision = await _connect(conn)
            paused = await _put(conn, revision, due=NOW - 3 * MINUTE)
            retaken = await _put(conn, revision, due=NOW - 2 * MINUTE)
            jobs = await take(conn, now=NOW)
            # While pass sent former rows: one dropped by pause, another taken by another pass.
            await other.execute(
                "UPDATE play_deliveries SET state = 'dropped' WHERE listen_id = $1",
                paused,
            )
            await take(other, now=NOW + LEASE)
            words = [
                await deliver(
                    conn,
                    job,
                    senders={"listenbrainz": sender},
                    lookup=_lookup,
                    now=NOW + LEASE,
                )
                for job in jobs
            ]
            return paused, retaken, words, await _rows(conn)
        finally:
            await conn.close()
            await other.close()

    paused, retaken, words, rows = asyncio.run(go())
    assert words == ["outdated", "outdated"]
    assert sender.calls == [], "row no longer ours — nothing goes outside"
    assert rows[(paused, "listenbrainz")] == ("dropped", 1, NOW + LEASE)
    assert rows[(retaken, "listenbrainz")] == ("working", 2, NOW + LEASE + LEASE)


def test_database_failure_on_one_delivery_does_not_stop_the_pass(base: str) -> None:
    sender = _Sender("sent")

    async def work(conn: asyncpg.Connection) -> Any:
        revision = await _connect(conn)
        first = await _put(conn, revision, due=NOW - 2 * MINUTE)
        second = await _put(conn, revision, due=NOW - MINUTE)
        # Recording outcome of first row fails in DB; second must go as usual.
        await conn.execute(
            f"""
            CREATE FUNCTION ft641_poison() RETURNS trigger AS $$
            BEGIN
                IF NEW.listen_id = '{first}' AND NEW.state = 'sent' THEN
                    RAISE EXCEPTION 'poisoned';
                END IF;
                RETURN NEW;
            END $$ LANGUAGE plpgsql;
            CREATE TRIGGER ft641_poison BEFORE UPDATE ON play_deliveries
                FOR EACH ROW EXECUTE FUNCTION ft641_poison();
            """
        )
        try:
            counts = await _pass(conn, sender)
        finally:
            await conn.execute(
                "DROP TRIGGER ft641_poison ON play_deliveries; DROP FUNCTION ft641_poison()"
            )
        return first, second, counts, await _rows(conn)

    first, second, counts, rows = _run(base, work)
    assert counts == {"failed": 1, "sent": 1}
    assert rows[(first, "listenbrainz")][0] == "working", "will return after lease"
    assert rows[(second, "listenbrainz")][0] == "sent"


# --- ListenBrainz -----------------------------------------------------------


def _client(handler: Any) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


@pytest.mark.parametrize(
    ("status", "word"),
    [
        (200, "sent"),
        (401, "bad_token"),
        (400, "refused"),
        (429, "retry"),
        (500, "retry"),
        (503, "retry"),
        (404, "retry"),
    ],
)
def test_listenbrainz_answer_becomes_a_word(status: int, word: str) -> None:
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(status, json={"status": "ok"})

    async def go() -> str:
        async with _client(handler) as client:
            return await listenbrainz(client)(
                "token-one", Listen("Artist", "Title", 200_000, STARTED)
            )

    assert asyncio.run(go()) == word
    request = seen[0]
    assert str(request.url) == LISTENBRAINZ_URL
    assert request.headers["authorization"] == "Token token-one"
    body = json.loads(request.content)
    assert body["listen_type"] == "single"
    assert body["payload"][0]["listened_at"] == int(STARTED.timestamp())
    assert body["payload"][0]["track_metadata"]["artist_name"] == "Artist"
    assert body["payload"][0]["track_metadata"]["track_name"] == "Title"


def test_listenbrainz_network_error_is_a_retry() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("no route to https://secret.example/token-one")

    async def go() -> str:
        async with _client(handler) as client:
            return await listenbrainz(client)(
                "token-one", Listen("Artist", "Title", 200_000, STARTED)
            )

    assert asyncio.run(go()) == "retry"


# --- log -----------------------------------------------------------------


def test_log_has_the_service_and_the_word_and_nothing_personal(
    base: str, caplog: pytest.LogCaptureFixture
) -> None:
    listens: list[UUID] = []

    async def work(conn: asyncpg.Connection) -> Any:
        revision = await _connect(conn)
        listens.append(await _put(conn, revision, due=NOW - 3 * MINUTE))
        listens.append(await _put(conn, revision, due=NOW - 2 * MINUTE))
        await _pass(conn, _Sender("sent", "boom"))

    with caplog.at_level(logging.DEBUG):
        _run(base, work)
    text = caplog.text
    assert "play delivery listenbrainz sent" in text
    assert "play delivery listenbrainz retry" in text
    for secret in (
        "Secret",
        "token-one",
        SONG,
        str(ANN),
        "exploded",
        *(str(x) for x in listens),
    ):
        assert secret not in text
