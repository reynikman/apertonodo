# ruff: noqa: F811 — pytest fixtures from test_podcast_api come as parameters under the same names
"""FT-755: "Continue" — started and unfinished episodes with titles.

`GET /v1/podcasts/continue?limit=` returns `{"episodes": [...]}`: row format is identical to `/v1/podcasts/new`
(`feed_url`, `feed_title`, episode fields) plus `position_ms`, the progress mark. Most recently
updated positions come first.

Guards:
- only started (`position_ms > 0`) and unfinished (`done` is false) episodes in the list;
- episode no longer present in feed is skipped rather than failing the response;
- each user has their own data;
- `limit` behaves like `/new`: not a number — 400 `invalid_request`;
- without DB or on DB failure — 503 `library_unavailable`, without login — 401.

What the test does not prove: shelf in mobile app (separate client card).
"""

from __future__ import annotations

from collections.abc import Callable

import pytest
from fastapi.testclient import TestClient
from test_podcast_api import (  # noqa: F401 — pytest fixtures are imported by name
    FEED,
    OTHER,
    PROGRESS,
    SUBSCRIBE,
    UNSUBSCRIBE,
    Directory,
    _app,
    _save,
    as_bob,
    base,
    client,
    directory,
    item,
    kicks,
    reports_as_on_the_server,
)

CONTINUE = "/v1/podcasts/continue"


def _progress(client: TestClient, *items: dict) -> None:
    r = client.post(PROGRESS, json={"items": list(items)})
    assert r.status_code == 200


def _rows(client: TestClient, **params: str) -> list[tuple[str, str, int]]:
    r = client.get(CONTINUE, params=params)
    assert r.status_code == 200, r.text
    return [(e["feed_url"], e["guid"], e["position_ms"]) for e in r.json()["episodes"]]


def test_started_episode_comes_with_titles_and_place(
    client: TestClient, base: str
) -> None:
    client.post(SUBSCRIBE, json={"feed_url": FEED})
    _save(base, FEED, "Secret Show", 3)
    _progress(client, item("guid-2", position_ms=125_000))
    r = client.get(CONTINUE)
    assert r.status_code == 200
    assert r.json() == {
        "episodes": [
            {
                "feed_url": FEED,
                "feed_title": "Secret Show",
                "position_ms": 125_000,
                "guid": "guid-2",
                "title": "Secret Episode 2",
                "description": "",
                "audio_url": "https://cdn.example.org/2.mp3",
                "audio_type": "audio/mpeg",
                "audio_bytes": 1000,
                "duration_ms": 600_000,
                "published": "2026-09-02T10:00:00.000Z",
                "image": None,
                "season": None,
                "number": None,
                "explicit": False,
            }
        ]
    }


def test_freshest_place_first_across_feeds(client: TestClient, base: str) -> None:
    client.post(SUBSCRIBE, json={"feed_url": FEED})
    client.post(SUBSCRIBE, json={"feed_url": OTHER})
    _save(base, FEED, "Secret Show", 3)
    _save(base, OTHER, "Other Show", 2)
    _progress(
        client,
        item("guid-1", updated_at="2026-10-01T09:00:00.000Z", position_ms=1_000),
        item(
            "guid-2",
            feed=OTHER,
            updated_at="2026-10-01T11:00:00.000Z",
            position_ms=2_000,
        ),
        item("guid-3", updated_at="2026-10-01T10:00:00.000Z", position_ms=3_000),
    )
    assert _rows(client) == [
        (OTHER, "guid-2", 2_000),
        (FEED, "guid-3", 3_000),
        (FEED, "guid-1", 1_000),
    ]
    assert _rows(client, limit="2") == [
        (OTHER, "guid-2", 2_000),
        (FEED, "guid-3", 3_000),
    ]


def test_finished_and_not_started_are_not_continued(
    client: TestClient, base: str
) -> None:
    client.post(SUBSCRIBE, json={"feed_url": FEED})
    _save(base, FEED, "Secret Show", 3)
    _progress(
        client,
        item("guid-1", position_ms=600_000, done=True),
        item("guid-2", position_ms=0),
        item("guid-3", position_ms=5_000),
    )
    assert _rows(client) == [(FEED, "guid-3", 5_000)]


def test_episode_gone_from_the_feed_is_skipped(client: TestClient, base: str) -> None:
    client.post(SUBSCRIBE, json={"feed_url": FEED})
    _save(base, FEED, "Secret Show", 2)
    _progress(
        client,
        item("guid-1", position_ms=7_000),
        item("guid-gone", position_ms=9_000),
        item(
            "guid-x",
            feed="https://feeds.example.org/never-saved.xml",
            position_ms=4_000,
        ),
    )
    assert _rows(client) == [(FEED, "guid-1", 7_000)]


def test_continue_is_personal(
    client: TestClient, base: str, as_bob: Callable[[], None]
) -> None:
    client.post(SUBSCRIBE, json={"feed_url": FEED})
    _save(base, FEED, "Secret Show", 2)
    _progress(client, item("guid-1", position_ms=7_000))
    as_bob()
    r = client.get(CONTINUE)
    assert (r.status_code, r.json()) == (200, {"episodes": []})


def test_place_survives_unsubscribe(client: TestClient, base: str) -> None:
    """Progress mark survives unsubscribe (054): started episodes remain while episode exists in DB."""
    client.post(SUBSCRIBE, json={"feed_url": FEED})
    _save(base, FEED, "Secret Show", 2)
    _progress(client, item("guid-1", position_ms=7_000))
    client.post(UNSUBSCRIBE, json={"feed_url": FEED})
    assert _rows(client) == [(FEED, "guid-1", 7_000)]


@pytest.mark.parametrize("limit", ["x", "-1", "1.5", ""])
def test_continue_refuses_a_broken_limit(client: TestClient, limit: str) -> None:
    r = client.get(CONTINUE, params={"limit": limit})
    assert (r.status_code, r.json()) == (400, {"status": "invalid_request"})


def test_continue_without_a_base_is_unavailable(directory: Directory) -> None:
    r = TestClient(_app(None, directory)).get(CONTINUE)
    assert (r.status_code, r.json()) == (503, {"status": "library_unavailable"})


def test_continue_with_a_dead_base_is_unavailable(directory: Directory) -> None:
    dead = "postgresql://music@127.0.0.1:1/nothing"
    r = TestClient(_app(dead, directory)).get(CONTINUE)
    assert (r.status_code, r.json()) == (503, {"status": "library_unavailable"})


@pytest.mark.real_auth
def test_continue_without_login_is_closed(base: str, directory: Directory) -> None:
    r = TestClient(_app(base, directory)).get(CONTINUE)
    assert r.status_code == 401
