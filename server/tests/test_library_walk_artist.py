"""H6-12a (FT-742): library walk sees empty artist pages.

Owner: some artists have no popular tracks, no bio, no photo. Walk
(`scripts/library_walk.py`, FT-584) with `artist_gaps=True` writes one line for
each such gap — sequential artist number to stdout, name only to file.
Without the flag, the report remains as before.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest

from tests.test_library_walk import KEY, PAGES, _module, _rows, server  # noqa: F401
from not_in_slice import needs

pytestmark = needs("scripts/library_walk.py")

GAPS = ("artist_no_top", "artist_no_bio", "artist_no_photo")


@pytest.fixture
def full_alpha(monkeypatch: pytest.MonkeyPatch) -> None:
    """Alpha Band has everything: photo, bio, popular tracks."""
    page = dict(PAGES["Alpha Band"])
    page["artist"] = {"id": "x1", "name": "Alpha Band", "photo": "/v1/photos/x1"}
    page["bio"] = "Alpha Band is a band."
    monkeypatch.setitem(PAGES, "Alpha Band", page)


def _gaps(path: Path) -> set[tuple[str, str]]:
    return {(r["kind"], r["artist"]) for r in _rows(path) if r["kind"] in GAPS}


def test_each_gap_is_one_row(server: str, tmp_path: Path, full_alpha: None) -> None:  # noqa: F811
    out = tmp_path / "walk.jsonl"
    summary = _module().walk(
        server, KEY, out, albums=False, delay=0.0, artist_gaps=True
    )
    assert _gaps(out) == {
        ("artist_no_top", "Amber"),
        ("artist_no_bio", "Amber"),
        ("artist_no_photo", "Amber"),
    }
    for kind in GAPS:
        assert summary[kind] == 1
    for r in _rows(out):
        if r["kind"] in GAPS:
            assert r["where"] == "artist"
            assert r["title"] == ""


def test_empty_bio_and_blank_photo_count_as_missing(
    server: str,  # noqa: F811
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    page = dict(PAGES["Alpha Band"])
    page["artist"] = {"id": "x1", "name": "Alpha Band", "photo": ""}
    page["bio"] = "   "
    monkeypatch.setitem(PAGES, "Alpha Band", page)
    out = tmp_path / "walk.jsonl"
    _module().walk(server, KEY, out, albums=False, delay=0.0, artist_gaps=True)
    assert ("artist_no_bio", "Alpha Band") in _gaps(out)
    assert ("artist_no_photo", "Alpha Band") in _gaps(out)
    assert ("artist_no_top", "Alpha Band") not in _gaps(out)


def test_without_flag_report_is_as_before(server: str, tmp_path: Path) -> None:  # noqa: F811
    out = tmp_path / "walk.jsonl"
    summary = _module().walk(server, KEY, out, albums=False, delay=0.0)
    assert _gaps(out) == set()
    assert not set(summary) & set(GAPS)


def test_broken_page_is_an_error_not_a_gap(server: str, tmp_path: Path) -> None:  # noqa: F811
    out = tmp_path / "walk.jsonl"
    _module().walk(server, KEY, out, albums=False, delay=0.0, artist_gaps=True)
    assert {k for k, a in _gaps(out) if a == "Beta"} == set()
    assert ("error", "Beta") in {(r["kind"], r["artist"]) for r in _rows(out)}


def test_cli_flag_reaches_walk(
    server: str,  # noqa: F811
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    module = _module()
    monkeypatch.setenv("MUSIC_API_KEY", KEY)
    out = tmp_path / "walk.jsonl"
    code = module.main(
        [
            "--base",
            server,
            "--out",
            str(out),
            "--no-albums",
            "--delay",
            "0",
            "--artist-gaps",
        ]
    )
    assert code == 0
    assert ("artist_no_top", "Amber") in _gaps(out)


def test_kinds_name_the_gaps() -> None:
    kinds: Any = _module().KINDS
    assert kinds[-3:] == GAPS
