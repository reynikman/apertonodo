from __future__ import annotations

import re
from typing import Any

from app.canonical import normalize_text

CONFIDENCE_THRESHOLD = 0.75
BLACKLIST = ("live", "cover", "karaoke", "instrumental", "demo", "remix")
# Medium in the release title: «[7"] [24/96] … Stumblin' In», «[LP]», «Vinyl Rip».
_ANALOG_TITLE = re.compile(r"\[\s*(?:lp|(?:7|10|12)\s*(?:\"|''|”|inch))\s*\]|\bvinyl|\bвинил", re.IGNORECASE)
SEARCH_STOPWORDS_RAW = (
    "the",
    "a",
    "an",
    "song",
    "track",
    "mp3",
    "песня",
    "песню",
    "трек",
)
_FEAT = re.compile(r"\b(feat|ft|featuring)\b.*$", re.IGNORECASE)
_CYR_TO_LAT = str.maketrans(
    {
        "а": "a",
        "б": "b",
        "в": "v",
        "г": "g",
        "д": "d",
        "е": "e",
        "ё": "e",
        "ж": "zh",
        "з": "z",
        "и": "i",
        "й": "y",
        "к": "k",
        "л": "l",
        "м": "m",
        "н": "n",
        "о": "o",
        "п": "p",
        "р": "r",
        "с": "s",
        "т": "t",
        "у": "u",
        "ф": "f",
        "х": "h",
        "ц": "ts",
        "ч": "ch",
        "ш": "sh",
        "щ": "sch",
        "ъ": "",
        "ы": "y",
        "ь": "",
        "э": "e",
        "ю": "yu",
        "я": "ya",
    }
)


def fold_query(value: str) -> str:
    text = normalize_text(_FEAT.sub("", value))
    return text.translate(_CYR_TO_LAT)


SEARCH_STOPWORDS = frozenset(fold_query(word) for word in SEARCH_STOPWORDS_RAW)


def analog(candidate: dict[str, Any]) -> bool:
    """Digitization of a record or cassette: needle, crackle and hiss are audible in the recording.

    Valuable where there is no digital edition, but when choosing it comes after the digital one —
    otherwise "best quality" 24/96 would mean the surface noise of a 1978 vinyl.
    """
    return bool(candidate.get("analog")) or bool(_ANALOG_TITLE.search(str(candidate.get("title") or "")))
