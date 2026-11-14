"""Nightly check does not raise false alarms on "&" and "and" (P3.5, phase 9; night 30.09).

"Dan Hicks & His Hot Licks" from genre and "Dan Hicks and His Hot Licks" in search —
same artist, but the check reported `[search-miss]`. Fixed in the check itself,
not in search. It does not become any softer: another artist's name is still a miss.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path
from typing import Any

import pytest
from not_in_slice import needs

pytestmark = needs("scripts/nightly_check.py")

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "nightly_check.py"


def _module() -> Any:
    spec = importlib.util.spec_from_file_location("nightly_check_under_test", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _search(asked: str, answered: list[str]) -> list[str]:
    check = _module().NightlyCheck("http://127.0.0.1:9", "unused")
    check.get = lambda path, params=None: (
        {"artists": [{"name": name} for name in answered]},
        200,
        None,
        0.01,
    )  # type: ignore[method-assign]
    check.check_search(asked, search_limit_s=1.5)
    return check.failures


@pytest.mark.parametrize(
    ("asked", "answered"),
    [
        ("Dan Hicks & His Hot Licks", ["Dan Hicks and His Hot Licks"]),
        ("Dan Hicks and His Hot Licks", ["Dan Hicks & His Hot Licks"]),
        ("Simon & Garfunkel", ["Paul Simon", "Simon and Garfunkel"]),
        ("Metallica", ["Metallica"]),
    ],
)
def test_same_artist_is_found(asked: str, answered: list[str]) -> None:
    assert _search(asked, answered) == []


@pytest.mark.parametrize(
    ("asked", "answered"),
    [
        ("Rick Scott", ["Rick Ross", "Jill Scott"]),
        ("Metallica", ["Metallica & San Francisco Symphony"]),
        ("Simon & Garfunkel", ["Simon Garfunkel"]),
        ("Dan Hicks & His Hot Licks", ["Dan Hicks"]),
    ],
)
def test_another_artist_is_still_a_miss(asked: str, answered: list[str]) -> None:
    assert _search(asked, answered) == [f"FAIL [search-miss] {asked}"]


@pytest.mark.parametrize(
    "title",
    [
        "Klavier Sonaten",
        "Klaviersonaten",
        "Piano Concertos Nos. 20 & 23",
        "Piano Concertos nos. 20, 23",
        "St. Anger",
        "ST. ANGER",
        "Ёлка",
        "AC/DC Live",
        "Straße_Mix",
    ],
)
def test_album_key_folds_like_the_server(title: str) -> None:
    """Night 26.10: Mozart's "Klavier Sonaten" and "Klaviersonaten" are two recordings the
    server rightly shows apart; the check called them one album. Same key as the server."""
    from app.names import norm

    assert _module()._album_key(title) == norm(title)


def test_album_key_keeps_distinct_recordings_apart() -> None:
    key = _module()._album_key
    assert key("Klavier Sonaten") != key("Klaviersonaten")
    assert key("Piano Concertos Nos. 20 & 23") != key("Piano Concertos nos. 20, 23")
    assert key("St. Anger") == key("ST. ANGER")
