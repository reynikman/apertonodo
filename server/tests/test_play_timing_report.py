"""FT-788 (И1в): "where time is lost" report from `play_timing` metrics table (FT-786).

Owner 08.10: measurement first. Report answers four questions that dictate next cards
about sources: whether we wait for extension search, file preparation, or transit to phone,
and how many Plays end in silence. Computed by `summary(rows)` — pure function over table rows;
`render` formats it. The script makes a single `SELECT` to the database and writes nothing.

What tests do not prove: that numbers in production are accurate (provided by week of listening)
and that database query is fast on large datasets (30 days is ~9k rows, index on `at` is in FT-786).
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any
from not_in_slice import needs

pytestmark = needs("scripts/play_report.py")

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "play_report.py"


def _module() -> Any:
    spec = importlib.util.spec_from_file_location("play_report", SCRIPT)
    assert spec and spec.loader, "missing scripts/play_report.py"
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _row(outcome: str = "played", *, source: str | None = "bt", prepared: bool = False,
         find: int | None = 100, prepare: int | None = 1100, token: int | None = 1110,
         first_byte: int | None = 1500, first_256k: int | None = 2500) -> dict[str, Any]:
    return {
        "track_id": "t", "source": source, "prepared": prepared, "outcome": outcome,
        "find_ms": find, "prepare_ms": prepare, "token_ms": token,
        "first_byte_ms": first_byte, "first_256k_ms": first_256k,
    }


def test_percentile_is_nearest_rank() -> None:
    percentile = _module().percentile
    assert percentile([], 50) is None
    assert percentile([7], 90) == 7
    assert percentile([4, 1, 3, 2], 50) == 2, "even count of values — lower of two medians, no fractions"
    assert percentile(list(range(1, 11)), 90) == 9
    assert percentile(list(range(1, 101)), 90) == 90


def test_summary_counts_outcomes_and_silence() -> None:
    rows = (
        [_row() for _ in range(6)]
        + [_row("no_source", source=None, prepare=None, first_byte=None, first_256k=None)] * 2
        + [_row("stalled", first_256k=None)]
        + [_row("not_ready", prepare=None, first_byte=None, first_256k=None)]
        + [_row("waiting", prepared=True, first_byte=None, first_256k=None)] * 5
    )
    got = _module().summary(rows)
    assert got["total"] == 15 and got["prepared"] == 5
    assert got["outcomes"] == {"played": 6, "waiting": 5, "no_source": 2, "stalled": 1, "not_ready": 1}
    assert list(got["outcomes"]) == ["played", "waiting", "no_source", "stalled", "not_ready"], "descending"
    # Silence is counted among Plays that finished with an outcome: "waiting" (advance preparation) — neither silence nor sound.
    assert got["silent_share"] == 0.4


def test_stages_are_durations_not_marks() -> None:
    rows = [
        _row(find=100, prepare=1100, token=1110, first_byte=1500, first_256k=2500),
        _row(find=300, prepare=5300, token=5310, first_byte=5400, first_256k=5600),
        _row(find=200, prepare=2200, token=2210, first_byte=2900, first_256k=None),
        # Prepared in advance: user pressed Play a minute later — transit to phone cannot be measured on it.
        _row(prepared=True, find=50, prepare=950, token=960, first_byte=61000, first_256k=62000),
    ]
    stages = _module().summary(rows)["stages"]
    assert stages["find"] == {"n": 4, "median": 100, "p90": 300}
    assert stages["prepare"] == {"n": 4, "median": 1000, "p90": 5000}
    assert stages["to_phone"] == {"n": 3, "median": 390, "p90": 690}, "first_byte − token, excluding prepared"
    assert stages["first_256k"] == {"n": 2, "median": 200, "p90": 1000}, "first_256k − first_byte, excluding prepared"
    assert stages["to_first_byte"] == {"n": 3, "median": 2900, "p90": 5400}, "entire user wait"
    assert _module().summary(rows)["slowest"] == "prepare"


def test_slowest_is_named_among_the_three_waits() -> None:
    summary = _module().summary
    assert summary([_row(find=4000, prepare=4100, token=4110, first_byte=4200)])["slowest"] == "find"
    assert summary([_row(find=10, prepare=20, token=30, first_byte=9000)])["slowest"] == "to_phone"
    assert summary([])["slowest"] is None
    assert summary([_row("no_source", source=None, find=None, prepare=None, first_byte=None)])["slowest"] is None


def test_sources_are_compared() -> None:
    rows = [
        _row(source="bt", first_byte=1000), _row(source="bt", first_byte=3000), _row(source="bt", first_byte=2000),
        _row("stalled", source="bt", first_256k=None),
        _row(source="folder", first_byte=200),
        _row("no_source", source=None, prepare=None, first_byte=None, first_256k=None),
    ]
    sources = _module().summary(rows)["sources"]
    assert sources == {
        "bt": {"total": 4, "played": 3, "median_first_byte": 2000},
        "folder": {"total": 1, "played": 1, "median_first_byte": 200},
    }, "Plays without extension are not compared; median across played ones"


def test_empty_week_is_said_plainly() -> None:
    module = _module()
    text = module.render(module.summary([]), days=7)
    assert "for 7 days" in text and "no measurements" in text.casefold()


def test_render_is_russian_and_carries_the_numbers() -> None:
    module = _module()
    rows = [_row() for _ in range(3)] + [_row("no_source", source=None, prepare=None, first_byte=None, first_256k=None)]
    text = module.render(module.summary(rows), days=7)
    for word in ("for 7 days", "Total Play: 4", "Played", "Not found", "Search", "Preparation", "To phone",
                 "median", "90 %", "bt", "Waiting most for"):
        assert word in text, f"report is missing '{word}':\n{text}"
    assert "25 %" in text, "silence share — 1 of 4"
    for slug in ("no_source", "to_phone", "first_256k", "silent_share", "None"):
        assert slug not in text, f"internal keyword {slug} in user report"
    assert not re.search(r"\bt\b", text), "no song IDs in report"


def test_cli_without_database_refuses_and_writes_nothing() -> None:
    env = {key: value for key, value in os.environ.items() if key != "DATABASE_URL"}
    done = subprocess.run([sys.executable, str(SCRIPT), "--days", "7"], env=env, capture_output=True, text=True)
    assert done.returncode == 2, done
    assert "DATABASE_URL" in done.stderr
    source = SCRIPT.read_text(encoding="utf-8")
    for word in ("INSERT", "UPDATE", "DELETE", "DROP", "ALTER", "TRUNCATE"):
        assert not re.search(rf"\b{word}\b", source), f"report only reads, but script contains {word}"
    assert "play_failures" not in source and "user_id" not in source, "report does not touch personal table"


def test_cli_json_from_database(postgres_url: str) -> None:
    """With database: `--json` prints same summary. Table is created by FT-786 migration — test skipped without it."""
    import asyncio

    import asyncpg
    import pytest

    from app.migrate import apply

    async def seed() -> bool:
        await apply(postgres_url)
        conn = await asyncpg.connect(postgres_url)
        try:
            if not await conn.fetchval("SELECT to_regclass('play_timing')"):
                return False
            await conn.execute(
                "INSERT INTO play_timing (track_id, source, prepared, find_ms, prepare_ms, token_ms, outcome) "
                "VALUES ('ft788', 'ft788ext', false, 1, 2, 3, 'waiting')"
            )
            return True
        finally:
            await conn.close()

    if not asyncio.run(seed()):
        pytest.skip("no play_timing table (FT-786 not yet merged into this branch)")
    done = subprocess.run(
        [sys.executable, str(SCRIPT), "--days", "1", "--json"],
        env={**os.environ, "DATABASE_URL": postgres_url}, capture_output=True, text=True,
    )
    assert done.returncode == 0, done.stderr
    got = json.loads(done.stdout)
    assert got["total"] >= 1 and "ft788ext" in got["sources"]
