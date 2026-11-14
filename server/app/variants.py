from __future__ import annotations

import json
import math
import os
import hashlib
import re
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any, BinaryIO

_LOSSLESS = {"flac", "alac", "wavpack", "ape", "tta"}


class VariantFailed(Exception):
    """Safe log reason; the bounded, private stderr tail is never logged."""

    def __init__(self, reason: str, *, stderr: bytes = b"") -> None:
        super().__init__(reason)
        self.stderr = stderr[-2048:]


def _probe(path: Path, timeout_s: float = 30.0) -> dict[str, Any]:
    try:
        result = subprocess.run(
            [
                "ffprobe", "-v", "error", "-protocol_whitelist", "file,pipe",
                "-select_streams", "a:0", "-show_entries",
                "stream=codec_name:format=duration", "-of", "json", str(path.resolve()),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=True,
            timeout=timeout_s,
        )
        data = json.loads(result.stdout)
        if not isinstance(data, dict):
            raise ValueError
        return data
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        raise VariantFailed("ffprobe failed") from None


def needs_opus(path: Path) -> bool:
    try:
        codec = _probe(path)["streams"][0]["codec_name"]
        return isinstance(codec, str) and (codec in _LOSSLESS or codec.startswith("pcm_"))
    except (VariantFailed, KeyError, IndexError, TypeError):
        return False


def _duration(path: Path, timeout_s: float) -> float:
    try:
        seconds = float(_probe(path, timeout_s)["format"]["duration"])
    except (KeyError, TypeError, ValueError):
        raise VariantFailed("duration unavailable") from None
    if not math.isfinite(seconds) or seconds <= 0:
        raise VariantFailed("duration unavailable")
    return seconds


def _stderr_tail(stderr: BinaryIO) -> bytes:
    stderr.seek(max(0, stderr.tell() - 2048))
    return stderr.read(2048)


def make_opus(source: Path, target: Path, *, timeout_s: float = 600.0) -> None:
    part = target.with_suffix(target.suffix + ".part")
    deadline = time.monotonic() + timeout_s

    def remaining() -> float:
        seconds = deadline - time.monotonic()
        if not math.isfinite(seconds) or seconds <= 0:
            raise VariantFailed("conversion timed out")
        return seconds

    try:
        source = source.resolve(strict=True)
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.is_symlink() or part.is_symlink():
            raise VariantFailed("unsafe output file")
        duration = _duration(source, min(30.0, remaining()))
        with tempfile.TemporaryFile() as stderr:
            try:
                result = subprocess.run(
                    [
                        "ffmpeg", "-v", "error", "-y", "-nostdin",
                        "-protocol_whitelist", "file,pipe", "-threads", "1",
                        "-i", str(source), "-map", "0:a:0", "-vn",
                        "-map_metadata", "-1", "-map_chapters", "-1",
                        "-c:a", "libopus", "-b:a", "160k", "-threads", "1",
                        "-f", "ogg", str(part.resolve()),
                    ],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=stderr,
                    timeout=remaining(),
                )
            except subprocess.TimeoutExpired:
                raise VariantFailed("ffmpeg timed out", stderr=_stderr_tail(stderr)) from None
            if result.returncode:
                raise VariantFailed(
                    f"ffmpeg exited with code {result.returncode}", stderr=_stderr_tail(stderr)
                )
        if abs(_duration(part, min(30.0, remaining())) - duration) > 0.1:
            raise VariantFailed("duration mismatch")
        remaining()
        os.replace(part, target)
    except OSError:
        raise VariantFailed("file operation failed") from None
    finally:
        try:
            part.unlink(missing_ok=True)
        except OSError:
            raise VariantFailed("partial cleanup failed") from None


def asset_stem(root: Path, asset: str) -> Path:
    """Stem path for extension file: `<root>/ext/<name>/<sha256(file_id)[:32]>`."""
    name, sep, file_id = asset.partition(":")
    if not sep or not re.fullmatch(r"[a-z][a-z0-9-]{0,31}", name) or not file_id:
        raise VariantFailed("invalid variant identity")
    stem = root / "ext" / name / hashlib.sha256(file_id.encode()).hexdigest()[:32]
    if not stem.resolve().is_relative_to(root.resolve()):
        raise VariantFailed("variant path leaves storage")
    return stem


def asset_variant_path(root: Path, asset: str) -> Path:
    return asset_stem(root, asset).with_suffix(".opus")
