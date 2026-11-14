from __future__ import annotations

import asyncio

from app.musicbrainz import MetadataCache, MusicBrainzClient


class FakeHttp:
    def __init__(self) -> None:
        self.calls = 0

    async def get_json(self, url: str, params: dict[str, str]) -> dict:
        self.calls += 1
        return {"recordings": [{"id": "mb-1", "title": "Duality"}]}


def test_identical_lookups_hit_network_once() -> None:
    http = FakeHttp()
    cache = MetadataCache()
    client = MusicBrainzClient(http=http, cache=cache)

    async def run() -> None:
        first = await client.search_recordings("duality")
        second = await client.search_recordings("duality")
        assert first == second

    asyncio.run(run())
    assert http.calls == 1


def test_cache_forgets_the_least_recent_lookup_past_its_limit() -> None:
    """Audit 18 September: dict grew without bounds, every search — forever in memory."""
    cache = MetadataCache(max_entries=2)

    async def run() -> list[object]:
        await cache.set("a", 1)
        await cache.set("b", 2)
        assert await cache.get("a") == 1  # "a" was accessed more recently than "b"
        await cache.set("c", 3)
        return [await cache.get(key) for key in ("a", "b", "c")]

    assert asyncio.run(run()) == [1, None, 3]
