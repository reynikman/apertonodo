"""Pressing Play fits within budget, even when each step hangs.

Previously worst case in code was ~210 seconds: source search and four
candidates 49s each. In front of the server stand Nginx Proxy Manager (60 s default
response timeout) and Cloudflare (100 s), so response was terminated by proxy, and phone
saw network error instead of honest "not found". Now when time is up — we don't start
the next candidate and respond with 409 ourselves.

What this doesn't prove: that budget is enough for live source to answer in time.
That is a network question, visible in log lines (`test_play_trace.py`).
"""

from __future__ import annotations

import time
from pathlib import Path

from fake_extension import running_extension
from fakes import CountingExtension
from fastapi.testclient import TestClient
from test_extension_asset import Disk, _tone

from app.main import create_app

TRACK = {
    "id": "5e1f0000-0000-4000-8000-000000000001",
    "title": "Disasterpiece",
    "artist": "Slipknot",
    "duration_ms": 1,
    "artwork_url": "",
}


def test_play_answers_before_the_proxies_when_the_source_hangs() -> None:
    """Question to source is limited by its timeout (`FIND_READ_S`), shorter than 55s budget."""
    hanging = CountingExtension(slow={TRACK["title"]})
    with running_extension(hanging.app()) as url:
        app = create_app(catalog=[TRACK], extensions={"hang": url})
        try:
            with TestClient(app) as client:
                started = time.monotonic()
                response = client.post("/v1/playback", json={"track_id": TRACK["id"]})
                elapsed = time.monotonic() - started
        finally:
            hanging.gate.set()

    assert response.status_code == 409, response.text
    assert response.json() == {"state": "unresolved"}
    assert elapsed < 15, f"Play answered in {elapsed:.1f} s"


def test_one_fast_source_still_plays_within_budget(tmp_path: Path) -> None:
    disk = Disk(_tone(tmp_path / "music" / "01.mp3", TRACK))
    with running_extension(disk.app()) as url:
        app = create_app(catalog=[TRACK], extensions={"disk": url}, playback_budget_s=3.0)
        with TestClient(app) as client:
            response = client.post("/v1/playback", json={"track_id": TRACK["id"]})

    assert response.status_code == 200, response.text


def test_default_budget_fits_under_the_proxies() -> None:
    """Nginx Proxy Manager terminates response after 60s by default, Cloudflare after 100s."""
    budget = create_app(catalog=[TRACK]).state.playback_budget_s
    assert 0 < budget <= 55, budget
