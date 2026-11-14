"""FT-688: podcast catalog — sections and popular."""

from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
import json
import logging
import time
from typing import Any

from fastapi import APIRouter, FastAPI, Request
from fastapi.responses import JSONResponse
import httpx

from app.podcast_search import (
    MAX_BYTES,
    FoundPodcast,
    PodcastSearchUnavailable,
    _clean_feed_url,
    _clean_image_url,
    _clean_text,
)

# httpx at INFO level logs every request line in full.
logging.getLogger("httpx").setLevel(logging.WARNING)

TOP_URL: str = (
    "https://itunes.apple.com/{country}/rss/toppodcasts/limit={limit}{genre}/json"
)
LOOKUP_URL: str = "https://itunes.apple.com/lookup"
TOP_LIMIT: int = 30
FRESH_S: int = 6 * 3600
# An empty Apple response often means a one-off failure: keep it for minutes, not hours.
EMPTY_FRESH_S: int = 10 * 60
STALE_S: int = 24 * 3600
MAX_KEYS: int = 200
DEFAULT_COUNTRY: str = "us"
TIMEOUT_S: float = 10.0


@dataclass(frozen=True)
class Category:
    id: int
    ru: str
    en: str


CATEGORIES: tuple[Category, ...] = (
    Category(1533, "Наука", "Science"),
    Category(1487, "История", "History"),
    Category(1324, "Общество и культура", "Society & Culture"),
    Category(1303, "Комедия", "Comedy"),
    Category(1304, "Образование", "Education"),
    Category(1318, "Технологии", "Technology"),
    Category(1321, "Бизнес", "Business"),
    Category(1512, "Здоровье", "Health & Fitness"),
    Category(1545, "Спорт", "Sports"),
    Category(1305, "Дети и семья", "Kids & Family"),
    Category(1483, "Художественные", "Fiction"),
    Category(1489, "Новости", "News"),
)

_CATEGORY_BY_ID: dict[int, Category] = {c.id: c for c in CATEGORIES}
_CATEGORY_ID_BY_STR: dict[str, int] = {str(c.id): c.id for c in CATEGORIES}


def country_of(raw: object) -> str:
    if (
        isinstance(raw, str)
        and len(raw) == 2
        and raw.isascii()
        and raw.islower()
        and raw.isalpha()
    ):
        return raw
    return DEFAULT_COUNTRY


async def _fetch_json(
    client: httpx.AsyncClient,
    url: str,
    params: dict[str, str] | None = None,
) -> Any:
    failed = False
    body = bytearray()
    try:
        async with (
            asyncio.timeout(TIMEOUT_S),
            client.stream(
                "GET",
                url,
                params=params,
                headers={"Accept-Encoding": "identity"},
                timeout=TIMEOUT_S,
                follow_redirects=False,
            ) as response,
        ):
            packed = response.headers.get("content-encoding", "").strip().lower()
            if response.status_code != 200 or packed not in ("", "identity"):
                failed = True
            else:
                async for chunk in response.aiter_bytes():
                    body += chunk
                    if len(body) > MAX_BYTES:
                        failed = True
                        break
    except (httpx.HTTPError, TimeoutError):
        failed = True

    if failed:
        raise PodcastSearchUnavailable()

    try:
        data = json.loads(body)
    except (ValueError, RecursionError):
        failed = True

    if failed:
        raise PodcastSearchUnavailable()

    return data


async def top(
    *,
    client: httpx.AsyncClient,
    country: str = DEFAULT_COUNTRY,
    category: int | None = None,
) -> list[FoundPodcast]:
    if category is not None and category not in _CATEGORY_BY_ID:
        raise ValueError(f"Unknown category: {category}")

    cc = country_of(country)
    genre = f"/genre={category}" if category is not None else ""
    top_url = TOP_URL.format(country=cc, limit=TOP_LIMIT, genre=genre)

    feed_data = await _fetch_json(client, top_url)
    if not isinstance(feed_data, dict):
        raise PodcastSearchUnavailable()

    feed = feed_data.get("feed")
    if not isinstance(feed, dict):
        raise PodcastSearchUnavailable()

    raw_entry = feed.get("entry")
    if raw_entry is None or raw_entry == []:
        return []

    if isinstance(raw_entry, dict):
        entry_list: list[object] = [raw_entry]
    elif isinstance(raw_entry, list):
        entry_list = raw_entry
    else:
        raise PodcastSearchUnavailable()

    podcast_ids: list[str] = []
    seen_ids: set[str] = set()

    for item in entry_list:
        if not isinstance(item, dict):
            continue
        id_obj = item.get("id")
        if not isinstance(id_obj, dict):
            continue
        attrs = id_obj.get("attributes")
        if not isinstance(attrs, dict):
            continue
        raw_id = attrs.get("im:id")
        if (
            isinstance(raw_id, str)
            and raw_id.isascii()
            and raw_id.isdigit()
            and 1 <= len(raw_id) <= 12
        ):
            if raw_id not in seen_ids:
                seen_ids.add(raw_id)
                podcast_ids.append(raw_id)
                if len(podcast_ids) >= TOP_LIMIT:
                    break

    if not podcast_ids:
        return []

    lookup_params = {
        "id": ",".join(podcast_ids),
        "entity": "podcast",
        "country": cc,
    }
    lookup_data = await _fetch_json(client, LOOKUP_URL, params=lookup_params)
    if not isinstance(lookup_data, dict):
        raise PodcastSearchUnavailable()

    results = lookup_data.get("results")
    if not isinstance(results, list):
        raise PodcastSearchUnavailable()

    by_id: dict[str, FoundPodcast] = {}
    for row in results:
        if not isinstance(row, dict):
            continue

        cid = row.get("collectionId")
        if type(cid) is not int or isinstance(cid, bool):
            continue

        cid_str = str(cid)
        if cid_str not in seen_ids or cid_str in by_id:
            continue

        feed_url = _clean_feed_url(row.get("feedUrl"))
        if feed_url is None:
            continue

        title = _clean_text(row.get("collectionName"))
        if not title:
            title = _clean_text(row.get("trackName"))
        if not title:
            continue

        author = _clean_text(row.get("artistName"))
        image = _clean_image_url(row.get("artworkUrl600")) or _clean_image_url(
            row.get("artworkUrl100")
        )
        raw_count = row.get("trackCount")
        episodes = (
            raw_count
            if type(raw_count) is int
            and not isinstance(raw_count, bool)
            and 1 <= raw_count <= 999_999
            else None
        )

        by_id[cid_str] = FoundPodcast(
            title=title,
            author=author,
            feed_url=feed_url,
            image=image,
            episodes=episodes,
        )

    podcasts: list[FoundPodcast] = []
    seen_feeds: set[str] = set()

    for pid in podcast_ids:
        p = by_id.get(pid)
        if p is None:
            continue
        if p.feed_url in seen_feeds:
            continue
        seen_feeds.add(p.feed_url)
        podcasts.append(p)

    return podcasts


@dataclass
class _CacheEntry:
    recorded_at: float
    podcasts: list[FoundPodcast]
    empty: bool = False


def _fresh_for(entry: _CacheEntry) -> int:
    return EMPTY_FRESH_S if entry.empty else FRESH_S


class TopCache:
    def __init__(self, *, clock: Callable[[], float] = time.monotonic) -> None:
        self._clock = clock
        self._entries: dict[tuple[str, int | None], _CacheEntry] = {}
        # The last non-empty response per key — a fallback list on failure and on an empty response.
        self._full: dict[tuple[str, int | None], _CacheEntry] = {}

    async def get(
        self,
        key: tuple[str, int | None],
        fetch: Callable[[], Awaitable[list[FoundPodcast]]],
    ) -> list[FoundPodcast]:
        now = self._clock()
        entry = self._entries.get(key)
        if entry is not None and (now - entry.recorded_at) < _fresh_for(entry):
            return entry.podcasts
        full = self._full.get(key)
        if full is not None and (now - full.recorded_at) >= STALE_S:
            full = None

        try:
            podcasts = await fetch()
        except PodcastSearchUnavailable:
            if full is not None:
                return full.podcasts
            raise

        self._entries.pop(key, None)
        if not podcasts and full is not None:
            # An empty response does not overwrite a fresh full list; we will ask again in minutes.
            podcasts = full.podcasts
            self._entries[key] = _CacheEntry(
                recorded_at=now, podcasts=podcasts, empty=True
            )
            self._full[key] = full
        else:
            entry = _CacheEntry(recorded_at=now, podcasts=podcasts, empty=not podcasts)
            self._entries[key] = entry
            if podcasts:
                self._full[key] = entry

        while len(self._entries) > MAX_KEYS:
            oldest_key = next(iter(self._entries))
            del self._entries[oldest_key]
            self._full.pop(oldest_key, None)

        return podcasts


router = APIRouter()


@router.get("/v1/podcasts/categories")
async def get_categories() -> Any:
    return {"categories": [{"id": c.id, "ru": c.ru, "en": c.en} for c in CATEGORIES]}


@router.get("/v1/podcasts/top")
async def get_top(request: Request) -> Any:
    category_id: int | None = None
    if "category" in request.query_params:
        raw_cat = request.query_params["category"]
        if raw_cat not in _CATEGORY_ID_BY_STR:
            return JSONResponse({"status": "invalid_request"}, status_code=400)
        category_id = _CATEGORY_ID_BY_STR[raw_cat]

    country = country_of(request.query_params.get("country"))

    client: httpx.AsyncClient | None = getattr(
        request.app.state, "podcast_catalog_client", None
    )
    if client is None:
        return JSONResponse({"status": "podcast_search_unavailable"}, status_code=503)

    cache: TopCache | None = getattr(request.app.state, "podcast_catalog_cache", None)
    if cache is None:
        return JSONResponse({"status": "podcast_search_unavailable"}, status_code=503)

    active_client = client
    target_category = category_id
    target_country = country

    async def _fetch() -> list[FoundPodcast]:
        return await top(
            client=active_client,
            country=target_country,
            category=target_category,
        )

    key = (country, category_id)
    try:
        items = await cache.get(key, _fetch)
    except PodcastSearchUnavailable:
        return JSONResponse({"status": "podcast_search_unavailable"}, status_code=503)

    return {
        "podcasts": [
            {
                "feed_url": p.feed_url,
                "title": p.title,
                "author": p.author,
                "image": p.image,
                "episodes": p.episodes,
            }
            for p in items
        ]
    }


def install_podcast_catalog(
    app: FastAPI,
    *,
    client: httpx.AsyncClient | None,
    clock: Callable[[], float] = time.monotonic,
) -> None:
    app.state.podcast_catalog_client = client
    app.state.podcast_catalog_cache = TopCache(clock=clock)
    app.include_router(router)


__all__ = [
    "CATEGORIES",
    "Category",
    "DEFAULT_COUNTRY",
    "FRESH_S",
    "LOOKUP_URL",
    "EMPTY_FRESH_S",
    "MAX_KEYS",
    "STALE_S",
    "TIMEOUT_S",
    "TOP_LIMIT",
    "TOP_URL",
    "TopCache",
    "country_of",
    "install_podcast_catalog",
    "top",
]
