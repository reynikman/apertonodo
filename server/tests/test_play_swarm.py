"""FT-787 (И1б): core records what extension reported about swarm at ready time into timing row.

Four optional `play_timing` columns: `peers`, `speed_bps`, `have_pct`, `via`. The core does not know what they
mean for the source — they are numbers and one word out of three. Garbage from extension does not break Play: `NULL` in row.

What tests do not prove: that actual swarm numbers are accurate (tested in extension and week of measurements).
"""

from __future__ import annotations

from typing import Any

import pytest
from fake_extension import AUDIO, running_extension
from fastapi import FastAPI
from fastapi.responses import Response
from test_play_timing import SMALL, _client, _prepare, _settled, _track

AUDIO_BYTES = (AUDIO / "tone-440hz-4s.mp3").read_bytes()


def _extension(stats: Any, *, polls: int = 0) -> FastAPI:
    """Extension with single song; `stats` is returned in `ready` response as is. `polls` — how many times to return `preparing`."""
    app = FastAPI()
    left = [polls]

    @app.post("/v1/find")
    def find() -> dict[str, Any]:
        return {"items": [{"id": "one", "confidence": 0.9, "format": "mp3", "size": len(AUDIO_BYTES), "quality": "lossy"}]}

    @app.post("/v1/prepare")
    def prepare() -> dict[str, Any]:
        if left[0] > 0:
            left[0] -= 1
            return {"state": "preparing"}
        answer: dict[str, Any] = {"state": "ready", "format": "mp3", "size": len(AUDIO_BYTES)}
        if stats is not ...:
            answer["stats"] = stats
        return answer

    @app.get("/v1/files/{file_id}")
    def files(file_id: str) -> Response:
        return Response(AUDIO_BYTES, media_type="audio/mpeg")

    return app


def _played_row(url: str, stats: Any, *, polls: int = 0) -> dict[str, Any]:
    track = _track(SMALL, "Slipknot")
    _prepare(url, track)
    with running_extension(_extension(stats, polls=polls)) as ext, _client(url, track, {"swarm": ext}) as client:
        played = client.post("/v1/playback", json={"track_id": track["id"]})
        assert played.status_code == 200, played.text
        assert "stats" not in played.text and "peers" not in played.text, "swarm metrics are not sent to phone"
        assert client.get(f"/v1/stream/{played.json()['token']}").content == AUDIO_BYTES
        return _settled(url, track, "played")


def test_swarm_of_the_ready_answer_lands_in_the_row(postgres_url: str) -> None:
    row = _played_row(postgres_url, {"peers": 7, "speed_bps": 180000, "have_pct": 3, "via": "link"}, polls=1)
    assert (row["peers"], row["speed_bps"], row["have_pct"], row["via"]) == (7, 180000, 3, "link")
    assert row["source"] == "swarm"


def test_extension_without_stats_leaves_nulls(postgres_url: str) -> None:
    row = _played_row(postgres_url, ...)
    assert (row["peers"], row["speed_bps"], row["have_pct"], row["via"]) == (None, None, None, None)


@pytest.mark.parametrize(
    "stats",
    [
        "many",
        ["peers", 7],
        {"peers": "7", "speed_bps": -5, "have_pct": 250, "via": "wire"},
        {"peers": 7.5, "speed_bps": 10**12, "have_pct": None, "via": 3},
        {"peers": True, "via": "LINK", "name": "Slipknot - Duality.mp3"},
    ],
)
def test_garbage_from_an_extension_is_null_not_a_broken_play(postgres_url: str, stats: Any) -> None:
    row = _played_row(postgres_url, stats)
    assert (row["peers"], row["speed_bps"], row["have_pct"], row["via"]) == (None, None, None, None), row


def test_good_fields_survive_next_to_bad_ones(postgres_url: str) -> None:
    row = _played_row(postgres_url, {"peers": 0, "speed_bps": "fast", "have_pct": 100, "via": "cache"})
    assert (row["peers"], row["speed_bps"], row["have_pct"], row["via"]) == (0, None, 100, "cache")
