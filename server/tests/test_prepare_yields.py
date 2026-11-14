"""FT-570 (Р-A82 item 5): advance preparation never delays Play click.

05.10 daytime on prod in 20 minutes — around 100 preparations (`prepare: true`) per
dozen clicks: open playlist prepares three tracks (FT-563), playback queue prepares its own.
Each preparation takes the same path as Play: source lookup and waiting for file start
up to 50 s. Owner clicks during this time responded "Source not found".

Rule: at most two preparations run concurrently; extra ones respond
immediately and do not search. Play bypasses this queue.
"""

from __future__ import annotations

import json
import threading
import time
from pathlib import Path

from fake_extension import running_extension
from fakes import CountingExtension
from fastapi.testclient import TestClient

from app.main import create_app

ROOT = Path(__file__).resolve().parents[2]
CATALOG = json.loads((ROOT / "contracts" / "fixtures" / "catalog.json").read_text())["tracks"]
SLOW = {track["id"] for track in CATALOG[:4]}
SLOW_TITLES = {track["title"] for track in CATALOG[:4]}


def _until(done, seconds: float = 5.0) -> None:
    end = time.monotonic() + seconds
    while not done() and time.monotonic() < end:
        time.sleep(0.02)


def _app(url: str) -> TestClient:
    return TestClient(
        create_app(database_url=None, catalog=CATALOG, catalog_port=None, extensions={"count": url})
    )


def test_two_prepares_at_once_the_rest_answer_without_work() -> None:
    own = CountingExtension(slow=SLOW_TITLES)
    with running_extension(own.app()) as url, _app(url) as client:
        answered: dict[str, tuple[int, float]] = {}

        def prepare(track_id: str) -> None:
            began = time.monotonic()
            response = client.post("/v1/playback", json={"track_id": track_id, "prepare": True})
            answered[track_id] = (response.status_code, time.monotonic() - began)

        threads = [threading.Thread(target=prepare, args=(track_id,)) for track_id in SLOW]
        for thread in threads:
            thread.start()
        try:
            _until(lambda: len(own.asked) >= 2 and len(answered) >= 2)
            time.sleep(0.5)
            assert len(own.asked) == 2, f"{len(own.asked)} preparations search concurrently, expected two"
            assert len(answered) == 2, "excess preparations wait in queue instead of answering immediately"
            for code, took in answered.values():
                assert code == 409
                assert took < 2, f"excess preparation took {took:.1f} s"

            # Play during this time: immediate search, without queueing behind preparations.
            began = time.monotonic()
            response = client.post("/v1/playback", json={"track_id": CATALOG[10]["id"]})
            assert response.status_code == 409
            assert time.monotonic() - began < 3, "Play waited for preparations"
            assert CATALOG[10]["title"] in own.asked
        finally:
            own.gate.set()
            for thread in threads:
                thread.join(25)


def test_after_prepares_finish_the_next_one_works() -> None:
    # Guard: slot is released — otherwise preparation would be disabled forever.
    own = CountingExtension()
    with running_extension(own.app()) as url, _app(url) as client:
        for track in CATALOG[4:8]:
            response = client.post("/v1/playback", json={"track_id": track["id"], "prepare": True})
            assert response.status_code == 409
        assert own.asked == [track["title"] for track in CATALOG[4:8]]
