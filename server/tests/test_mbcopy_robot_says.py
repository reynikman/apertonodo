"""FT-612: MusicBrainz copy robot reports decisions and crash reasons.

Since 26.09 the robot wrote no lines to the log, and it was impossible to tell from the log whether: dump is absent,
not a Saturday dump, already loaded, or the loader crashed. The robot swallowed loader output
(`python -m app.mbcopy load`, `capture_output`), and even a failed load left only "exit 1". Now:
- every decision is a `mbcopy: …` line with dump date and reason;
- a failed loader yields a line with the last lines of its output (without database URL).

The robot here is real (`MbCopy`), network is mocked with `httpx.MockTransport`, loader is a real process that
fails on an unavailable database.
"""

from __future__ import annotations

import logging
from datetime import date
from typing import Any

import httpx
import pytest

from app.mbcopy import MbCopy

NOWHERE = "postgresql://music:secret-word@127.0.0.1:1/nowhere"


def _robot(latest: str, last: date | None, monkeypatch: pytest.MonkeyPatch) -> MbCopy:
    http = httpx.Client(
        transport=httpx.MockTransport(
            lambda request: httpx.Response(200, text=latest + "\n")
        )
    )
    robot = MbCopy(NOWHERE, http=http)

    async def last_date() -> date | None:
        return last

    monkeypatch.setattr(robot, "_last_date", last_date)
    return robot


def _lines(caplog: Any) -> list[str]:
    return [
        record.getMessage()
        for record in caplog.records
        if record.getMessage().startswith("mbcopy: ")
    ]


def test_not_a_saturday_dump_is_said(
    monkeypatch: pytest.MonkeyPatch, caplog: Any
) -> None:
    robot = _robot("20260930-002222", date(2026, 9, 26), monkeypatch)
    with caplog.at_level(logging.INFO, logger="apertonodo"):
        robot._run_safely()
    lines = _lines(caplog)
    assert len(lines) == 1, lines
    assert "2026-09-30" in lines[0] and "saturday" in lines[0].casefold(), lines


def test_already_loaded_is_said(monkeypatch: pytest.MonkeyPatch, caplog: Any) -> None:
    robot = _robot("20260926-001001", date(2026, 9, 26), monkeypatch)
    with caplog.at_level(logging.INFO, logger="apertonodo"):
        robot._run_safely()
    lines = _lines(caplog)
    assert len(lines) == 1, lines
    assert "2026-09-26" in lines[0] and "already" in lines[0].casefold(), lines


def test_failed_loader_says_why(monkeypatch: pytest.MonkeyPatch, caplog: Any) -> None:
    robot = _robot("20261003-001001", date(2026, 9, 26), monkeypatch)
    with caplog.at_level(logging.INFO, logger="apertonodo"):
        robot._run_safely()
    lines = _lines(caplog)
    text = "\n".join(lines)
    assert any("2026-10-03" in line and "load" in line.casefold() for line in lines), (
        lines
    )
    assert "exit" in text, lines
    # Loader failed connecting to database — that should be visible in the log, not just exit code.
    assert any(
        word in text for word in ("ConnectionRefused", "Connect", "connect", "OSError")
    ), lines
    assert "secret-word" not in caplog.text, "database URL with password leaked into log"
    assert robot.last_fail is not None, "pause for a day after failure, as before"


def test_loader_tail_is_short(monkeypatch: pytest.MonkeyPatch, caplog: Any) -> None:
    robot = _robot("20261003-001001", date(2026, 9, 26), monkeypatch)
    with caplog.at_level(logging.INFO, logger="apertonodo"):
        robot._run_safely()
    assert all(len(line) <= 600 for line in _lines(caplog)), (
        "loader output tail is not a huge wall of text"
    )
