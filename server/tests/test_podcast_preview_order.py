"""Episode order for podcast preview without subscription (FT-736).

Lead check, executor does not modify it. `GET /v1/podcasts/preview` accepts
`order=newest|oldest` — like `/v1/podcasts/episodes` (FT-729): `newest` — by release date
from newest (`published DESC NULLS LAST`, ties broken by feed order),
`oldest` — from earliest (`published ASC NULLS LAST`, ties broken by reverse feed order).
An unrecognized value acts as `newest`. Without `order` response is unchanged: feed parsing
(`parse_podcast`) already puts episodes newest first, which is `newest`.
At most `MAX_EPISODES` are returned from the requested end: for longer feeds — the real
first episodes, not fresh ones reversed. The feed is downloaded once per `FRESH_S`
for any order.
"""

from __future__ import annotations

from email.utils import format_datetime
from datetime import UTC, datetime, timedelta

from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.podcast_preview import FRESH_S, MAX_EPISODES, install_podcast_preview
from tests.test_podcast_feed import feed, item

FEED = "https://pod.example.org/feed.xml"
DAY0 = datetime(2020, 1, 1, 12, tzinfo=UTC)


class Clock:
    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now


def _client(body: bytes, calls: list[str], clock: Clock | None = None) -> TestClient:
    async def fetch(url: str) -> bytes:
        calls.append(url)
        return body

    app = FastAPI()
    install_podcast_preview(app, live=True, fetch=fetch, clock=clock or Clock())
    return TestClient(app)


def dated(guid: str, day: int | None) -> str:
    extra = (
        ""
        if day is None
        else f"<pubDate>{format_datetime(DAY0 + timedelta(days=day))}</pubDate>"
    )
    return item(f"Выпуск {guid}", guid=guid, extra=extra)


def guids(client: TestClient, order: str | None) -> list[str]:
    params = {"feed_url": FEED}
    if order is not None:
        params["order"] = order
    answer = client.get("/v1/podcasts/preview", params=params)
    assert answer.status_code == 200, answer.text
    return [e["guid"] for e in answer.json()["episodes"]]


def long_feed(n: int) -> bytes:
    # Feed, as usual, is newest first: the first item is the most recent episode.
    return feed(*(dated(f"e{i}", i) for i in reversed(range(n))))


def test_oldest_of_a_long_feed_are_the_real_first_episodes() -> None:
    n = MAX_EPISODES + 50
    got = guids(_client(long_feed(n), []), "oldest")
    assert len(got) == MAX_EPISODES
    assert got[:3] == ["e0", "e1", "e2"]
    assert got[-1] == f"e{MAX_EPISODES - 1}"


def test_newest_of_a_long_feed() -> None:
    n = MAX_EPISODES + 50
    got = guids(_client(long_feed(n), []), "newest")
    assert len(got) == MAX_EPISODES
    assert got[0] == f"e{n - 1}"
    assert got[-1] == f"e{n - MAX_EPISODES}"


def test_newest_sorts_by_date_not_by_feed_position() -> None:
    raw = feed(dated("mid", 5), dated("new", 9), dated("old", 1))
    client = _client(raw, [])
    assert guids(client, "newest") == ["new", "mid", "old"]
    assert guids(client, "oldest") == ["old", "mid", "new"]


def test_without_date_last_in_both_orders() -> None:
    raw = feed(dated("nodate", None), dated("a", 1), dated("b", 2))
    client = _client(raw, [])
    assert guids(client, "newest") == ["b", "a", "nodate"]
    assert guids(client, "oldest") == ["a", "b", "nodate"]


def test_same_date_keeps_feed_order_for_newest_and_reverses_for_oldest() -> None:
    raw = feed(dated("x", 3), dated("y", 3), dated("z", 3))
    client = _client(raw, [])
    assert guids(client, "newest") == ["x", "y", "z"]
    assert guids(client, "oldest") == ["z", "y", "x"]


def test_without_order_answer_is_as_before() -> None:
    raw = feed(dated("mid", 5), dated("new", 9), dated("old", 1))
    assert guids(_client(raw, []), None) == ["new", "mid", "old"]


def test_unknown_order_is_newest() -> None:
    raw = feed(dated("mid", 5), dated("new", 9), dated("old", 1))
    assert guids(_client(raw, []), "sideways") == ["new", "mid", "old"]


def test_one_fetch_for_every_order_until_fresh_runs_out() -> None:
    calls: list[str] = []
    clock = Clock()
    client = _client(long_feed(10), calls, clock)
    for order in (None, "newest", "oldest", "newest"):
        guids(client, order)
    assert calls == [FEED]
    clock.now += FRESH_S
    guids(client, "oldest")
    assert len(calls) == 2


def test_bad_url_still_400_with_order() -> None:
    answer = _client(long_feed(1), []).get(
        "/v1/podcasts/preview", params={"feed_url": "ftp://x", "order": "oldest"}
    )
    assert answer.status_code == 400
