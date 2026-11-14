"""Podcast feed language is stored and served (FT-737, Яз-1).

Lead check, executor does not modify it. Contract:
- `Podcast.language: str | None = None` — last field, with default value;
  `parse_podcast` takes channel's `<language>` via `podcast_lang.language_of`.
- Migration `058_podcast_language.sql`: `podcast_feeds.language text NULL`, repeat
  run does not fail.
- `save_feed` writes language; feed removed `<language>` — in db `NULL` (language follows the feed).
- `Subscription.language: str | None = None` — last field; `subscriptions()`
  populates it; `GET /v1/podcasts/subscriptions` returns key `language` (before the first
  feed fetch — `null`).
"""

from __future__ import annotations

import asyncio

import asyncpg

from app.migrate import apply
from app.podcast_feed import parse_podcast
from app.podcasts import save_feed, subscribe, subscriptions
from tests.test_podcast_feed import feed, item
from tests.test_podcasts import ANN, FEED, NOW, _run, base, ep, pod  # noqa: F401


def _head(language: str) -> str:
    return f"<title>Подкаст</title><language>{language}</language>"


def test_feed_language_is_parsed() -> None:
    podcast = parse_podcast(feed(item(), head=_head("ru-RU")))
    assert podcast is not None
    assert podcast.language == "ru"


def test_language_word_is_parsed_like_the_helper() -> None:
    podcast = parse_podcast(feed(item(), head=_head("English")))
    assert podcast is not None
    assert podcast.language == "en"


def test_language_with_long_indent_is_parsed() -> None:
    """FT-737 review: tag with newlines and indentation longer than 35 characters."""
    podcast = parse_podcast(
        feed(item(), head=_head("\n" + " " * 40 + "ru\n" + " " * 8))
    )
    assert podcast is not None
    assert podcast.language == "ru"


def test_no_language_is_none() -> None:
    podcast = parse_podcast(feed(item()))
    assert podcast is not None
    assert podcast.language is None


def test_junk_language_is_none() -> None:
    podcast = parse_podcast(feed(item(), head=_head("@@@")))
    assert podcast is not None
    assert podcast.language is None


def test_podcast_without_language_argument_still_builds() -> None:
    assert pod(ep(1)).language is None


def test_saved_language_comes_back_with_the_subscription(base: str) -> None:  # noqa: F811
    async def work(conn: asyncpg.Connection) -> None:
        await subscribe(conn, ANN, FEED, now=NOW)
        (sub,) = await subscriptions(conn, ANN)
        assert sub.language is None, "feed has not been fetched yet"
        await save_feed(conn, FEED, pod(ep(1, day=1), language="de"), now=NOW)
        (sub,) = await subscriptions(conn, ANN)
        assert sub.language == "de"

    _run(base, work)


def test_language_follows_the_feed(base: str) -> None:  # noqa: F811
    async def work(conn: asyncpg.Connection) -> None:
        await subscribe(conn, ANN, FEED, now=NOW)
        await save_feed(conn, FEED, pod(ep(1, day=1), language="de"), now=NOW)
        await save_feed(conn, FEED, pod(ep(1, day=1)), now=NOW)
        (sub,) = await subscriptions(conn, ANN)
        assert sub.language is None

    _run(base, work)


def test_migration_runs_twice(base: str) -> None:  # noqa: F811
    asyncio.run(apply(base))

    async def work(conn: asyncpg.Connection) -> None:
        kind = await conn.fetchval(
            "SELECT data_type FROM information_schema.columns "
            "WHERE table_name = 'podcast_feeds' AND column_name = 'language'"
        )
        assert kind == "text"

    _run(base, work)
