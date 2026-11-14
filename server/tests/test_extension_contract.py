"""FT-587: core-extension contract and its verification (`contracts/extension-api.md`).

`scripts/extension_check.py` — how every P8 extension is accepted (FT-590 "folder", FT-592 torrents extension).
A green check proves nothing until it is shown to fail: a fake extension
(`fake_extension.py`) breaks one contract rule at a time, and each failure must yield exit 1 with the name
of the violated rule. An extension that does not respond at all yields exit 2, not 1: an unstarted server is not a test failure.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest
from fake_extension import make_fake_extension, running_extension

ROOT = Path(__file__).resolve().parents[2]
CHECK = ROOT / "scripts" / "extension_check.py"


def _check(url: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(CHECK), "--url", url, "--artist", "Slipknot", "--title", "Duality"],
        capture_output=True,
        text=True,
        timeout=120,
    )


def test_honest_extension_passes() -> None:
    with running_extension(make_fake_extension()) as url:
        result = _check(url)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "RED" not in result.stdout


@pytest.mark.parametrize(
    ("broken", "rule"),
    [
        ("no_range", "files: Range 0-1023"),
        ("unknown_is_found", "find: non-existent track"),
        ("unsorted", "find: best first"),
        ("failed_ignored", "failed: after complaint"),
        ("bad_id", "find: own track found"),
        ("wrong_bytes", "files: file start"),
        ("bad_genre", "catalog: genre from contracts/genres.txt"),
        ("has_says_yes", "has: non-existent pair — false"),
        ("has_short", "has: answer for each pair"),
        ("has_no_limit", "has: more than 50 pairs — rejection"),
        ("has_misses_own", "has: own pair — true"),
        ("has_list", "has: answer for each pair"),
        ("has_sorted", "has: answer for each pair"),
        ("genre_case", "catalog: genre from contracts/genres.txt"),
    ],
)
def test_each_broken_rule_is_caught(broken: str, rule: str) -> None:
    with running_extension(make_fake_extension(broken=broken)) as url:
        result = _check(url)
    assert result.returncode == 1, f"{broken}: exit {result.returncode}\n{result.stdout}{result.stderr}"
    red = [line for line in result.stdout.splitlines() if line.startswith("RED")]
    assert any(rule in line for line in red), f"{broken}: «{rule}» not reported\n{result.stdout}"


def test_unreachable_extension_is_setup_not_breakage() -> None:
    result = _check("http://127.0.0.1:9")
    assert result.returncode == 2, result.stdout + result.stderr


def test_contract_has_no_source_words() -> None:
    text = (ROOT / "contracts" / "extension-api.md").read_text(encoding="utf-8").casefold()
    for word in ("magnet", "torrent", "tracker", "info_hash", "infohash"):
        assert word not in text, f"source word «{word}» found in core contract"
