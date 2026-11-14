"""Server compresses FLAC to Opus (FT-521, Р-A60).

Production, 02.10.2026: out of 524 played songs, 364 are FLAC, median 31 MiB. On
mobile network this is 31 MiB of traffic per song, an album is half a gigabyte. Opus 160
kbps is about 5 MiB. The owner decided: server compresses on its own, immediately after
the song played and its FLAC fully landed on disk (B8 "b"), and on "download".

Compressed copy is a ready file, not an ffmpeg on-the-fly stream: ready file
can seek and serve chunks (Range), stream cannot. Written to `.part` and
becomes visible only after duration verification, so a half
never looks ready. MP3 and other lossy formats are untouched — recompressing
only damages audio.

Compression itself is tested here; copy via `asset` is in `test_extension_asset.py`.
"""

from __future__ import annotations

import json
import subprocess
import time
import uuid
from pathlib import Path
from typing import Any

import pytest

from app.variants import VariantFailed, make_opus, needs_opus
from not_in_slice import needs

ROOT = Path(__file__).resolve().parents[2]
MB = 1_000_000

SONG = {
    "id": str(uuid.uuid4()),
    "title": "Disasterpiece",
    # Custom artist: database is shared with test_album_memory.py and test_storage.py.
    "artist": "Varianttest",
    "duration_ms": 1,
    "artwork_url": "",
}


def _ffmpeg(*args: str) -> None:
    subprocess.run(["ffmpeg", "-v", "error", "-y", *args], check=True, timeout=60)


def _probe(path: Path) -> dict[str, Any]:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)],
        check=True,
        capture_output=True,
        text=True,
        timeout=30,
    ).stdout
    return json.loads(out)


def _tone(path: Path, seconds: float = 3.0, *, source: str = "sine=frequency=440") -> Path:
    """Tone or noise with song tags — like release file. Format depends on extension."""
    path.parent.mkdir(parents=True, exist_ok=True)
    _ffmpeg(
        "-f", "lavfi", "-i", f"{source}:duration={seconds}",
        "-metadata", f"artist={SONG['artist']}",
        "-metadata", f"title={SONG['title']}",
        str(path),
    )
    return path


def _seconds(path: Path) -> float:
    return float(_probe(path)["format"]["duration"])


# ---------------------------------------------------------------- the file itself


def test_flac_becomes_opus_of_the_same_length(tmp_path: Path) -> None:
    source = _tone(tmp_path / "in.flac")
    target = tmp_path / "out" / "0.opus"

    make_opus(source, target)

    stream = _probe(target)["streams"][0]
    assert stream["codec_name"] == "opus", stream
    assert abs(_seconds(target) - _seconds(source)) <= 0.1
    assert [item.name for item in target.parent.iterdir()] == ["0.opus"], ".part remained"


def test_opus_is_160_kbit(tmp_path: Path) -> None:
    """Noise rather than tone: on silence and sine VBR drops far below target."""
    source = _tone(tmp_path / "noise.flac", 10.0, source="anoisesrc=color=pink")
    target = tmp_path / "noise.opus"

    make_opus(source, target)

    kbit = target.stat().st_size * 8 / 10.0 / 1000
    assert 120 <= kbit <= 210, f"{kbit:.0f} kbps instead of ~160"


def test_lossy_is_left_alone(tmp_path: Path) -> None:
    mp3 = tmp_path / "in.mp3"
    _ffmpeg("-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-b:a", "320k", str(mp3))

    assert needs_opus(mp3) is False
    assert needs_opus(_tone(tmp_path / "in.flac")) is True


def test_broken_flac_leaves_nothing(tmp_path: Path) -> None:
    """Truncated FLAC: ffmpeg finishes reading beginning and exits with 0 — duration check catches it."""
    whole = _tone(tmp_path / "whole.flac", 6.0)
    broken = tmp_path / "broken.flac"
    broken.write_bytes(whole.read_bytes()[: whole.stat().st_size // 3])
    target = tmp_path / "out" / "0.opus"

    with pytest.raises(VariantFailed):
        make_opus(broken, target)

    assert not target.exists()
    assert not list(tmp_path.rglob("*.part")), ".part remained"


def test_ffmpeg_that_takes_too_long_is_stopped(tmp_path: Path) -> None:
    source = _tone(tmp_path / "long.flac", 60.0)
    target = tmp_path / "out" / "0.opus"

    began = time.monotonic()
    with pytest.raises(VariantFailed):
        make_opus(source, target, timeout_s=0.05)

    assert time.monotonic() - began < 10
    assert not target.exists()
    assert not list(tmp_path.rglob("*.part")), ".part remained"


def _wait(predicate: Any, seconds: float = 20.0) -> bool:
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if predicate():
            return True
        time.sleep(0.1)
    return False


def _lines(caplog: Any) -> list[str]:
    return [record.getMessage() for record in caplog.records]


# ------------------------------------------------------------- production image


@needs(".gitlab-ci.yml")
def test_image_and_ci_have_ffmpeg() -> None:
    """Without ffmpeg in image server silently never compresses anything."""
    assert "ffmpeg" in (ROOT / "Dockerfile").read_text(), "ffmpeg is not installed in Dockerfile"
    ci = (ROOT / ".gitlab-ci.yml").read_text()
    backend = ci.split("\nbackend-tests:", 1)[1].split("\n\n", 1)[0]
    assert "ffmpeg" in backend
