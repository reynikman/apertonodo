"""FT-687: podcast language from the feed `<language>` field."""

from __future__ import annotations

MAX_RAW: int = 35

THREE_LETTER: dict[str, str] = {
    "ara": "ar",
    "ces": "cs",
    "chi": "zh",
    "cze": "cs",
    "dan": "da",
    "deu": "de",
    "dut": "nl",
    "ell": "el",
    "eng": "en",
    "fin": "fi",
    "fra": "fr",
    "fre": "fr",
    "ger": "de",
    "gre": "el",
    "ita": "it",
    "jpn": "ja",
    "kaz": "kk",
    "kor": "ko",
    "nld": "nl",
    "nor": "no",
    "pol": "pl",
    "por": "pt",
    "rus": "ru",
    "spa": "es",
    "swe": "sv",
    "tur": "tr",
    "ukr": "uk",
    "zho": "zh",
}

NAMES: dict[str, str] = {
    "английский": "en",
    "русский": "ru",
    "chinese": "zh",
    "english": "en",
    "french": "fr",
    "german": "de",
    "italian": "it",
    "portuguese": "pt",
    "russian": "ru",
    "spanish": "es",
}


def language_of(raw: object) -> str | None:
    if not isinstance(raw, str) or len(raw) > MAX_RAW:
        return None

    cleaned = raw.strip().lower()
    if not cleaned:
        return None

    if cleaned in NAMES:
        return NAMES[cleaned]

    part = cleaned.split("-", 1)[0].split("_", 1)[0]
    if not (2 <= len(part) <= 3) or not part.isascii() or not part.isalpha():
        return None

    if len(part) == 2:
        return part

    return THREE_LETTER.get(part)
