"""FT-685: library walk summary — numbers and line numbers, without names."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest
from not_in_slice import skip_module

skip_module("scripts/library_walk_summary.py")

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "library_walk_summary.py"


def _load() -> ModuleType:
    spec = importlib.util.spec_from_file_location("library_walk_summary", SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    import sys

    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


lws = _load()


def row(
    kind: str, artist: str = "Secret Band", title: str = "Hidden Song", **more: Any
) -> str:
    return json.dumps(
        {"kind": kind, "artist": artist, "title": title, "where": "popular", **more},
        ensure_ascii=False,
    )


def write(path: Path, lines: list[str]) -> Path:
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


def test_kinds_are_the_walk_kinds() -> None:
    assert lws.KINDS == (
        "no_id",
        "no_id_playable",
        "no_duration",
        "album_silent",
        "no_cover",
        "track_silent",
        "error",
        "artist_no_top",
        "artist_no_bio",
        "artist_no_photo",
    )
    assert lws.EXAMPLES == 5


def test_empty_report() -> None:
    summary = lws.summarize([])
    assert (summary.rows, summary.broken, summary.kinds, summary.codes) == (
        0,
        0,
        {},
        {},
    )
    assert lws.render(summary) == "kind\trows\tartists\tshare\tlines\nrows 0 broken 0"


def test_counts_rows_artists_and_first_lines() -> None:
    lines = [
        row("no_id", "A"),
        row("no_id", "A"),
        "",
        row("no_id", "B"),
        row("no_duration", "A"),
        "   ",
        row("no_id", "C"),
        row("no_id", "D"),
        row("no_id", "E"),
        row("no_id", "F"),
    ]
    summary = lws.summarize(lines)
    assert (summary.rows, summary.broken) == (8, 0)
    assert summary.count("no_id") == 7
    assert summary.count("no_duration") == 1
    assert summary.count("error") == 0
    assert len(summary.kinds["no_id"].artists) == 6
    # Line numbers are actual file lines, empty lines count too; at most five.
    assert summary.kinds["no_id"].examples == [1, 2, 4, 7, 8]
    assert summary.kinds["no_duration"].examples == [5]


@pytest.mark.parametrize(
    "bad",
    [
        "{not json",
        "[1, 2]",
        '"text"',
        "null",
        "17",
        '{"artist": "A"}',
        '{"kind": "weird"}',
        '{"kind": 5}',
        '{"kind": null}',
    ],
)
def test_broken_line_is_counted_and_skipped(bad: str) -> None:
    summary = lws.summarize([row("no_id"), bad, row("no_cover")])
    assert (summary.rows, summary.broken) == (2, 1)
    assert summary.kinds["no_cover"].examples == [3]


def test_artist_that_is_not_a_name_is_not_counted() -> None:
    lines = [
        json.dumps({"kind": "no_id"}),
        json.dumps({"kind": "no_id", "artist": ""}),
        json.dumps({"kind": "no_id", "artist": 7}),
        json.dumps({"kind": "no_id", "artist": None}),
    ]
    summary = lws.summarize(lines)
    assert summary.count("no_id") == 4
    assert summary.kinds["no_id"].artists == set()


def test_error_codes_are_counted_only_for_errors() -> None:
    lines = [
        row("error", code=503),
        row("error", code=503),
        row("error", code=0),
        row("error"),
        row("error", code="500"),
        row("error", code=True),
        row("no_id", code=404),
    ]
    summary = lws.summarize(lines)
    assert summary.codes == {503: 2, 0: 1}
    assert summary.count("error") == 6


def test_table() -> None:
    lines = [
        row("track_silent", "A"),
        row("no_id", "A"),
        row("no_id", "B"),
        row("error", "C", code=503),
    ]
    text = lws.render(lws.summarize(lines), artists=40)
    assert text.split("\n") == [
        "kind\trows\tartists\tshare\tlines",
        "no_id\t2\t2\t5.0%\t2,3",
        "track_silent\t1\t1\t2.5%\t1",
        "error\t1\t1\t2.5%\t4",
        "rows 4 broken 0",
        "error codes 503:1",
    ]


@pytest.mark.parametrize("artists", [None, 0, -5])
def test_share_needs_a_real_total(artists: int | None) -> None:
    text = lws.render(lws.summarize([row("no_id")]), artists=artists)
    assert text.split("\n")[1] == "no_id\t1\t1\t-\t1"


def test_share_is_of_artists_not_rows() -> None:
    lines = [row("no_id", "A")] * 3
    assert (
        lws.render(lws.summarize(lines), artists=3).split("\n")[1]
        == "no_id\t3\t1\t33.3%\t1,2,3"
    )


def test_difference_with_previous_report() -> None:
    before = lws.summarize(
        [
            row("no_id", "A"),
            row("no_id", "B"),
            row("no_cover", "A"),
            row("album_silent", "A"),
        ]
    )
    now = lws.summarize(
        [
            row("no_id", "A"),
            row("album_silent", "A"),
            row("album_silent", "B"),
            row("error", "C"),
        ]
    )
    assert lws.render(now, artists=10, previous=before).split("\n") == [
        "kind\trows\tartists\tshare\tdelta\tlines",
        "no_id\t1\t1\t10.0%\t-1\t1",
        "album_silent\t2\t2\t20.0%\t+1\t2,3",
        "no_cover\t0\t0\t0.0%\t-1\t-",
        "error\t1\t1\t10.0%\t+1\t4",
        "rows 4 broken 0",
    ]


def test_same_reports_differ_by_zero() -> None:
    same = lws.summarize([row("no_id")])
    assert lws.render(same, previous=same).split("\n")[1] == "no_id\t1\t1\t-\t+0\t1"


def test_error_codes_are_sorted() -> None:
    lines = [
        row("error", code=503),
        row("error", code=0),
        row("error", code=404),
        row("error", code=0),
    ]
    assert (
        lws.render(lws.summarize(lines)).split("\n")[-1]
        == "error codes 0:2 404:1 503:1"
    )


def test_names_never_reach_the_summary(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    lines = [
        row(kind, "Тайная Группа", "Скрытая Песня", album="Hidden Album")
        for kind in lws.KINDS
    ]
    lines.append('{"kind": "odd", "artist": "Тайная Группа"}')
    lines.append("Тайная Группа not json")
    report = write(tmp_path / "walk.jsonl", lines)
    assert lws.main([str(report), "--artists", "10", "--previous", str(report)]) == 0
    out = capsys.readouterr()
    for secret in ("Тайная", "Группа", "Скрытая", "Hidden", "popular", str(tmp_path)):
        assert secret not in out.out + out.err
    assert f"rows {len(lws.KINDS)} broken 2" in out.out
    assert "no_id\t1\t1\t10.0%\t+0\t1" in out.out


def test_reads_lazily() -> None:
    # A million lines without in-memory list: summary takes lines one by one.
    def lines() -> Any:
        for index in range(200_000):
            yield row("no_id", f"A{index % 50}")

    summary = lws.summarize(lines())
    assert summary.count("no_id") == 200_000
    assert len(summary.kinds["no_id"].artists) == 50
    assert summary.kinds["no_id"].examples == [1, 2, 3, 4, 5]


def test_exit_codes(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    report = write(tmp_path / "walk.jsonl", [row("error", code=0)] * 3 + [row("no_id")])
    assert lws.main([str(report)]) == 0
    assert lws.main([str(report), "--max-errors", "3"]) == 0
    assert lws.main([str(report), "--max-errors", "2"]) == 1
    assert lws.main([str(report), "--max-errors", "0"]) == 1
    capsys.readouterr()
    assert lws.main([str(tmp_path / "missing.jsonl")]) == 2
    out = capsys.readouterr()
    assert out.out == ""
    assert "missing" not in out.err and str(tmp_path) not in out.err
    assert lws.main([str(report), "--previous", str(tmp_path / "missing.jsonl")]) == 2


def test_table_is_printed_even_when_errors_are_over_the_limit(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    report = write(tmp_path / "walk.jsonl", [row("error", code=502)])
    assert lws.main([str(report), "--max-errors", "0"]) == 1
    assert "error\t1\t1\t-\t1" in capsys.readouterr().out


def test_undecodable_bytes_do_not_stop_the_summary(tmp_path: Path) -> None:
    report = tmp_path / "walk.jsonl"
    report.write_bytes(
        row("no_id").encode()
        + b"\n\xff\xfe broken\n"
        + row("no_cover").encode()
        + b"\n"
    )
    assert lws.main([str(report)]) == 0


def test_standard_library_only() -> None:
    source = SCRIPT.read_text(encoding="utf-8")
    for word in (
        "import requests",
        "import httpx",
        "import asyncpg",
        "from app",
        "urllib",
    ):
        assert word not in source
