from __future__ import annotations

import re
from typing import Any

from app.matching import CONFIDENCE_THRESHOLD, analog

LOSSLESS_FILE_EXTENSIONS = frozenset({".flac", ".ape", ".wv", ".wav", ".tta"})
LOSSY_FILE_EXTENSIONS = frozenset({".mp3", ".ogg", ".opus", ".aac"})
AUDIO_FORMAT_EXTENSIONS = frozenset({"flac", "mp3", "opus", "ogg", "m4a", "aac", "wav"})

_LOSSLESS_WORDS = re.compile(r"\b(?:flac|alac|wavpack|lossless)\b", re.IGNORECASE)
_LOSSLESS_APE = re.compile(r"\bAPE\b")
_LOSSY_WORDS = re.compile(
    r"\b(?:mp3|aac|ogg|opus|vorbis|lossy|\d{2,3}\s*(?:kbps|kbits?))\b",
    re.IGNORECASE,
)


def lossless(candidate: dict[str, Any]) -> bool | None:
    """Determine whether a candidate is a lossless source.

    1. First check the file extension in candidate["file_path"] (last path component,
       case-insensitive): .flac .ape .wv .wav .tta -> True; .mp3 .ogg .opus .aac -> False;
       .m4a -> None (can be either).
    2. Otherwise — candidate title candidate["title"].
       Lossless indicators: full words flac, alac, wavpack, lossless in any case
       and APE in uppercase only.
       Lossy indicators: full words mp3, aac, ogg, opus, vorbis, lossy and 2-3 digit
       number preceding kbps or kbit.
       Only first present -> True; only second present -> False; conflict ("FLAC + MP3")
       or no indicators -> None.
    """
    if not isinstance(candidate, dict):
        return None

    raw_path = candidate.get("file_path")
    if isinstance(raw_path, str):
        cleaned_path = raw_path.strip().replace("\\", "/")
        if cleaned_path and not cleaned_path.endswith("/"):
            file_name = cleaned_path.rsplit("/", 1)[-1]
            dot_idx = file_name.rfind(".")
            if dot_idx >= 0:
                ext = file_name[dot_idx:].lower()
                if ext in LOSSLESS_FILE_EXTENSIONS:
                    return True
                if ext in LOSSY_FILE_EXTENSIONS:
                    return False
                if ext == ".m4a":
                    return None

    raw_title = candidate.get("title")
    if not isinstance(raw_title, str) or not raw_title.strip():
        return None

    has_lossless = bool(_LOSSLESS_WORDS.search(raw_title)) or bool(
        _LOSSLESS_APE.search(raw_title)
    )
    has_lossy = bool(_LOSSY_WORDS.search(raw_title))

    if has_lossless and not has_lossy:
        return True
    if has_lossy and not has_lossless:
        return False
    return None


def prefer_order(
    candidates: list[dict[str, Any]],
    prefer: str | None,
    *,
    threshold: float = CONFIDENCE_THRESHOLD,
) -> list[dict[str, Any]]:
    """Order candidates according to the chosen quality preference.

    Always returns a new list, does not mutate input, does not drop any candidates.
    If prefer is not "lossless" — preserves input order.
    When "lossless" — three sequential groups:
      1) confident (confidence >= threshold), lossless, and not vinyl rip;
      2) other confident;
      3) unconfident.
    Within each group, input order is strictly preserved.
    """
    if prefer != "lossless":
        return list(candidates)

    confident_lossless: list[dict[str, Any]] = []
    other_confident: list[dict[str, Any]] = []
    unsure: list[dict[str, Any]] = []

    for c in candidates:
        conf = float(c.get("confidence") or 0.0)
        if conf >= threshold:
            if lossless(c) is True and not analog(c):
                confident_lossless.append(c)
            else:
                other_confident.append(c)
        else:
            unsure.append(c)

    return confident_lossless + other_confident + unsure


def audio_format(name: str) -> str | None:
    """Format for badge by extension of actual filename.

    flac, mp3, opus, ogg, m4a, aac, wav; everything else, including empty string,
    release title, and One.flac.part — None.
    """
    if not isinstance(name, str):
        return None
    cleaned = name.strip().replace("\\", "/")
    if not cleaned or cleaned.endswith("/"):
        return None
    file_name = cleaned.rsplit("/", 1)[-1]
    dot_idx = file_name.rfind(".")
    if dot_idx < 0:
        return None
    ext = file_name[dot_idx + 1 :].lower()
    if ext in AUDIO_FORMAT_EXTENSIONS:
        return ext
    return None
