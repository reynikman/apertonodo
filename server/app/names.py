from __future__ import annotations

import re


def norm(text: str) -> str:
    """Words separated by space: casefold, yo to e, without punctuation.

    The exact same function at loading and at searching — so "AC/DC" and
    "AC-DC" converge to `ac dc`, and "Guns N' Roses" — to `guns n roses`.
    """
    lowered = text.casefold().replace("ё", "е").replace("&", " and ")
    return " ".join(re.findall(r"\w+", lowered))


def first_artist(text: str) -> str:
    """Primary artist, normalized: "taylor swift feat post malone"
    → "taylor swift".

    Lineup from MusicBrainz arrives as a single string, whereas a release title
    contains only the primary artist: searching for the full phrase matched nothing there.
    "&" and comma are left untouched — "Simon & Garfunkel" is a single artist.
    """
    full = norm(text)
    cut = re.split(r"\b(?:feat|ft|featuring)\b", full, maxsplit=1)[0].strip()
    return cut or full