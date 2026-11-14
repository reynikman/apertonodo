from __future__ import annotations

import math
from typing import Any

from app.quality import audio_format

PREFER_MODES: tuple[str, ...] = ("opus", "lossless")
MAX_GAIN_DB: float = 60.0

__all__ = ["MAX_GAIN_DB", "PREFER_MODES", "audio_block", "normalize_prefer"]


def normalize_prefer(raw: object) -> str | None:
    """Normalize quality preference mode from client request."""
    if not isinstance(raw, str):
        return None
    cleaned = raw.strip().lower()
    if cleaned in PREFER_MODES:
        return cleaned
    return None


def audio_block(name: object, *, gain_db: object = None) -> dict[str, Any] | None:
    """Construct audio block for Play response."""
    if not isinstance(name, str):
        return None
    fmt = audio_format(name)
    if fmt is None:
        return None
    block: dict[str, Any] = {"format": fmt}
    if (
        isinstance(gain_db, (int, float))
        and not isinstance(gain_db, bool)
        and abs(gain_db) <= MAX_GAIN_DB
        and math.isfinite(gain_db)
    ):
        rounded = round(float(gain_db), 2)
        block["gain_db"] = 0.0 if rounded == 0.0 else rounded
    return block
