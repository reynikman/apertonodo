"""Blind review FT-758: tests fail on current module."""

from __future__ import annotations

import asyncio
import time


from tests.test_playable_from_extensions import A, NOTHING, SANDMAN, Ext, make


def test_info_failure_is_not_cached_forever() -> None:
    """The first /v1/info failed (extension was still starting up); then it is healthy and answers "no"."""
    a = Ext({SANDMAN})
    a.down = True

    async def go() -> tuple[list[bool], list[bool]]:
        playable, client = make({A: a})
        async with client:
            first = await playable.pairs([NOTHING])
            a.down = False
            second = await playable.pairs([NOTHING])
            return first, second

    first, second = asyncio.run(go())
    assert first == [True]
    # extension recovered: "did not respond" must not be remembered for the lifetime of the object
    assert second == [False]


def test_batches_of_a_dead_extension_cost_one_timeout_not_four() -> None:
    """Artist page (200 tracks = 4 batches): a silent extension must not cost 4 timeouts."""
    a = Ext(set())
    a.slow = 5.0
    pairs = [("Artist", f"Song {i}") for i in range(200)]

    async def go() -> float:
        playable, client = make({A: a}, timeout=0.3)
        async with client:
            await playable.pairs([NOTHING])  # warm up /v1/info
            began = time.monotonic()
            res = await playable.pairs(pairs)
            assert res == [True] * 200
            return time.monotonic() - began

    elapsed = asyncio.run(go())
    assert elapsed < 0.6, f"4 consecutive batches: {elapsed:.2f}s instead of ~0.3s"


def test_slow_healthy_extension_batches_run_concurrently() -> None:
    a = Ext(set())
    a.slow = 0.3
    pairs = [("Artist", f"Song {i}") for i in range(200)]

    async def go() -> float:
        playable, client = make({A: a})
        async with client:
            await playable.pairs([NOTHING])
            began = time.monotonic()
            await playable.pairs(pairs)
            return time.monotonic() - began

    assert asyncio.run(go()) < 0.8
