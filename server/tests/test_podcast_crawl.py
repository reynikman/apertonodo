"""FT-660 (Р-A93, block B-5): podcast feed crawler.

The store (FT-657) knows which feed is due for fetching; parser (FT-654) converts
bytes into a podcast. Here is a single pass: take feeds that are due, fetch,
parse, save; record failures and proceed. There is no network in tests:
fetching is mocked.

Contract of the `app/podcast_crawl.py` module:
- `MAX_FEED_BYTES = 8 MiB`, `FEED_TIMEOUT_S = 30.0`, `PER_PASS = 20`;
- `class FeedUnavailable(Exception)`;
- `async default_fetch(url) -> bytes` — via `app.news_fetch.fetch`;
- `async refresh_one(conn, feed_url, *, fetch=default_fetch, now=None)
   -> "saved" | "failed" | "not_a_feed" | "bad_url"`;
- `async run_once(conn, *, fetch=default_fetch, now=None, limit=PER_PASS)
   -> {"saved": n, "failed": n, "not_a_feed": n}`.

What tests do not prove: that the pass is run periodically on a schedule
(wiring by lead), that real feed from the web is fetched, and parsing speed
of a large feed.
"""

from __future__ import annotations

import asyncio
import logging
import threading
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any
from uuid import UUID

import asyncpg
import httpx
import pytest

from app import news_fetch, podcast_crawl, podcasts
from app.migrate import apply
from app.podcast_crawl import (
    FEED_TIMEOUT_S,
    MAX_FEED_BYTES,
    PER_PASS,
    FeedUnavailable,
    default_fetch,
    refresh_one,
    run_once,
)
from app.podcasts import REFRESH_EVERY, backoff, episodes, subscribe, subscriptions

NOW = datetime(2026, 10, 7, 12, 0, tzinfo=UTC)
ANN = UUID("aaaaaaaa-0000-4000-8000-000000000001")
FEED = "https://pod.example.org/feed.xml"
OTHER = "https://other.example.org/rss"
THIRD = "https://third.example.org/rss"


def rss(*titles: str, title: str = "Подкаст") -> bytes:
    items = "".join(
        f"<item><title>{t}</title><guid>g-{t}</guid>"
        f'<enclosure url="https://cdn.example.org/{n}.mp3" type="audio/mpeg" length="100"/>'
        f"<pubDate>Mon, 0{n + 1} Sep 2026 10:00:00 GMT</pubDate></item>"
        for n, t in enumerate(titles)
    )
    return (
        '<?xml version="1.0" encoding="UTF-8"?><rss version="2.0">'
        f"<channel><title>{title}</title>{items}</channel></rss>"
    ).encode()


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
        await conn.execute(
            "INSERT INTO users (id, username) VALUES ($1, $2) ON CONFLICT (id) DO NOTHING",
            ANN,
            "ann-ft660",
        )

    _run(postgres_url, prepare)
    return postgres_url


class Net:
    """In-memory fetching: url -> bytes or exception."""

    def __init__(self, **pages: Any) -> None:
        self.pages: dict[str, Any] = dict(pages)
        self.asked: list[str] = []
        self.in_flight = 0
        self.most_in_flight = 0

    async def __call__(self, url: str) -> bytes:
        self.asked.append(url)
        self.in_flight += 1
        self.most_in_flight = max(self.most_in_flight, self.in_flight)
        try:
            await asyncio.sleep(0)
            page = self.pages.get(url, FeedUnavailable())
            if isinstance(page, BaseException):
                raise page
            return page
        finally:
            self.in_flight -= 1


async def feed_row(conn: asyncpg.Connection, url: str = FEED) -> asyncpg.Record | None:
    return await conn.fetchrow(
        "SELECT title, fetched_at, failures, next_fetch_at FROM podcast_feeds WHERE feed_url = $1",
        url,
    )


# --- single feed ---


def test_constants() -> None:
    assert MAX_FEED_BYTES == 8 * 1024 * 1024
    assert FEED_TIMEOUT_S == 30.0
    assert PER_PASS == 20
    assert issubclass(FeedUnavailable, Exception)


def test_feed_is_fetched_parsed_and_saved(base: str) -> None:
    net = Net(**{FEED: rss("один", "два", title="Мой подкаст")})

    async def work(conn: asyncpg.Connection) -> None:
        await subscribe(conn, ANN, FEED, now=NOW)
        assert await refresh_one(conn, FEED, fetch=net, now=NOW) == "saved"
        assert net.asked == [FEED]
        [sub] = await subscriptions(conn, ANN)
        assert (sub.title, sub.episodes) == ("Мой подкаст", 2)
        page = await episodes(conn, ANN, FEED)
        assert page is not None
        assert [e.title for e in page] == ["два", "один"]
        row = await feed_row(conn)
        assert row is not None
        assert row["failures"] == 0
        assert row["fetched_at"] == NOW
        assert row["next_fetch_at"] == NOW + REFRESH_EVERY

    _run(base, work)


@pytest.mark.parametrize(
    "error",
    [
        FeedUnavailable(),
        news_fetch.NewsFetchRefused("внутренний адрес"),
        httpx.ConnectError("нет сети"),
        TimeoutError(),
        OSError("сломалось"),
        ValueError("что угодно"),
    ],
)
def test_fetch_failure_is_remembered_not_raised(base: str, error: Exception) -> None:
    net = Net(**{FEED: error})

    async def work(conn: asyncpg.Connection) -> None:
        await subscribe(conn, ANN, FEED, now=NOW)
        assert await refresh_one(conn, FEED, fetch=net, now=NOW) == "failed"
        row = await feed_row(conn)
        assert row is not None
        assert row["failures"] == 1
        assert row["fetched_at"] is None
        assert row["next_fetch_at"] == NOW + backoff(1)

    _run(base, work)


@pytest.mark.parametrize(
    "body",
    [
        b"",
        b"<html><body>404</body></html>",
        b"\x00\x01\x02 not xml",
        b'{"json": true}',
        b"<rss><nochannel/></rss>",
    ],
)
def test_not_a_feed_is_remembered_as_failure(base: str, body: bytes) -> None:
    net = Net(**{FEED: body})

    async def work(conn: asyncpg.Connection) -> None:
        await subscribe(conn, ANN, FEED, now=NOW)
        assert await refresh_one(conn, FEED, fetch=net, now=NOW) == "not_a_feed"
        row = await feed_row(conn)
        assert row is not None and row["failures"] == 1

    _run(base, work)


def test_failure_keeps_old_episodes_and_success_resets(base: str) -> None:
    net = Net(**{FEED: rss("один")})

    async def work(conn: asyncpg.Connection) -> None:
        await subscribe(conn, ANN, FEED, now=NOW)
        await refresh_one(conn, FEED, fetch=net, now=NOW)
        net.pages[FEED] = b"<html/>"
        later = NOW + timedelta(hours=2)
        assert await refresh_one(conn, FEED, fetch=net, now=later) == "not_a_feed"
        net.pages[FEED] = FeedUnavailable()
        assert await refresh_one(conn, FEED, fetch=net, now=later) == "failed"
        row = await feed_row(conn)
        assert row is not None
        assert row["failures"] == 2
        assert row["fetched_at"] == NOW
        assert row["next_fetch_at"] == later + backoff(2)
        page = await episodes(conn, ANN, FEED)
        assert page is not None and [e.title for e in page] == ["один"]
        net.pages[FEED] = rss("один", "два")
        assert await refresh_one(conn, FEED, fetch=net, now=later) == "saved"
        row = await feed_row(conn)
        assert row is not None and row["failures"] == 0

    _run(base, work)


@pytest.mark.parametrize(
    "bad", ["", "ftp://pod.example.org/f", "https://u:p@pod.example.org/f", "x"]
)
def test_bad_address_is_not_fetched(base: str, bad: str) -> None:
    net = Net()

    async def work(conn: asyncpg.Connection) -> None:
        assert await refresh_one(conn, bad, fetch=net, now=NOW) == "bad_url"
        assert net.asked == []
        assert await conn.fetchval("SELECT count(*) FROM podcast_feeds") == 0

    _run(base, work)


def test_bigger_than_the_bound_is_a_failure(base: str) -> None:
    net = Net(**{FEED: rss("один") + b" " * MAX_FEED_BYTES})

    async def work(conn: asyncpg.Connection) -> None:
        await subscribe(conn, ANN, FEED, now=NOW)
        assert await refresh_one(conn, FEED, fetch=net, now=NOW) == "failed"
        assert await conn.fetchval("SELECT count(*) FROM podcast_episodes") == 0
        row = await feed_row(conn)
        assert row is not None and row["failures"] == 1

    _run(base, work)


@pytest.mark.parametrize("body", [None, "<rss/>", 7, [b"x"]])
def test_fetch_answer_that_is_not_bytes_is_a_failure(base: str, body: Any) -> None:
    async def fetch(url: str) -> Any:
        return body

    async def work(conn: asyncpg.Connection) -> None:
        await subscribe(conn, ANN, FEED, now=NOW)
        assert await refresh_one(conn, FEED, fetch=fetch, now=NOW) == "failed"

    _run(base, work)


def test_slow_feed_is_cut_by_one_deadline(
    base: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(podcast_crawl, "FEED_TIMEOUT_S", 0.05)
    stopped = []

    async def fetch(url: str) -> bytes:
        try:
            await asyncio.sleep(30)
        except asyncio.CancelledError:
            stopped.append(url)
            raise
        return rss("один")

    async def work(conn: asyncpg.Connection) -> None:
        await subscribe(conn, ANN, FEED, now=NOW)
        started = asyncio.get_running_loop().time()
        assert await refresh_one(conn, FEED, fetch=fetch, now=NOW) == "failed"
        assert asyncio.get_running_loop().time() - started < 5
        assert stopped == [FEED]
        row = await feed_row(conn)
        assert row is not None and row["failures"] == 1

    _run(base, work)


def test_cancel_goes_through_and_is_not_a_failure(base: str) -> None:
    entered = asyncio.Event()

    async def fetch(url: str) -> bytes:
        entered.set()
        await asyncio.sleep(30)
        return rss("один")

    async def work(conn: asyncpg.Connection) -> None:
        await subscribe(conn, ANN, FEED, now=NOW)
        task = asyncio.ensure_future(refresh_one(conn, FEED, fetch=fetch, now=NOW))
        await entered.wait()
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert await feed_row(conn) is None

    _run(base, work)


def test_parsing_does_not_block_the_loop(
    base: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    seen: list[bool] = []
    real = podcast_crawl.parse_podcast

    def spy(raw: bytes) -> Any:
        seen.append(threading.current_thread() is threading.main_thread())
        return real(raw)

    monkeypatch.setattr(podcast_crawl, "parse_podcast", spy)
    net = Net(**{FEED: rss("один")})

    async def work(conn: asyncpg.Connection) -> None:
        await subscribe(conn, ANN, FEED, now=NOW)
        assert await refresh_one(conn, FEED, fetch=net, now=NOW) == "saved"

    _run(base, work)
    assert seen == [False]


def test_parser_crash_is_not_a_feed(base: str, monkeypatch: pytest.MonkeyPatch) -> None:
    def boom(raw: bytes) -> Any:
        raise RuntimeError("https://pod.example.org/feed.xml разбор упал")

    monkeypatch.setattr(podcast_crawl, "parse_podcast", boom)
    net = Net(**{FEED: rss("один")})

    async def work(conn: asyncpg.Connection) -> None:
        await subscribe(conn, ANN, FEED, now=NOW)
        assert await refresh_one(conn, FEED, fetch=net, now=NOW) == "not_a_feed"
        row = await feed_row(conn)
        assert row is not None and row["failures"] == 1

    _run(base, work)


def test_now_defaults_to_the_clock(base: str) -> None:
    net = Net(**{FEED: rss("один")})

    async def work(conn: asyncpg.Connection) -> None:
        await subscribe(conn, ANN, FEED)
        before = datetime.now(UTC)
        assert await refresh_one(conn, FEED, fetch=net) == "saved"
        row = await feed_row(conn)
        assert row is not None
        assert before - timedelta(seconds=5) <= row["fetched_at"] <= datetime.now(UTC)

    _run(base, work)


# --- pass ---


def test_pass_takes_only_due_feeds(base: str) -> None:
    net = Net(**{FEED: rss("один"), OTHER: rss("два")})

    async def work(conn: asyncpg.Connection) -> None:
        await subscribe(conn, ANN, FEED, now=NOW)
        assert await run_once(conn, fetch=net, now=NOW) == {
            "saved": 1,
            "failed": 0,
            "not_a_feed": 0,
        }
        await subscribe(conn, ANN, OTHER, now=NOW)
        net.asked.clear()
        soon = NOW + timedelta(minutes=30)
        assert (await run_once(conn, fetch=net, now=soon))["saved"] == 1
        assert net.asked == [OTHER]
        net.asked.clear()
        assert await run_once(conn, fetch=net, now=soon) == {
            "saved": 0,
            "failed": 0,
            "not_a_feed": 0,
        }
        assert net.asked == []
        net.asked.clear()
        await run_once(conn, fetch=net, now=NOW + REFRESH_EVERY)
        assert net.asked == [FEED]

    _run(base, work)


def test_feed_nobody_follows_is_not_fetched(base: str) -> None:
    net = Net(**{FEED: rss("один")})

    async def work(conn: asyncpg.Connection) -> None:
        await subscribe(conn, ANN, FEED, now=NOW)
        await run_once(conn, fetch=net, now=NOW)
        await podcasts.unsubscribe(conn, ANN, FEED)
        net.asked.clear()
        await run_once(conn, fetch=net, now=NOW + timedelta(days=2))
        assert net.asked == []

    _run(base, work)


def test_one_bad_feed_does_not_stop_the_pass(base: str) -> None:
    net = Net(**{FEED: FeedUnavailable(), OTHER: b"<html/>", THIRD: rss("три")})

    async def work(conn: asyncpg.Connection) -> None:
        for n, url in enumerate((FEED, OTHER, THIRD)):
            await subscribe(conn, ANN, url, now=NOW + timedelta(seconds=n))
        assert await run_once(conn, fetch=net, now=NOW + timedelta(minutes=1)) == {
            "saved": 1,
            "failed": 1,
            "not_a_feed": 1,
        }
        assert sorted(net.asked) == sorted([FEED, OTHER, THIRD])

    _run(base, work)


def test_failed_feed_waits_its_backoff(base: str) -> None:
    net = Net()

    async def work(conn: asyncpg.Connection) -> None:
        await subscribe(conn, ANN, FEED, now=NOW)
        await run_once(conn, fetch=net, now=NOW)
        net.asked.clear()
        await run_once(conn, fetch=net, now=NOW + backoff(1) - timedelta(seconds=1))
        assert net.asked == []
        await run_once(conn, fetch=net, now=NOW + backoff(1))
        assert net.asked == [FEED]

    _run(base, work)


def test_pass_is_bounded_and_goes_one_by_one(base: str) -> None:
    urls = [f"https://pod{n:02d}.example.org/rss" for n in range(PER_PASS + 5)]
    net = Net(**{u: rss("один") for u in urls})

    async def work(conn: asyncpg.Connection) -> None:
        for n, url in enumerate(urls):
            await subscribe(conn, ANN, url, now=NOW + timedelta(seconds=n))
        later = NOW + timedelta(minutes=5)
        assert (await run_once(conn, fetch=net, now=later))["saved"] == PER_PASS
        assert len(net.asked) == PER_PASS
        assert net.most_in_flight == 1
        net.asked.clear()
        assert (await run_once(conn, fetch=net, now=later, limit=3))["saved"] == 3
        assert (await run_once(conn, fetch=net, now=later))["saved"] == 2

    _run(base, work)


def test_database_error_on_one_feed_is_counted_and_the_pass_goes_on(
    base: str, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    real = podcasts.save_feed

    async def flaky(
        conn: asyncpg.Connection, feed_url: str, podcast: Any, **kw: Any
    ) -> bool:
        if feed_url == FEED:
            raise asyncpg.PostgresError(
                "https://pod.example.org/feed.xml не записалась"
            )
        return await real(conn, feed_url, podcast, **kw)

    monkeypatch.setattr(podcasts, "save_feed", flaky)
    net = Net(**{FEED: rss("один"), OTHER: rss("два")})

    async def work(conn: asyncpg.Connection) -> None:
        await subscribe(conn, ANN, FEED, now=NOW)
        await subscribe(conn, ANN, OTHER, now=NOW + timedelta(seconds=1))
        assert await run_once(conn, fetch=net, now=NOW + timedelta(minutes=1)) == {
            "saved": 1,
            "failed": 1,
            "not_a_feed": 0,
        }

    with caplog.at_level(logging.DEBUG):
        _run(base, work)
    lines = [r.getMessage() for r in caplog.records if r.name == "apertonodo"]
    assert lines == ["podcast crawl saved=1 failed=1 not_a_feed=0"]
    assert "example.org" not in caplog.text
    assert "не записалась" not in caplog.text


def test_cancel_stops_the_pass(base: str) -> None:
    entered = asyncio.Event()

    async def fetch(url: str) -> bytes:
        entered.set()
        await asyncio.sleep(30)
        return rss("один")

    async def work(conn: asyncpg.Connection) -> None:
        await subscribe(conn, ANN, FEED, now=NOW)
        task = asyncio.ensure_future(run_once(conn, fetch=fetch, now=NOW))
        await entered.wait()
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task

    _run(base, work)


# --- log and privacy ---


def test_one_line_per_pass_with_counts_only(
    base: str, caplog: pytest.LogCaptureFixture
) -> None:
    net = Net(
        **{
            FEED: rss("Тайный выпуск", title="Тайное название"),
            OTHER: ValueError("https://other.example.org/rss секрет"),
            THIRD: b"<html>third.example.org</html>",
        }
    )

    async def work(conn: asyncpg.Connection) -> None:
        for n, url in enumerate((FEED, OTHER, THIRD)):
            await subscribe(conn, ANN, url, now=NOW + timedelta(seconds=n))
        await run_once(conn, fetch=net, now=NOW + timedelta(minutes=1))

    with caplog.at_level(logging.DEBUG):
        _run(base, work)
    lines = [r.getMessage() for r in caplog.records if r.name == "apertonodo"]
    assert lines == ["podcast crawl saved=1 failed=1 not_a_feed=1"]
    text = caplog.text
    for secret in ("example.org", "Тайн", "секрет", "third"):
        assert secret not in text


def test_empty_pass_writes_nothing(base: str, caplog: pytest.LogCaptureFixture) -> None:
    async def work(conn: asyncpg.Connection) -> None:
        assert await run_once(conn, fetch=Net(), now=NOW) == {
            "saved": 0,
            "failed": 0,
            "not_a_feed": 0,
        }

    with caplog.at_level(logging.DEBUG):
        _run(base, work)
    assert [r for r in caplog.records if r.name == "apertonodo"] == []


def test_single_refresh_writes_nothing(
    base: str, caplog: pytest.LogCaptureFixture
) -> None:
    net = Net(**{FEED: ValueError("https://pod.example.org секрет")})

    async def work(conn: asyncpg.Connection) -> None:
        await subscribe(conn, ANN, FEED, now=NOW)
        await refresh_one(conn, FEED, fetch=net, now=NOW)

    with caplog.at_level(logging.DEBUG):
        _run(base, work)
    assert "example.org" not in caplog.text
    assert "секрет" not in caplog.text


def test_counts_in_the_line_are_not_mixed_up(
    base: str, caplog: pytest.LogCaptureFixture
) -> None:
    net = Net(**{FEED: rss("один"), OTHER: rss("два")})

    async def work(conn: asyncpg.Connection) -> None:
        for n, url in enumerate((FEED, OTHER, THIRD)):
            await subscribe(conn, ANN, url, now=NOW + timedelta(seconds=n))
        await run_once(conn, fetch=net, now=NOW + timedelta(minutes=1))

    with caplog.at_level(logging.DEBUG):
        _run(base, work)
    lines = [r.getMessage() for r in caplog.records if r.name == "apertonodo"]
    assert lines == ["podcast crawl saved=2 failed=1 not_a_feed=0"]


# --- default fetch ---


def _fake_fetch(
    monkeypatch: pytest.MonkeyPatch, status: int, body: bytes
) -> list[dict[str, Any]]:
    calls: list[dict[str, Any]] = []

    async def fake(url: Any, **kw: Any) -> news_fetch.NewsFetchResult:
        calls.append({"url": url, **kw})
        return news_fetch.NewsFetchResult(
            status=status, body=body, url=httpx.URL(str(url))
        )

    monkeypatch.setattr(news_fetch, "fetch", fake)
    return calls


def test_default_fetch_goes_through_the_guarded_fetcher(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls = _fake_fetch(monkeypatch, 200, b"<rss/>")
    assert asyncio.run(default_fetch(FEED)) == b"<rss/>"
    assert calls == [
        {"url": FEED, "max_bytes": MAX_FEED_BYTES, "timeout": FEED_TIMEOUT_S}
    ]


@pytest.mark.parametrize("status", [204, 206, 301, 304, 401, 404, 429, 500, 503])
def test_default_fetch_takes_only_200(
    monkeypatch: pytest.MonkeyPatch, status: int
) -> None:
    _fake_fetch(monkeypatch, status, b"<rss/>")
    with pytest.raises(FeedUnavailable) as caught:
        asyncio.run(default_fetch(FEED))
    assert "example.org" not in str(caught.value)
    assert "example.org" not in repr(caught.value)


def test_default_fetch_passes_the_refusal_on(monkeypatch: pytest.MonkeyPatch) -> None:
    async def refuse(url: Any, **kw: Any) -> Any:
        raise news_fetch.NewsFetchRefused("внутренний адрес")

    monkeypatch.setattr(news_fetch, "fetch", refuse)
    with pytest.raises(news_fetch.NewsFetchRefused):
        asyncio.run(default_fetch("http://192.168.1.1/feed"))


def test_module_does_not_open_the_network_itself() -> None:
    source = Path(podcast_crawl.__file__).read_text(encoding="utf-8")
    for word in (
        "import httpx",
        "AsyncClient",
        "print(",
        "app.main",
        "import os",
        "urlopen",
    ):
        assert word not in source, word
    assert 'getLogger("apertonodo")' in source
