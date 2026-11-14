"""FT-904 (R-A63): online MusicBrainz is never switched on silently.

Without a local MusicBrainz copy the server searches the online one and says so once
at startup. The line has no query and no address.
"""

from __future__ import annotations

import logging

import pytest

from app.main import create_app

LINE = "catalog: no local MusicBrainz copy, using online MusicBrainz"


@pytest.fixture(autouse=True)
def _key(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("MUSIC_API_KEY", "k" * 40)


def lines(caplog: pytest.LogCaptureFixture) -> list[str]:
    return [r.getMessage() for r in caplog.records if r.getMessage() == LINE]


def test_online_catalog_without_local_copy_is_announced_once(
    monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    monkeypatch.setenv("MUSICBRAINZ_ENABLED", "1")
    monkeypatch.delenv("MBCOPY_ENABLED", raising=False)
    with caplog.at_level(logging.INFO, logger="apertonodo"):
        create_app()
    assert lines(caplog) == [LINE]


def test_no_notice_when_online_catalog_is_off(
    monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    monkeypatch.delenv("MUSICBRAINZ_ENABLED", raising=False)
    with caplog.at_level(logging.INFO, logger="apertonodo"):
        create_app()
    assert lines(caplog) == []
