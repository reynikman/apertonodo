"""Podcasts are wired to the server (FT-702).

Before this card, podcast modules sat in `main` separately: nobody called
`install_podcasts` or `install_podcast_catalog`, and `/v1/podcasts/*` responded with 404.

What the tests prove:
- prod app (`app.main.app`) and `create_app` serve podcast endpoints;
- endpoints are guarded by auth lock, like all `/v1/*`;
- without `PODCASTS_LIVE=1` no network access happens: search and catalog honestly return 503,
  feed crawler does not start;
- with `PODCASTS_LIVE=1` a network client exists, and subscribing wakes up feed crawler immediately.

What they do not prove: that Apple directory and the feeds themselves respond — that is tested on
prod address after deployment.
"""
from __future__ import annotations

import threading

from fastapi.testclient import TestClient

from app import podcast_wiring
from app.main import app as production_app
from app.main import create_app

KEY = {"x-apertonodo-key": "pytest-key-" + "0" * 24}

PODCAST_PATHS = {
    "/v1/podcasts/search",
    "/v1/podcasts",
    "/v1/podcasts/subscribe",
    "/v1/podcasts/unsubscribe",
    "/v1/podcasts/episodes",
    "/v1/podcasts/progress",
    "/v1/podcasts/categories",
    "/v1/podcasts/top",
}


def _paths(app) -> set[str]:
    # FastAPI 0.142 keeps included APIRouter as a whole (`_IncludedRouter`), rather than
    # flattening its routes into `app.routes` — we traverse inside.
    found: set[str] = set()

    def walk(routes) -> None:
        for r in routes:
            inner = getattr(r, "original_router", None)
            if inner is not None:
                walk(inner.routes)
            else:
                found.add(getattr(r, "path", ""))

    walk(app.routes)
    return found


def test_production_app_serves_podcasts() -> None:
    missing = PODCAST_PATHS - _paths(production_app)
    assert missing == set(), f"prod app has no handlers: {sorted(missing)}"


def test_create_app_serves_podcasts() -> None:
    missing = PODCAST_PATHS - _paths(create_app())
    assert missing == set(), f"create_app has no handlers: {sorted(missing)}"


def test_podcasts_are_behind_the_lock() -> None:
    # Production build applies the lock; `create_app()` without `api_key` intentionally does not.
    client = TestClient(production_app)
    for path in ("/v1/podcasts/categories", "/v1/podcasts/top", "/v1/podcasts/search?q=x"):
        assert client.get(path).status_code == 401, path


def test_categories_answer_without_network() -> None:
    client = TestClient(create_app(), headers=KEY)
    body = client.get("/v1/podcasts/categories").json()
    assert len(body["categories"]) == 12


def test_without_live_switch_nothing_goes_to_the_network() -> None:
    app = create_app()
    assert app.state.podcast_client is None
    assert app.state.podcast_catalog_client is None
    assert app.state.podcast_crawler is None
    client = TestClient(app, headers=KEY)
    assert client.get("/v1/podcasts/search?q=history").status_code == 503
    assert client.get("/v1/podcasts/top").status_code == 503


def test_live_switch_is_explicit() -> None:
    assert podcast_wiring.live_from_env({}) is False
    assert podcast_wiring.live_from_env({"PODCASTS_LIVE": "0"}) is False
    assert podcast_wiring.live_from_env({"PODCASTS_LIVE": ""}) is False
    assert podcast_wiring.live_from_env({"PODCASTS_LIVE": "1"}) is True


def test_kick_wakes_the_crawler_at_once() -> None:
    passes: list[int] = []
    woke = threading.Event()

    def one_pass() -> None:
        passes.append(1)
        if len(passes) >= 2:
            woke.set()

    crawler = podcast_wiring.Crawler(one_pass, interval_s=3600)
    crawler.start()
    try:
        crawler.kick()
        assert woke.wait(timeout=5), "subscription did not wake up crawler"
    finally:
        crawler.stop()
    assert not crawler.thread.is_alive()


def test_crawler_survives_a_failed_pass() -> None:
    passes: list[int] = []
    woke = threading.Event()

    def one_pass() -> None:
        passes.append(1)
        if len(passes) == 1:
            raise OSError("лента не ответила")
        woke.set()

    crawler = podcast_wiring.Crawler(one_pass, interval_s=3600)
    crawler.start()
    try:
        crawler.kick()
        assert woke.wait(timeout=5), "crawler stopped after error"
    finally:
        crawler.stop()


def test_live_install_has_client_and_crawler(monkeypatch) -> None:
    started: list[bool] = []
    monkeypatch.setattr(podcast_wiring.Crawler, "start", lambda self: started.append(True))
    app = create_app()
    podcast_wiring.install_podcast_suite(
        app, database_url="postgresql://unused", env={"PODCASTS_LIVE": "1"}
    )
    assert app.state.podcast_client is not None
    assert app.state.podcast_catalog_client is app.state.podcast_client
    assert app.state.podcast_crawler is not None and started == [True]
    assert app.state.podcast_kick == app.state.podcast_crawler.kick


def test_live_install_without_database_does_not_crawl(monkeypatch) -> None:
    monkeypatch.setattr(podcast_wiring.Crawler, "start", lambda self: None)
    app = create_app()
    podcast_wiring.install_podcast_suite(app, database_url=None, env={"PODCASTS_LIVE": "1"})
    assert app.state.podcast_crawler is None
    assert app.state.podcast_kick is None
