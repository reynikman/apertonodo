"""FT-655: podcast search in public directory (iTunes Search API)."""

from __future__ import annotations

import asyncio
from dataclasses import dataclass
import json
import logging
import unicodedata
import urllib.parse

import httpx

# httpx at INFO level logs entire request URL, including search query parameters.
logging.getLogger("httpx").setLevel(logging.WARNING)

SEARCH_URL = "https://itunes.apple.com/search"
MAX_QUERY = 200
MIN_QUERY = 2
MAX_LIMIT = 50
MAX_BYTES = 1024 * 1024
TIMEOUT_S = 10.0
MAX_URL = 2048


class PodcastSearchUnavailable(Exception):
    """Podcast directory is unavailable or returned an invalid response."""

    def __init__(self) -> None:
        super().__init__("Podcast directory unavailable")


@dataclass(frozen=True)
class FoundPodcast:
    title: str
    author: str
    feed_url: str
    image: str | None
    episodes: int | None


def _clean_text(raw: object, max_len: int = 500) -> str:
    if not isinstance(raw, str):
        return ""
    # Control characters, text direction marks, and lone surrogates (categories
    # C*) do not go to the screen; whitespace first collapses to spaces.
    spaced = " ".join(raw.split())
    cleaned = "".join(ch for ch in spaced if unicodedata.category(ch)[0] != "C")
    return " ".join(cleaned.split())[:max_len]


def _clean_url(raw: object, schemes: tuple[str, ...]) -> str | None:
    if not isinstance(raw, str):
        return None
    url = raw.strip()
    if not url or len(url) > MAX_URL or "\\" in url:
        return None
    if any(ch.isspace() or not ch.isprintable() for ch in url):
        return None
    try:
        parsed = urllib.parse.urlsplit(url)
        parsed.port  # noqa: B018 — malformed port raises exception
    except ValueError:
        return None
    if parsed.scheme not in schemes or not parsed.hostname:
        return None
    if "@" in parsed.netloc:
        return None
    return url


def _clean_feed_url(raw: object) -> str | None:
    return _clean_url(raw, ("http", "https"))


def _clean_image_url(raw: object) -> str | None:
    return _clean_url(raw, ("https",))


async def search(
    query: str,
    *,
    client: httpx.AsyncClient,
    limit: int = 20,
) -> list[FoundPodcast]:
    normalized_query = _clean_text(query, MAX_QUERY)
    if len(normalized_query) < MIN_QUERY:
        return []

    clamped_limit = max(1, min(limit, MAX_LIMIT))

    # Exception is raised outside `except`: `from None` only hides previous exception from
    # printing, but it remains in `__context__` along with request URL.
    failed = False
    body = bytearray()
    try:
        # httpx timeout is per read; overall timeout protects against trickle attacks.
        async with (
            asyncio.timeout(TIMEOUT_S),
            client.stream(
                "GET",
                SEARCH_URL,
                params={
                    "media": "podcast",
                    "entity": "podcast",
                    "term": normalized_query,
                    "limit": str(clamped_limit),
                },
                # Do not request or decompress gzip: 200 KiB gzip
                # can expand to hundreds of megabytes before size check.
                headers={"Accept-Encoding": "identity"},
                timeout=TIMEOUT_S,
                follow_redirects=False,
            ) as response,
        ):
            packed = response.headers.get("content-encoding", "").strip().lower()
            if response.status_code != 200 or packed not in ("", "identity"):
                failed = True
            else:
                # No compression (checked above), so these are raw bytes as received.
                async for chunk in response.aiter_bytes():
                    body += chunk
                    if len(body) > MAX_BYTES:
                        failed = True
                        break
    except (httpx.HTTPError, TimeoutError):
        failed = True
    if failed:
        raise PodcastSearchUnavailable()

    data: object = None
    try:
        data = json.loads(body)
    except (ValueError, RecursionError):
        failed = True
    if failed:
        raise PodcastSearchUnavailable()

    if not isinstance(data, dict):
        raise PodcastSearchUnavailable() from None

    results = data.get("results")
    if not isinstance(results, list):
        raise PodcastSearchUnavailable() from None

    seen_feeds: set[str] = set()
    podcasts: list[FoundPodcast] = []

    for item in results:
        if not isinstance(item, dict):
            continue

        feed_url = _clean_feed_url(item.get("feedUrl"))
        if feed_url is None:
            continue

        if feed_url in seen_feeds:
            continue

        title = _clean_text(item.get("collectionName"))
        if not title:
            title = _clean_text(item.get("trackName"))
        if not title:
            continue

        author = _clean_text(item.get("artistName"))

        image = _clean_image_url(item.get("artworkUrl600")) or _clean_image_url(
            item.get("artworkUrl100")
        )

        raw_count = item.get("trackCount")
        episodes = (
            raw_count if type(raw_count) is int and 1 <= raw_count <= 999_999 else None
        )

        seen_feeds.add(feed_url)
        podcasts.append(
            FoundPodcast(
                title=title,
                author=author,
                feed_url=feed_url,
                image=image,
                episodes=episodes,
            )
        )
        if len(podcasts) >= clamped_limit:
            break

    return podcasts
