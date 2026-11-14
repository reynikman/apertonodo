"""FT-758 (FT-594d, P8): "is the song playable" is queried from extensions (`POST /v1/has`), not from the releases table.

`app.playable_from_extensions.Playable(urls, client=…)`:
- `await pairs([(artist, title), …]) -> list[bool]` — by response per pair, in the same order;
- `await playable(artist, [title, …]) -> list[bool]` — the same for a single artist.

Contract (`contracts/extension-api.md`, `POST /v1/has`): only extensions with `has` in `features` are queried
(`GET /v1/info`, cached); batch size <= 50 pairs; response within 2 s. Summary across extensions:
- if at least one returned `true` — playable;
- otherwise if at least one failed to answer (503, error, timeout, malformed response) — **show as playable**, do not hide;
- otherwise (all responding extensions returned `false`, or nobody to ask) — not playable.
Empty artist or title — `false` without query. Log — no artist or title names.

What the test does not prove: integration replacing `catalog.playable` / `playable_pairs` (lead); live extensions.
"""

from __future__ import annotations

import asyncio
import json
import logging
from collections.abc import Callable
from typing import Any

import httpx
import pytest

from app.playable_from_extensions import Playable

A = "http://ext-a.test"
B = "http://ext-b.test"


class Ext:
    """Test extension: what it "has", what is declared and how to respond; tracks batches."""

    def __init__(
        self,
        have: set[tuple[str, str]] | None = None,
        *,
        features: tuple[str, ...] = ("catalog", "has"),
    ) -> None:
        self.have = have or set()
        self.features = list(features)
        self.status = 200
        self.down = False
        self.slow = 0.0
        self.mangle: Callable[[list[bool]], Any] | None = None
        self.batches: list[list[tuple[str, str]]] = []
        self.infos = 0

    async def answer(self, request: httpx.Request) -> httpx.Response:
        if self.down:
            raise httpx.ConnectError("refused", request=request)
        if request.url.path == "/v1/info":
            self.infos += 1
            return httpx.Response(
                200, json={"name": "ext", "version": "1", "features": self.features}
            )
        assert (request.method, request.url.path) == ("POST", "/v1/has")
        pairs = [
            (p["artist"], p["title"]) for p in json.loads(request.content)["pairs"]
        ]
        self.batches.append(pairs)
        if self.slow:
            await asyncio.sleep(self.slow)
        if self.status != 200:
            return httpx.Response(self.status, json={"error": "unavailable"})
        hits = [pair in self.have for pair in pairs]
        body = self.mangle(hits) if self.mangle else {"hits": hits}
        return httpx.Response(200, json=body)


def make(exts: dict[str, Ext], **kwargs: Any) -> tuple[Playable, httpx.AsyncClient]:
    async def route(request: httpx.Request) -> httpx.Response:
        return await exts[f"{request.url.scheme}://{request.url.host}"].answer(request)

    client = httpx.AsyncClient(transport=httpx.MockTransport(route))
    return Playable({name: name for name in exts}, client=client, **kwargs), client


def ask(
    exts: dict[str, Ext], pairs: list[tuple[str, str]], **kwargs: Any
) -> list[bool]:
    async def go() -> list[bool]:
        playable, client = make(exts, **kwargs)
        async with client:
            return await playable.pairs(pairs)

    return asyncio.run(go())


SANDMAN = ("Metallica", "Enter Sandman")
DUALITY = ("Slipknot", "Duality")
NOTHING = ("Nobody", "No Song")


def test_each_pair_answered_in_order() -> None:
    a = Ext({SANDMAN})
    assert ask({A: a}, [NOTHING, SANDMAN, DUALITY]) == [False, True, False]


def test_one_extension_with_it_is_enough() -> None:
    a = Ext({SANDMAN})
    b = Ext({DUALITY})
    assert ask({A: a, B: b}, [SANDMAN, DUALITY, NOTHING]) == [True, True, False]


def test_playable_for_one_artist() -> None:
    a = Ext({SANDMAN, ("Metallica", "One")})

    async def go() -> list[bool]:
        playable, client = make({A: a})
        async with client:
            return await playable.playable(
                "Metallica", ["One", "Enter Sandman", "Fuel"]
            )

    assert asyncio.run(go()) == [True, True, False]
    assert a.batches == [
        [("Metallica", "One"), ("Metallica", "Enter Sandman"), ("Metallica", "Fuel")]
    ]


def test_batches_are_at_most_fifty() -> None:
    a = Ext({("Artist", "Song 0"), ("Artist", "Song 120")})
    pairs = [("Artist", f"Song {i}") for i in range(121)]
    answer = ask({A: a}, pairs)
    assert answer == [i in (0, 120) for i in range(121)]
    assert [len(b) for b in a.batches] == [50, 50, 21]
    assert [p for b in a.batches for p in b] == pairs


def test_empty_names_are_false_without_asking() -> None:
    a = Ext({SANDMAN})
    assert ask({A: a}, [("", "Song"), ("Artist", "  "), SANDMAN]) == [
        False,
        False,
        True,
    ]
    assert a.batches == [[SANDMAN]]
    b = Ext({SANDMAN})
    assert ask({A: b}, [("", "Song")]) == [False]
    assert b.batches == []


def test_no_pairs_no_requests() -> None:
    a = Ext({SANDMAN})
    assert ask({A: a}, []) == []
    assert a.batches == []


def test_only_extensions_with_has_are_asked() -> None:
    a = Ext({SANDMAN})
    b = Ext({DUALITY}, features=("catalog", "pins"))
    assert ask({A: a, B: b}, [SANDMAN, DUALITY]) == [True, False]
    assert b.batches == []


def test_nobody_to_ask_means_nothing_plays() -> None:
    b = Ext({DUALITY}, features=("pins",))
    assert ask({B: b}, [DUALITY]) == [False]
    assert ask({}, [DUALITY]) == [False]


def test_features_are_asked_once() -> None:
    a = Ext({SANDMAN})

    async def go() -> None:
        playable, client = make({A: a})
        async with client:
            for _ in range(3):
                assert await playable.pairs([SANDMAN]) == [True]

    asyncio.run(go())
    assert a.infos == 1
    assert len(a.batches) == 3


# --- extension did not respond: show as playable ----------------------------


@pytest.mark.parametrize("status", [503, 500, 400, 422])
def test_unanswered_shows_as_playable(status: int) -> None:
    a = Ext({SANDMAN})
    a.status = status
    assert ask({A: a}, [SANDMAN, NOTHING]) == [True, True]


def test_unanswered_does_not_override_a_clear_no_from_nobody() -> None:
    """One is silent, another said "no" — unknown, so show; "yes" from any — yes."""
    a = Ext({SANDMAN})
    b = Ext(set())
    b.status = 503
    assert ask({A: a, B: b}, [SANDMAN, NOTHING]) == [True, True]


def test_down_extension_shows_as_playable() -> None:
    a = Ext({SANDMAN})
    a.down = True
    assert ask({A: a}, [NOTHING]) == [True]


def test_slow_extension_is_cut_at_two_seconds_and_shows_as_playable() -> None:
    import time

    a = Ext(set())
    a.slow = 5.0
    began = time.monotonic()
    assert ask({A: a}, [NOTHING]) == [True]
    assert time.monotonic() - began < 3.0


@pytest.mark.parametrize(
    "mangle",
    [
        lambda hits: {"hits": hits[:-1]},
        lambda hits: {"hits": hits + [True]},
        lambda hits: {"hits": ["yes" for _ in hits]},
        lambda hits: {"hits": [1 for _ in hits]},
        lambda hits: {"found": hits},
        lambda hits: hits,
    ],
)
def test_answer_not_in_shape_shows_as_playable(
    mangle: Callable[[list[bool]], Any],
) -> None:
    a = Ext(set())
    a.mangle = mangle
    assert ask({A: a}, [NOTHING, DUALITY]) == [True, True]


def test_one_bad_batch_does_not_spoil_the_others() -> None:
    a = Ext({("Artist", "Song 0")})
    calls = {"n": 0}

    def second_broken(hits: list[bool]) -> Any:
        calls["n"] += 1
        return {"hits": hits} if calls["n"] != 2 else {"oops": True}

    a.mangle = second_broken
    pairs = [("Artist", f"Song {i}") for i in range(120)]
    answer = ask({A: a}, pairs)
    assert answer[:50] == [i == 0 for i in range(50)]
    assert answer[50:100] == [True] * 50
    assert answer[100:] == [False] * 20


def test_log_has_no_names(caplog: pytest.LogCaptureFixture) -> None:
    caplog.set_level(logging.DEBUG)
    a = Ext({SANDMAN})
    b = Ext(set())
    b.status = 503
    ask({A: a, B: b}, [SANDMAN, DUALITY])
    text = "\n".join(r.getMessage() for r in caplog.records)
    for word in ("Metallica", "Sandman", "Slipknot", "Duality"):
        assert word not in text
