from __future__ import annotations

import re
import unicodedata
from typing import Any

_VERSION_PARENS = re.compile(
    r"\s*[\(\[][^\)\]]*?(remaster|deluxe|edition|version|anniversary)[^\)\]]*[\)\]]",
    re.IGNORECASE,
)
_NON_ALNUM = re.compile(r"[^\w\s]+", re.UNICODE)
_SPACES = re.compile(r"\s+")
_PENALTY_WORDS = ("remaster", "live", "deluxe", "remix", "cover", "karaoke")


def normalize_text(value: str) -> str:
    value = unicodedata.normalize("NFKC", value).casefold()
    value = _VERSION_PARENS.sub("", value)
    value = _NON_ALNUM.sub(" ", value)
    return _SPACES.sub(" ", value).strip()


def canonical_key(artist: str, title: str) -> str:
    return f"{normalize_text(artist)}|{normalize_text(title)}"


def canonical_key_sql(artist: str, title: str) -> str:
    """Return SQL matching canonical_key for trusted column expressions."""
    version_parens = r"\s*[\(\[][^\)\]]*?(?:remaster|deluxe|edition|version|anniversary)[^\)\]]*[\)\]]"

    def normalized(column: str) -> str:
        return f"""trim(regexp_replace(
            regexp_replace(
                    regexp_replace(lower(normalize({column}, NFKC)),
                        '{version_parens}', '', 'gi'),
                    '[^\\w\\s]+', ' ', 'g'),
                '\\s+', ' ', 'g'))"""

    return f"{normalized(artist)} || '|' || {normalized(title)}"


def _score(track: dict[str, Any]) -> int:
    title = str(track.get("title", "")).casefold()
    return sum(-10 for word in _PENALTY_WORDS if word in title)


def collapse_tracks(tracks: list[dict[str, Any]]) -> list[dict[str, Any]]:
    best: dict[str, dict[str, Any]] = {}
    order: list[str] = []
    for track in tracks:
        key = canonical_key(str(track["artist"]), str(track["title"]))
        current = best.get(key)
        if current is None:
            best[key] = track
            order.append(key)
        elif _score(track) > _score(current):
            best[key] = track
    return [best[key] for key in order]
