"""FT-661 (Р-A93, block B-5): podcast endpoints — search, subscriptions, episodes, progress mark.

The `app/podcast_api.py` module only connects existing components (FT-655 search, FT-657 storage, FT-658 progress) to
HTTP. It has no podcast logic of its own, and the test specifically guards the interface:

- `GET  /v1/podcasts/search?q=&limit=` — directory; without a client or on client failure — 503
  `podcast_search_unavailable`, not an empty list ("nothing found" and "did not ask" are different);
- `GET  /v1/podcasts` — user's subscriptions;
- `POST /v1/podcasts/subscribe` `{feed_url}` — `new` / `exists`, 422 `bad_url`, 409 `limit`;
- `POST /v1/podcasts/unsubscribe` `{feed_url}` — `{removed}`;
- `GET  /v1/podcasts/episodes?feed_url=&limit=&offset=` — only for user's own subscription, otherwise 404;
- `POST /v1/podcasts/progress` `{items}` and `GET /v1/podcasts/progress?after=&limit=` — FT-659 sync.

Guards:
- each user has their own data; someone else's feed cannot be read without a subscription;
- request body is not read into memory past the limit (FT-646 lesson);
- database failure — 503 `library_unavailable`, not 500 (FT-645 lesson);
- no search text, feed URL, or titles in the log;
- after a new subscription, `kick` is called (lead will connect FT-660 crawler to it); its failure does not
  cancel the subscription.

What the test does not prove: real directory is not called; `install_podcasts` in `main.py`, client,
proxy, and crawler are connected by the lead; mobile plays audio directly from episode URL — server does not
serve it.
"""

from __future__ import annotations

import asyncio
import json
import logging
import uuid
from collections.abc import Awaitable, Callable, Iterator
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import asyncpg
import httpx
import pytest
from fastapi.testclient import TestClient

from app import podcast_api, podcast_new, podcast_progress, podcasts
from app.main import create_app
from app.migrate import apply
from app.podcast_api import install_podcasts
from app.podcast_feed import parse_podcast
from app.podcast_search import SEARCH_URL

ROOT = Path(__file__).resolve().parents[2]
CATALOG = json.loads((ROOT / "contracts" / "fixtures" / "catalog.json").read_text())[
    "tracks"
]

SEARCH = "/v1/podcasts/search"
LIST = "/v1/podcasts"
SUBSCRIBE = "/v1/podcasts/subscribe"
UNSUBSCRIBE = "/v1/podcasts/unsubscribe"
EPISODES = "/v1/podcasts/episodes"
PROGRESS = "/v1/podcasts/progress"
NEW = "/v1/podcasts/new"

FEED = "https://feeds.example.org/secret-show.xml"
OTHER = "https://feeds.example.org/other-show.xml"
NOW = datetime(2026, 10, 7, 12, 0, tzinfo=UTC)
STAMP = "2026-10-01T11:00:00.000Z"


def rss(title: str, count: int) -> bytes:
    items = "".join(
        f"<item><title>Secret Episode {n}</title><guid>guid-{n}</guid>"
        f"<pubDate>{n:02d} Sep 2026 10:00:00 GMT</pubDate>"
        f'<enclosure url="https://cdn.example.org/{n}.mp3" type="audio/mpeg" length="1000"/>'
        f"<itunes:duration>00:10:00</itunes:duration></item>"
        for n in range(1, count + 1)
    )
    return (
        '<?xml version="1.0"?><rss version="2.0" '
        'xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>'
        f"<title>{title}</title><itunes:author>Secret Author</itunes:author>{items}"
        "</channel></rss>"
    ).encode()


class Directory:
    """Test directory: remembers requests and responds with whatever is configured."""

    def __init__(self) -> None:
        self.calls: list[dict[str, str]] = []
        self.status = 200
        self.rows: list[dict[str, Any]] = [
            {
                "collectionName": "Secret Show",
                "artistName": "Secret Author",
                "feedUrl": FEED,
                "artworkUrl600": "https://img.example.org/600.jpg",
                "trackCount": 42,
            }
        ]

    def answer(self, request: httpx.Request) -> httpx.Response:
        assert str(request.url).startswith(SEARCH_URL)
        self.calls.append(dict(request.url.params))
        return httpx.Response(
            self.status, json={"resultCount": len(self.rows), "results": self.rows}
        )


def _db(url: str, work: Callable[[asyncpg.Connection], Awaitable[Any]]) -> Any:
    async def run() -> Any:
        conn = await asyncpg.connect(url)
        try:
            return await work(conn)
        finally:
            await conn.close()

    return asyncio.run(run())


def _save(url: str, feed_url: str, title: str, count: int) -> None:
    podcast = parse_podcast(rss(title, count))
    assert podcast is not None
    _db(url, lambda conn: podcasts.save_feed(conn, feed_url, podcast, now=NOW))


def _app(
    url: str | None,
    directory: Directory | None,
    kick: Callable[[], None] | None = None,
) -> Any:
    app = create_app(
        database_url=url,
        catalog=CATALOG,
    )
    client = (
        httpx.AsyncClient(transport=httpx.MockTransport(directory.answer))
        if directory is not None
        else None
    )
    install_podcasts(app, database_url=url, client=client, kick=kick)
    return app


@pytest.fixture(autouse=True)
def reports_as_on_the_server() -> Iterator[None]:
    """Error reporter — as in production: does not read the request body (FT-646 lesson).

    Sibling report tests leave it enabled with default settings, which reads the entire
    body before the handler — and the read byte count would measure it instead of the endpoint.
    Production setting — `max_request_body_size="never"` in `app/error_reports.py`.
    """
    import sentry_sdk

    sentry_sdk.init(max_request_body_size="never")
    try:
        yield
    finally:
        sentry_sdk.get_client().close()
        sentry_sdk.init()


@pytest.fixture
def directory() -> Directory:
    return Directory()


@pytest.fixture
def base(postgres_url: str, test_principal: dict[str, Any]) -> str:
    asyncio.run(apply(postgres_url))

    async def prepare(conn: asyncpg.Connection) -> None:
        await conn.execute(
            "TRUNCATE podcast_progress, podcast_subscriptions, podcast_episodes, podcast_feeds"
        )
        await conn.execute(
            "INSERT INTO users (id, username) VALUES ($1, $2) ON CONFLICT (id) DO NOTHING",
            uuid.UUID(str(test_principal["id"])),
            f"me-{str(test_principal['id'])[:8]}",
        )

    _db(postgres_url, prepare)
    return postgres_url


@pytest.fixture
def kicks() -> list[int]:
    return []


@pytest.fixture
def client(base: str, directory: Directory, kicks: list[int]) -> TestClient:
    return TestClient(_app(base, directory, lambda: kicks.append(1)))


@pytest.fixture
def as_bob(
    base: str, test_principal: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> Callable[[], None]:
    """Subsequent requests come from the second user."""
    bob = uuid.uuid4()

    def switch() -> None:
        async def add(conn: asyncpg.Connection) -> None:
            await conn.execute(
                "INSERT INTO users (id, username) VALUES ($1, $2)",
                bob,
                f"bob-{bob.hex[:8]}",
            )

        _db(base, add)
        monkeypatch.setitem(test_principal, "id", str(bob))

    return switch


def item(guid: str = "guid-1", feed: str = FEED, **over: Any) -> dict[str, Any]:
    return {
        "feed_url": feed,
        "guid": guid,
        "position_ms": 60_000,
        "done": False,
        "updated_at": STAMP,
        **over,
    }


# --- search ------------------------------------------------------------------


def test_search_gives_what_the_directory_found(
    client: TestClient, directory: Directory
) -> None:
    r = client.get(SEARCH, params={"q": "secret show"})
    assert r.status_code == 200
    assert r.json() == {
        "podcasts": [
            {
                "feed_url": FEED,
                "title": "Secret Show",
                "author": "Secret Author",
                "image": "https://img.example.org/600.jpg",
                "episodes": 42,
            }
        ]
    }
    assert directory.calls[0]["term"] == "secret show"
    assert directory.calls[0]["limit"] == "20"


def test_search_passes_the_limit_on(client: TestClient, directory: Directory) -> None:
    assert client.get(SEARCH, params={"q": "secret", "limit": "7"}).status_code == 200
    assert directory.calls[0]["limit"] == "7"


@pytest.mark.parametrize("limit", ["x", "-1", "1.5", "", "٣", "9" * 30])
def test_search_refuses_a_limit_that_is_not_a_number(
    client: TestClient, directory: Directory, limit: str
) -> None:
    r = client.get(SEARCH, params={"q": "secret", "limit": limit})
    assert (r.status_code, r.json()) == (400, {"status": "invalid_request"})
    assert directory.calls == []


@pytest.mark.parametrize("params", [{}, {"q": ""}, {"q": "a"}])
def test_search_without_words_is_empty_and_asks_nobody(
    client: TestClient, directory: Directory, params: dict[str, str]
) -> None:
    r = client.get(SEARCH, params=params)
    assert (r.status_code, r.json()) == (200, {"podcasts": []})
    assert directory.calls == []


def test_directory_trouble_is_not_an_empty_answer(
    client: TestClient, directory: Directory
) -> None:
    directory.status = 503
    r = client.get(SEARCH, params={"q": "secret"})
    assert (r.status_code, r.json()) == (
        503,
        {"status": "podcast_search_unavailable"},
    )


def test_search_without_a_client_is_unavailable(base: str) -> None:
    r = TestClient(_app(base, None)).get(SEARCH, params={"q": "secret"})
    assert (r.status_code, r.json()) == (
        503,
        {"status": "podcast_search_unavailable"},
    )


def test_search_needs_no_database(directory: Directory) -> None:
    r = TestClient(_app(None, directory)).get(SEARCH, params={"q": "secret"})
    assert r.status_code == 200
    assert len(r.json()["podcasts"]) == 1


# --- subscriptions -----------------------------------------------------------


def test_subscription_carries_the_feed_language(client: TestClient, base: str) -> None:
    """FT-737: feed language — in subscriptions list."""
    client.post(SUBSCRIBE, json={"feed_url": FEED})
    raw = rss("Secret Show", 2).replace(
        b"<channel>", b"<channel><language>en-us</language>"
    )
    podcast = parse_podcast(raw)
    assert podcast is not None
    _db(base, lambda conn: podcasts.save_feed(conn, FEED, podcast, now=NOW))
    (row,) = client.get(LIST).json()["podcasts"]
    assert row["language"] == "en"


def test_nothing_subscribed_is_an_empty_list(client: TestClient) -> None:
    r = client.get(LIST)
    assert (r.status_code, r.json()) == (200, {"podcasts": []})


def test_subscribe_then_list(client: TestClient, base: str, kicks: list[int]) -> None:
    r = client.post(SUBSCRIBE, json={"feed_url": FEED})
    assert (r.status_code, r.json()) == (200, {"result": "new", "feed_url": FEED})
    assert kicks == [1], "new subscription wakes up crawler"

    (row,) = client.get(LIST).json()["podcasts"]
    assert row["feed_url"] == FEED
    assert row["title"] is None, "feed not fetched yet"
    assert row["episodes"] == 0
    assert row["newest_at"] is None
    assert row["added_at"].endswith("Z") and len(row["added_at"]) == 24

    _save(base, FEED, "Secret Show", 3)
    (row,) = client.get(LIST).json()["podcasts"]
    assert set(row) == {
        "feed_url",
        "title",
        "author",
        "image",
        "episodes",
        "newest_at",
        "added_at",
        "language",
    }
    assert row["language"] is None, "feed has no <language>"
    assert (row["title"], row["author"], row["episodes"]) == (
        "Secret Show",
        "Secret Author",
        3,
    )
    assert row["newest_at"] == "2026-09-03T10:00:00.000Z"


def test_times_are_utc_with_milliseconds(client: TestClient, base: str) -> None:
    client.post(SUBSCRIBE, json={"feed_url": FEED})

    async def shift(conn: asyncpg.Connection) -> None:
        await conn.execute(
            "UPDATE podcast_subscriptions SET added_at = '2026-10-01 09:00:00.123456+03'"
        )

    _db(base, shift)
    (row,) = client.get(LIST).json()["podcasts"]
    assert row["added_at"] == "2026-10-01T06:00:00.123Z"


def test_subscribing_twice_is_exists_and_does_not_kick(
    client: TestClient, kicks: list[int]
) -> None:
    client.post(SUBSCRIBE, json={"feed_url": FEED})
    r = client.post(SUBSCRIBE, json={"feed_url": FEED})
    assert (r.status_code, r.json()) == (200, {"result": "exists", "feed_url": FEED})
    assert kicks == [1]
    assert len(client.get(LIST).json()["podcasts"]) == 1


def test_the_address_comes_back_normalised(client: TestClient) -> None:
    r = client.post(
        SUBSCRIBE, json={"feed_url": "  HTTPS://Feeds.Example.org:443/a.xml#top "}
    )
    clean = podcasts.normalize_feed_url("  HTTPS://Feeds.Example.org:443/a.xml#top ")
    assert clean is not None
    assert (r.status_code, r.json()) == (200, {"result": "new", "feed_url": clean})
    assert client.get(LIST).json()["podcasts"][0]["feed_url"] == clean


@pytest.mark.parametrize(
    "bad", ["", "ftp://x.example.org/f", "not a url", "http://u:p@x.example.org/f"]
)
def test_a_bad_address_is_refused(
    client: TestClient, kicks: list[int], bad: str
) -> None:
    r = client.post(SUBSCRIBE, json={"feed_url": bad})
    assert (r.status_code, r.json()) == (422, {"status": "bad_url"})
    assert kicks == []
    assert client.get(LIST).json() == {"podcasts": []}


@pytest.mark.parametrize(
    "body",
    [
        b"",
        b"{",
        b"[]",
        b'"x"',
        b"{}",
        b'{"feed_url": 5}',
        b'{"feed_url": null}',
        b"\xff",
    ],
)
@pytest.mark.parametrize("path", [SUBSCRIBE, UNSUBSCRIBE])
def test_a_broken_body_is_refused(client: TestClient, path: str, body: bytes) -> None:
    r = client.post(path, content=body, headers={"content-type": "application/json"})
    assert (r.status_code, r.json()) == (400, {"status": "invalid_request"})


def test_the_limit_of_subscriptions_is_a_conflict(
    client: TestClient, kicks: list[int], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(podcasts, "MAX_SUBSCRIPTIONS", 2)
    for n in range(2):
        assert (
            client.post(
                SUBSCRIBE, json={"feed_url": f"https://x.example.org/{n}"}
            ).status_code
            == 200
        )
    r = client.post(SUBSCRIBE, json={"feed_url": FEED})
    assert (r.status_code, r.json()) == (409, {"status": "limit"})
    assert kicks == [1, 1]


def test_a_failing_kick_does_not_undo_the_subscription(
    base: str, directory: Directory
) -> None:
    def boom() -> None:
        raise RuntimeError("crawler is gone")

    client = TestClient(_app(base, directory, boom))
    r = client.post(SUBSCRIBE, json={"feed_url": FEED})
    assert (r.status_code, r.json()) == (200, {"result": "new", "feed_url": FEED})
    assert len(client.get(LIST).json()["podcasts"]) == 1


def test_no_kick_installed_is_fine(base: str, directory: Directory) -> None:
    r = TestClient(_app(base, directory)).post(SUBSCRIBE, json={"feed_url": FEED})
    assert r.status_code == 200


def test_unsubscribe(client: TestClient) -> None:
    client.post(SUBSCRIBE, json={"feed_url": FEED})
    client.post(SUBSCRIBE, json={"feed_url": OTHER})
    r = client.post(UNSUBSCRIBE, json={"feed_url": FEED})
    assert (r.status_code, r.json()) == (200, {"removed": True})
    assert [p["feed_url"] for p in client.get(LIST).json()["podcasts"]] == [OTHER]
    r = client.post(UNSUBSCRIBE, json={"feed_url": FEED})
    assert (r.status_code, r.json()) == (200, {"removed": False})
    r = client.post(UNSUBSCRIBE, json={"feed_url": "not a url"})
    assert (r.status_code, r.json()) == (200, {"removed": False})


# --- episodes ----------------------------------------------------------------


def test_episodes_of_a_subscription(client: TestClient, base: str) -> None:
    client.post(SUBSCRIBE, json={"feed_url": FEED})
    _save(base, FEED, "Secret Show", 3)
    r = client.get(EPISODES, params={"feed_url": FEED})
    assert r.status_code == 200
    rows = r.json()["episodes"]
    assert [e["guid"] for e in rows] == ["guid-3", "guid-2", "guid-1"]
    assert rows[0] == {
        "guid": "guid-3",
        "title": "Secret Episode 3",
        "description": "",
        "audio_url": "https://cdn.example.org/3.mp3",
        "audio_type": "audio/mpeg",
        "audio_bytes": 1000,
        "duration_ms": 600_000,
        "published": "2026-09-03T10:00:00.000Z",
        "image": None,
        "season": None,
        "number": None,
        "explicit": False,
    }


def test_episodes_by_pages(client: TestClient, base: str) -> None:
    client.post(SUBSCRIBE, json={"feed_url": FEED})
    _save(base, FEED, "Secret Show", 5)

    def page(**params: str) -> list[str]:
        r = client.get(EPISODES, params={"feed_url": FEED, **params})
        assert r.status_code == 200
        return [e["guid"] for e in r.json()["episodes"]]

    assert page(limit="2") == ["guid-5", "guid-4"]
    assert page(limit="2", offset="2") == ["guid-3", "guid-2"]
    assert page(limit="2", offset="4") == ["guid-1"]
    assert page(offset="99") == []
    assert page(offset=str(1 << 62)) == [], "huge offset is not a database failure"
    assert page(offset="9" * 19) == [], "offset larger than DB capacity is not a failure either"
    assert page(limit="9" * 19) != [], "and limit as well"


@pytest.mark.parametrize(
    "params",
    [
        {},
        {"feed_url": FEED, "limit": "x"},
        {"feed_url": FEED, "offset": "-1"},
        {"feed_url": FEED, "offset": "1e3"},
    ],
)
def test_episodes_refuse_broken_parameters(
    client: TestClient, params: dict[str, str]
) -> None:
    client.post(SUBSCRIBE, json={"feed_url": FEED})
    r = client.get(EPISODES, params=params)
    assert (r.status_code, r.json()) == (400, {"status": "invalid_request"})


@pytest.mark.parametrize("feed", [OTHER, "not a url"])
def test_episodes_without_a_subscription_are_not_found(
    client: TestClient, base: str, feed: str
) -> None:
    _save(base, OTHER, "Other Show", 2)
    r = client.get(EPISODES, params={"feed_url": feed})
    assert (r.status_code, r.json()) == (404, {"status": "not_subscribed"})


# --- order and new episodes (FT-732) -----------------------------------------


def test_episodes_from_the_first(client: TestClient, base: str) -> None:
    client.post(SUBSCRIBE, json={"feed_url": FEED})
    _save(base, FEED, "Secret Show", 5)

    def page(**params: str) -> list[str]:
        r = client.get(EPISODES, params={"feed_url": FEED, **params})
        assert r.status_code == 200
        return [e["guid"] for e in r.json()["episodes"]]

    assert page(order="oldest", limit="2") == ["guid-1", "guid-2"]
    assert page(order="oldest", limit="2", offset="2") == ["guid-3", "guid-4"]
    assert page(order="newest", limit="2") == ["guid-5", "guid-4"]
    assert page(order="oldest", offset=str(1 << 62)) == []


@pytest.mark.parametrize("order", ["", "asc", "OLDEST", "random"])
def test_unknown_order_is_newest(client: TestClient, base: str, order: str) -> None:
    client.post(SUBSCRIBE, json={"feed_url": FEED})
    _save(base, FEED, "Secret Show", 3)
    r = client.get(EPISODES, params={"feed_url": FEED, "order": order})
    assert r.status_code == 200
    assert [e["guid"] for e in r.json()["episodes"]] == ["guid-3", "guid-2", "guid-1"]


def test_oldest_without_a_subscription_is_not_found(
    client: TestClient, base: str
) -> None:
    _save(base, OTHER, "Other Show", 2)
    r = client.get(EPISODES, params={"feed_url": OTHER, "order": "oldest"})
    assert (r.status_code, r.json()) == (404, {"status": "not_subscribed"})


def test_new_episodes_of_subscriptions(client: TestClient, base: str) -> None:
    client.post(SUBSCRIBE, json={"feed_url": FEED})
    client.post(SUBSCRIBE, json={"feed_url": OTHER})
    _save(base, FEED, "Secret Show", 5)
    _save(base, OTHER, "Other Show", 1)
    r = client.get(NEW)
    assert r.status_code == 200
    rows = r.json()["episodes"]
    assert [(e["feed_url"], e["guid"]) for e in rows] == [
        (FEED, "guid-5"),
        (FEED, "guid-4"),
        (FEED, "guid-3"),
        (OTHER, "guid-1"),
    ]
    assert rows[0] == {
        "feed_url": FEED,
        "feed_title": "Secret Show",
        "guid": "guid-5",
        "title": "Secret Episode 5",
        "description": "",
        "audio_url": "https://cdn.example.org/5.mp3",
        "audio_type": "audio/mpeg",
        "audio_bytes": 1000,
        "duration_ms": 600_000,
        "published": "2026-09-05T10:00:00.000Z",
        "image": None,
        "season": None,
        "number": None,
        "explicit": False,
    }


def test_new_episodes_since_and_limit(client: TestClient, base: str) -> None:
    client.post(SUBSCRIBE, json={"feed_url": FEED})
    _save(base, FEED, "Secret Show", 5)

    def guids(**params: str) -> list[str]:
        r = client.get(NEW, params=params)
        assert r.status_code == 200
        return [e["guid"] for e in r.json()["episodes"]]

    assert guids(since="2026-09-03T10:00:00.000Z") == ["guid-5", "guid-4"]
    assert guids(since="2026-09-03T10:00:00Z") == ["guid-5", "guid-4"]
    assert guids(since="2027-01-01T00:00:00.000Z") == []
    assert guids(limit="1") == ["guid-5"]


@pytest.mark.parametrize(
    "params",
    [
        {"since": "yesterday"},
        {"since": "2026-09-03"},
        {"since": "2026-09-03T10:00:00"},
        {"limit": "x"},
        {"limit": "-1"},
    ],
)
def test_new_episodes_refuse_broken_parameters(
    client: TestClient, params: dict[str, str]
) -> None:
    r = client.get(NEW, params=params)
    assert (r.status_code, r.json()) == (400, {"status": "invalid_request"})


def test_new_episodes_are_personal(
    client: TestClient, base: str, as_bob: Callable[[], None]
) -> None:
    client.post(SUBSCRIBE, json={"feed_url": FEED})
    _save(base, FEED, "Secret Show", 2)
    as_bob()
    r = client.get(NEW)
    assert (r.status_code, r.json()) == (200, {"episodes": []})


def test_new_episodes_without_a_base_are_unavailable(directory: Directory) -> None:
    r = TestClient(_app(None, directory)).get(NEW)
    assert r.status_code == 503


# --- progress mark -----------------------------------------------------------


def test_progress_goes_in_and_comes_back(client: TestClient) -> None:
    r = client.post(PROGRESS, json={"items": [item("guid-1"), item("guid-2")]})
    assert r.status_code == 200
    assert sorted(i["guid"] for i in r.json()["items"]) == ["guid-1", "guid-2"]
    assert set(r.json()) == {"items"}

    r = client.get(PROGRESS)
    assert r.status_code == 200
    body = r.json()
    assert set(body) == {"items", "mark"}
    assert [i["guid"] for i in body["items"]] == ["guid-1", "guid-2"]
    assert body["items"][0] == item("guid-1")
    mark = body["mark"]
    assert isinstance(mark, int) and mark > 0

    r = client.get(PROGRESS, params={"after": str(mark)})
    assert r.json() == {"items": [], "mark": mark}, (
        "mark does not roll back on empty page"
    )


def test_changes_by_pages(client: TestClient) -> None:
    client.post(PROGRESS, json={"items": [item(f"guid-{n}") for n in range(5)]})
    first = client.get(PROGRESS, params={"limit": "2"}).json()
    assert len(first["items"]) == 2
    rest = client.get(
        PROGRESS, params={"after": str(first["mark"]), "limit": "10"}
    ).json()
    assert len(rest["items"]) == 3
    assert rest["mark"] > first["mark"]
    seen = {i["guid"] for i in first["items"]} | {i["guid"] for i in rest["items"]}
    assert seen == {f"guid-{n}" for n in range(5)}


def test_the_answer_is_what_the_server_kept(client: TestClient) -> None:
    newer = item(position_ms=90_000, updated_at="2026-10-01T11:30:00.000Z")
    client.post(PROGRESS, json={"items": [newer]})
    r = client.post(PROGRESS, json={"items": [item(position_ms=5_000)]})
    assert r.json() == {"items": [newer]}, (
        "old position does not overwrite newer, and mobile sees this"
    )


def test_empty_progress_needs_no_database(directory: Directory) -> None:
    r = TestClient(_app(None, directory)).post(PROGRESS, json={"items": []})
    assert (r.status_code, r.json()) == (200, {"items": []})


@pytest.mark.parametrize(
    "body", [b"", b"{", b"[]", b"{}", b'{"items": 5}', b'{"items": {}}', b"\xff"]
)
def test_broken_progress_is_refused(client: TestClient, body: bytes) -> None:
    r = client.post(
        PROGRESS, content=body, headers={"content-type": "application/json"}
    )
    assert (r.status_code, r.json()) == (400, {"status": "invalid_request"})


def test_too_many_items_are_refused(client: TestClient) -> None:
    items = [item(f"g{n}") for n in range(podcast_progress.MAX_BATCH + 1)]
    r = client.post(PROGRESS, json={"items": items})
    assert (r.status_code, r.json()) == (400, {"status": "invalid_request"})
    assert client.get(PROGRESS).json()["items"] == []


@pytest.mark.parametrize(
    "params", [{"after": "x"}, {"after": "-1"}, {"limit": "x"}, {"after": "9" * 30}]
)
def test_changes_refuse_broken_parameters(
    client: TestClient, params: dict[str, str]
) -> None:
    r = client.get(PROGRESS, params=params)
    assert (r.status_code, r.json()) == (400, {"status": "invalid_request"})


# --- body limit --------------------------------------------------------------


def test_the_limits_are_as_agreed() -> None:
    assert podcast_api.MAX_SMALL_BODY == 8 * 1024
    assert podcast_api.MAX_PROGRESS_BODY == 2 * 1024 * 1024


def _send(app: Any, path: str, chunks: list[bytes], declared: str | None) -> Any:
    """Direct ASGI request: counts how many body chunks the server read."""
    taken: list[int] = []
    sent: list[dict[str, Any]] = []
    queue = list(chunks)

    async def receive() -> dict[str, Any]:
        if not queue:
            return {"type": "http.disconnect"}
        chunk = queue.pop(0)
        taken.append(len(chunk))
        return {"type": "http.request", "body": chunk, "more_body": bool(queue)}

    async def send(message: dict[str, Any]) -> None:
        sent.append(message)

    headers = [(b"content-type", b"application/json")]
    if declared is not None:
        headers.append((b"content-length", declared.encode()))
    scope = {
        "type": "http",
        "asgi": {"version": "3.0"},
        "http_version": "1.1",
        "method": "POST",
        "scheme": "http",
        "path": path,
        "raw_path": path.encode(),
        "query_string": b"",
        "headers": headers,
        "client": ("127.0.0.1", 1),
        "server": ("test", 80),
    }
    asyncio.run(app(scope, receive, send))
    status = next(m["status"] for m in sent if m["type"] == "http.response.start")
    return status, sum(taken)


@pytest.mark.parametrize(
    ("path", "limit"),
    [
        (SUBSCRIBE, 8 * 1024),
        (UNSUBSCRIBE, 8 * 1024),
        (PROGRESS, 2 * 1024 * 1024),
    ],
)
def test_a_declared_oversize_body_is_refused_unread(
    base: str, directory: Directory, path: str, limit: int
) -> None:
    status, taken = _send(
        _app(base, directory), path, [b"x" * 1024] * 4, str(limit + 1)
    )
    assert status == 400
    assert taken == 0, "declared size exceeds limit — body is not read at all"


@pytest.mark.parametrize("declared", ["abc", "-5", ""])
def test_a_nonsense_length_is_refused_unread(
    base: str, directory: Directory, declared: str
) -> None:
    status, taken = _send(_app(base, directory), SUBSCRIBE, [b"{}"], declared)
    assert (status, taken) == (400, 0)


@pytest.mark.parametrize(
    ("path", "limit"),
    [
        (SUBSCRIBE, 8 * 1024),
        (UNSUBSCRIBE, 8 * 1024),
        (PROGRESS, 2 * 1024 * 1024),
    ],
)
def test_an_undeclared_oversize_body_stops_at_the_limit(
    base: str, directory: Directory, path: str, limit: int
) -> None:
    piece = 64 * 1024 if limit > 64 * 1024 else 1024
    pieces = [b" " * piece] * (limit // piece * 4)
    status, taken = _send(_app(base, directory), path, pieces, None)
    assert status == 400
    assert limit < taken <= limit + piece, (
        "reading stops at the first chunk beyond limit"
    )


def test_a_body_exactly_at_the_limit_is_read(base: str, directory: Directory) -> None:
    body = json.dumps({"feed_url": FEED}).encode()
    body += b" " * (8 * 1024 - len(body))
    status, taken = _send(_app(base, directory), SUBSCRIBE, [body], str(len(body)))
    assert (status, taken) == (200, 8 * 1024)


# --- own and others ----------------------------------------------------------


def test_each_person_has_their_own(
    client: TestClient, base: str, as_bob: Callable[[], None]
) -> None:
    client.post(SUBSCRIBE, json={"feed_url": FEED})
    _save(base, FEED, "Secret Show", 2)
    client.post(PROGRESS, json={"items": [item("guid-1")]})

    as_bob()
    assert client.get(LIST).json() == {"podcasts": []}
    assert client.get(EPISODES, params={"feed_url": FEED}).status_code == 404
    assert client.get(PROGRESS).json()["items"] == []
    assert client.post(UNSUBSCRIBE, json={"feed_url": FEED}).json() == {
        "removed": False
    }

    r = client.post(SUBSCRIBE, json={"feed_url": FEED})
    assert r.json()["result"] == "new", "another user's subscription is not mine"
    assert len(client.get(EPISODES, params={"feed_url": FEED}).json()["episodes"]) == 2
    client.post(PROGRESS, json={"items": [item("guid-2")]})
    assert [i["guid"] for i in client.get(PROGRESS).json()["items"]] == ["guid-2"]


@pytest.mark.real_auth
@pytest.mark.parametrize(
    ("method", "path"),
    [
        ("GET", SEARCH),
        ("GET", LIST),
        ("POST", SUBSCRIBE),
        ("POST", UNSUBSCRIBE),
        ("GET", EPISODES),
        ("POST", PROGRESS),
        ("GET", PROGRESS),
    ],
)
def test_without_login_everything_is_closed(
    base: str, directory: Directory, method: str, path: str
) -> None:
    r = TestClient(_app(base, directory)).request(
        method, path, params={"q": "secret"}, json={"items": []}
    )
    assert r.status_code == 401
    assert directory.calls == []


# --- database unavailable ----------------------------------------------------


def _calls(client: TestClient) -> Iterator[Any]:
    yield client.get(LIST)
    yield client.post(SUBSCRIBE, json={"feed_url": FEED})
    yield client.post(UNSUBSCRIBE, json={"feed_url": FEED})
    yield client.get(EPISODES, params={"feed_url": FEED})
    yield client.get(EPISODES, params={"feed_url": FEED, "order": "oldest"})
    yield client.get(NEW)
    yield client.post(PROGRESS, json={"items": [item()]})
    yield client.get(PROGRESS)


def test_no_database_is_unavailable_everywhere(directory: Directory) -> None:
    for r in _calls(TestClient(_app(None, directory))):
        assert (r.status_code, r.json()) == (503, {"status": "library_unavailable"})


def test_a_dead_database_is_unavailable_everywhere(directory: Directory) -> None:
    dead = "postgresql://music@127.0.0.1:1/nothing"
    for r in _calls(TestClient(_app(dead, directory))):
        assert (r.status_code, r.json()) == (503, {"status": "library_unavailable"})


@pytest.mark.parametrize(
    "error", [asyncpg.PostgresError, asyncpg.InterfaceError, OSError]
)
def test_a_database_error_in_the_middle_is_unavailable_not_a_crash(
    base: str,
    directory: Directory,
    monkeypatch: pytest.MonkeyPatch,
    error: type[Exception],
) -> None:
    closed: list[int] = []
    real_close = asyncpg.Connection.close

    async def counting_close(self: asyncpg.Connection, **kw: Any) -> None:
        closed.append(1)
        await real_close(self, **kw)

    async def broken(*args: Any, **kw: Any) -> Any:
        raise error("secret-show.xml is gone")

    for module, name in (
        (podcasts, "subscriptions"),
        (podcasts, "subscribe"),
        (podcasts, "unsubscribe"),
        (podcasts, "episodes"),
        (podcast_new, "episodes_ordered"),
        (podcast_new, "new_episodes"),
        (podcast_progress, "put"),
        (podcast_progress, "changes"),
    ):
        monkeypatch.setattr(module, name, broken)
    monkeypatch.setattr(asyncpg.Connection, "close", counting_close)

    client = TestClient(_app(base, directory), raise_server_exceptions=False)
    answers = list(_calls(client))
    for r in answers:
        assert (r.status_code, r.json()) == (503, {"status": "library_unavailable"})
    assert len(closed) == len(answers), "connection is closed even after failure"


def test_the_connection_is_closed_after_every_request(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    opened: list[int] = []
    closed: list[int] = []
    real_connect = asyncpg.connect
    real_close = asyncpg.Connection.close

    async def counting_connect(*args: Any, **kw: Any) -> Any:
        opened.append(1)
        return await real_connect(*args, **kw)

    async def counting_close(self: asyncpg.Connection, **kw: Any) -> None:
        closed.append(1)
        await real_close(self, **kw)

    monkeypatch.setattr(asyncpg, "connect", counting_connect)
    monkeypatch.setattr(asyncpg.Connection, "close", counting_close)
    answers = list(_calls(client))
    assert len(opened) == len(closed) == len(answers)

    opened.clear()
    client.get(SEARCH, params={"q": "secret"})
    client.post(SUBSCRIBE, json={"feed_url": "not a url"})
    client.post(PROGRESS, json={"items": []})
    assert opened == [], "search, bad URL, and empty batch do not touch the database"


# --- log ---------------------------------------------------------------------


def test_nothing_personal_in_the_log(
    client: TestClient, base: str, caplog: pytest.LogCaptureFixture
) -> None:
    caplog.set_level(logging.DEBUG)
    client.get(SEARCH, params={"q": "secret show"})
    client.post(SUBSCRIBE, json={"feed_url": FEED})
    _save(base, FEED, "Secret Show", 2)
    client.get(LIST)
    client.get(EPISODES, params={"feed_url": FEED})
    client.post(PROGRESS, json={"items": [item("guid-secret")]})
    client.get(PROGRESS)
    client.post(UNSUBSCRIBE, json={"feed_url": FEED})
    client.post(SUBSCRIBE, json={"feed_url": "ftp://secret-show.example.org/"})

    text = "\n".join(
        f"{record.getMessage()} {record.__dict__}" for record in caplog.records
    ).lower()
    for word in ("secret", "feeds.example.org", "cdn.example.org", "guid-"):
        assert word not in text


# --- installation ------------------------------------------------------------


def test_installing_podcasts_leaves_the_main_library_alone(base: str) -> None:
    """Podcasts can be installed without a database — "My Music" is not affected."""
    app = create_app(
        database_url=base,
        catalog=CATALOG,
    )
    mine = app.state.library
    install_podcasts(app, database_url=None, client=None)
    assert app.state.library is mine
    client = TestClient(app)
    assert client.get(LIST).status_code == 503
    assert client.get("/v1/favorites").status_code == 200
