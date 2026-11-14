"""MusicBrainz responds 503 to half the requests, and that is no reason to return empty results.

Measurement on production server September 18, 2026: six requests with 1.1 s interval — three
200 replies and three 503. They count by requesting IP address, and
we egress via a shared proxy. With a single retry attempt, half the searches
returned "nothing found", even though the song is in the catalog.

What these tests do not prove: that MusicBrainz is reachable at all and that retries
always rescue. Three failures in a row is still a failure, and search honestly returns
what was found locally.
"""

from __future__ import annotations

import asyncio

import httpx
import pytest

from app.musicbrainz import ATTEMPTS, ThrottledHttpJson

URL = "https://musicbrainz.org/ws/2/recording"


def _client(statuses: list[int], seen: list[int]) -> httpx.AsyncClient:
    def handler(request: httpx.Request) -> httpx.Response:
        code = statuses[min(len(seen), len(statuses) - 1)]
        seen.append(code)
        if code == 503:
            return httpx.Response(503, headers={"retry-after": "0"}, text="slow down")
        return httpx.Response(200, json={"recordings": [{"id": "x"}]})

    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


def test_one_refusal_does_not_lose_the_answer() -> None:
    seen: list[int] = []
    http = ThrottledHttpJson(client=_client([503, 200], seen), min_interval_s=0.0)

    payload = asyncio.run(http.get_json(URL, {"query": "duality"}))

    assert payload["recordings"], "output lost after one 503"
    assert seen == [503, 200], seen


def test_two_refusals_in_a_row_still_do_not_lose_the_answer() -> None:
    """Exactly what happens in production: refusal every other time."""
    seen: list[int] = []
    http = ThrottledHttpJson(client=_client([503, 503, 200], seen), min_interval_s=0.0)

    payload = asyncio.run(http.get_json(URL, {"query": "duality"}))

    assert payload["recordings"]
    assert seen == [503, 503, 200], seen


def test_endless_refusal_is_reported_not_hidden() -> None:
    seen: list[int] = []
    http = ThrottledHttpJson(client=_client([503], seen), min_interval_s=0.0)

    with pytest.raises(httpx.HTTPStatusError):
        asyncio.run(http.get_json(URL, {"query": "duality"}))

    assert len(seen) == ATTEMPTS, f"there were {len(seen)} attempts, not {ATTEMPTS}"
