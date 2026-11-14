"""Podcast episodes before subscribing (FT-723): `GET /v1/podcasts/preview`."""

from __future__ import annotations

import logging

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app import podcast_preview
from app.podcast_preview import FRESH_S, MAX_EPISODES, install_podcast_preview
from tests.test_podcast_feed import feed, item

FEED = "https://pod.example.org/feed.xml"


class Clock:
    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now


def _client(fetch, *, live: bool = True, clock: Clock | None = None) -> TestClient:
    app = FastAPI()
    install_podcast_preview(app, live=live, fetch=fetch, clock=clock or Clock())
    return TestClient(app)


def _fetcher(body: bytes, calls: list[str]):
    async def fetch(url: str) -> bytes:
        calls.append(url)
        return body

    return fetch


def test_episodes_without_subscription() -> None:
    calls: list[str] = []
    raw = feed(
        item("Первый", guid="a"),
        item("Второй", guid="b", url="https://cdn.example.org/b.mp3"),
    )
    answer = _client(_fetcher(raw, calls)).get(
        "/v1/podcasts/preview", params={"feed_url": FEED}
    )
    assert answer.status_code == 200, answer.text
    eps = answer.json()["episodes"]
    assert [e["guid"] for e in eps] == ["a", "b"]
    assert eps[0]["audio_url"] == "https://cdn.example.org/a/ep1.mp3"
    assert set(eps[0]) == {
        "guid",
        "title",
        "description",
        "audio_url",
        "audio_type",
        "audio_bytes",
        "duration_ms",
        "published",
        "image",
        "season",
        "number",
        "explicit",
    }
    assert calls == [FEED]


def test_second_open_is_cached_until_fresh_runs_out() -> None:
    calls: list[str] = []
    clock = Clock()
    client = _client(_fetcher(feed(item()), calls), clock=clock)
    client.get("/v1/podcasts/preview", params={"feed_url": FEED})
    client.get("/v1/podcasts/preview", params={"feed_url": FEED})
    assert len(calls) == 1
    clock.now += FRESH_S
    client.get("/v1/podcasts/preview", params={"feed_url": FEED})
    assert len(calls) == 2


@pytest.mark.parametrize("url", ["", "ftp://pod.example.org/f", "not a url"])
def test_bad_url_is_400_and_no_fetch(url: str) -> None:
    calls: list[str] = []
    answer = _client(_fetcher(feed(item()), calls)).get(
        "/v1/podcasts/preview", params={"feed_url": url}
    )
    assert answer.status_code == 400
    assert calls == []


def test_not_live_is_503_and_no_fetch() -> None:
    calls: list[str] = []
    answer = _client(_fetcher(feed(item()), calls), live=False).get(
        "/v1/podcasts/preview", params={"feed_url": FEED}
    )
    assert answer.status_code == 503
    assert calls == []


def test_fetch_failure_is_503_and_not_cached() -> None:
    calls: list[str] = []

    async def broken(url: str) -> bytes:
        calls.append(url)
        raise OSError("down")

    client = _client(broken)
    assert (
        client.get("/v1/podcasts/preview", params={"feed_url": FEED}).status_code == 503
    )
    assert (
        client.get("/v1/podcasts/preview", params={"feed_url": FEED}).status_code == 503
    )
    assert len(calls) == 2


def test_not_a_feed_is_404() -> None:
    answer = _client(_fetcher(b"<html>nope</html>", [])).get(
        "/v1/podcasts/preview", params={"feed_url": FEED}
    )
    assert answer.status_code == 404
    assert answer.json() == {"status": "not_a_feed"}


def test_too_big_is_503(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(podcast_preview, "MAX_FEED_BYTES", 10)
    answer = _client(_fetcher(feed(item()), [])).get(
        "/v1/podcasts/preview", params={"feed_url": FEED}
    )
    assert answer.status_code == 503


def test_at_most_max_episodes(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(podcast_preview, "MAX_EPISODES", 2)
    raw = feed(
        *[
            item(f"E{i}", guid=f"g{i}", url=f"https://cdn.example.org/{i}.mp3")
            for i in range(5)
        ]
    )
    eps = (
        _client(_fetcher(raw, []))
        .get("/v1/podcasts/preview", params={"feed_url": FEED})
        .json()["episodes"]
    )
    assert len(eps) == 2
    assert MAX_EPISODES == 200


def test_cache_has_a_ceiling(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(podcast_preview, "MAX_KEYS", 2)
    calls: list[str] = []
    client = _client(_fetcher(feed(item()), calls))
    for n in (1, 2, 3, 1):
        client.get(
            "/v1/podcasts/preview",
            params={"feed_url": f"https://pod.example.org/{n}.xml"},
        )
    assert len(calls) == 4  # the first is evicted by the third


def test_log_has_no_feed_address(caplog: pytest.LogCaptureFixture) -> None:
    caplog.set_level(logging.DEBUG)

    async def broken(url: str) -> bytes:
        raise OSError(url)

    _client(broken).get("/v1/podcasts/preview", params={"feed_url": FEED})
    assert "pod.example.org" not in caplog.text
