"""Nightly check names what timed out (FT-467, Р-A39; night 01.10).

Night 01.10 logged `[http] /v1/artist: timeout` — one failure out of 128 artists,
and unknown which one: had to reopen all 128 pages. Disconnection must
name the artist, album or query. A page that timed out, but responded on
the second attempt, is "cold": this is also a failure, but a different one, and albums of
such artist are still checked.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path
from typing import Any
from not_in_slice import needs

pytestmark = needs("scripts/nightly_check.py")

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "nightly_check.py"

Result = tuple[Any | None, int | None, str | None, float]
TIMEOUT: Result = (None, None, "timeout", 20.0)
NETWORK: Result = (None, None, "network error", 0.1)

ARTIST: Result = (
    {
        "artist": {"id": "id-beta", "name": "Beta", "aliases": []},
        "albums": [{"id": "beta-al1", "title": "Beta Album 1"}],
    },
    200,
    None,
    0.1,
)
ALBUM: Result = (
    {"tracks": [{"id": "t1", "title": "Beta Song", "duration_ms": 200000}]},
    200,
    None,
    0.1,
)
SEARCH: Result = ({"artists": [{"name": "Beta"}], "tracks": []}, 200, None, 0.1)


def _module() -> Any:
    spec = importlib.util.spec_from_file_location("nightly_check_under_test", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _night(answers: dict[str, list[Result]]) -> tuple[list[str], list[str]]:
    """Single check of artist Beta; answers by path prefix, the last one repeats."""
    check = _module().NightlyCheck("http://127.0.0.1:9", "unused")
    asked: list[str] = []

    def get(path: str, params: dict[str, str] | None = None) -> Result:
        asked.append(path)
        for prefix, queue in answers.items():
            if path.startswith(prefix):
                return queue.pop(0) if len(queue) > 1 else queue[0]
        raise AssertionError(f"unexpected request {path}")

    check.get = get  # type: ignore[method-assign]
    check.check_artist("Beta", "2026-10-01", 1.5)
    return check.failures, asked


def _healthy() -> dict[str, list[Result]]:
    return {"/v1/artist": [ARTIST], "/v1/albums/": [ALBUM], "/v1/search": [SEARCH]}


def test_healthy_artist_has_no_failures() -> None:
    failures, _ = _night(_healthy())
    assert failures == []


def test_dead_artist_page_names_the_artist() -> None:
    failures, asked = _night({**_healthy(), "/v1/artist": [TIMEOUT]})
    assert "FAIL [artist] Beta: timeout" in failures, failures
    assert not any("[http]" in line for line in failures), failures
    assert asked.count("/v1/artist") == 2, "page disconnect is retried once"


def test_cold_artist_page_is_named_and_its_albums_are_still_checked() -> None:
    failures, asked = _night({**_healthy(), "/v1/artist": [TIMEOUT, ARTIST]})
    assert failures == ["FAIL [artist-cold] Beta"], failures
    assert any(path.startswith("/v1/albums/") for path in asked), asked


def test_cold_page_does_not_hide_a_broken_album() -> None:
    empty: Result = ({"tracks": []}, 200, None, 0.1)
    failures, _ = _night(
        {**_healthy(), "/v1/artist": [TIMEOUT, ARTIST], "/v1/albums/": [empty]}
    )
    assert "FAIL [artist-cold] Beta" in failures, failures
    assert "FAIL [album] Beta / Beta Album 1: no tracks" in failures, failures


def test_album_timeout_names_the_album() -> None:
    failures, _ = _night({**_healthy(), "/v1/albums/": [TIMEOUT]})
    assert failures == ["FAIL [album] Beta / Beta Album 1: timeout"], failures


def test_search_timeout_names_the_query() -> None:
    failures, _ = _night({**_healthy(), "/v1/search": [TIMEOUT]})
    assert failures == ["FAIL [search] Beta: timeout"], failures


def test_network_error_names_the_artist_too() -> None:
    failures, _ = _night({**_healthy(), "/v1/artist": [NETWORK]})
    assert "FAIL [artist] Beta: network error" in failures, failures
    assert not any("[http]" in line for line in failures), failures


def test_http_status_keeps_its_old_line() -> None:
    gone: Result = (None, 404, None, 0.1)
    failures, asked = _night({**_healthy(), "/v1/artist": [gone]})
    assert "FAIL [artist] Beta: HTTP 404" in failures, failures
    assert asked.count("/v1/artist") == 1, "server response is not retried"
