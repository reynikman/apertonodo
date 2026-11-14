"""FT-686: name spelling in another alphabet for fallback search."""

from __future__ import annotations

import itertools

MAX_VARIANTS = 8
MIN_LETTERS = 2
MAX_TEXT = 200

CYR_TO_LAT: dict[str, tuple[str, ...]] = {
    "а": ("a",),
    "б": ("b",),
    "в": ("v",),
    "г": ("g",),
    "д": ("d",),
    "е": ("e",),
    "ё": ("e", "yo"),
    "ж": ("zh",),
    "з": ("z",),
    "и": ("i",),
    "й": ("y", "j", "i"),
    "к": ("k",),
    "л": ("l",),
    "м": ("m",),
    "н": ("n",),
    "о": ("o",),
    "п": ("p",),
    "р": ("r",),
    "с": ("s",),
    "т": ("t",),
    "у": ("u",),
    "ф": ("f",),
    "х": ("h",),
    "ц": ("ts", "c"),
    "ч": ("ch",),
    "ш": ("sh",),
    "щ": ("sch",),
    "ъ": ("",),
    "ы": ("y",),
    "ь": ("",),
    "э": ("e",),
    "ю": ("yu",),
    "я": ("ya",),
}

LAT_TO_CYR: dict[str, tuple[str, ...]] = {
    "shch": ("щ",),
    "sch": ("щ",),
    "zh": ("ж",),
    "kh": ("х",),
    "ch": ("ч",),
    "sh": ("ш",),
    "ts": ("ц",),
    "ya": ("я",),
    "yu": ("ю",),
    "yo": ("ё",),
    "ja": ("я",),
    "ju": ("ю",),
    "a": ("а",),
    "b": ("б",),
    "c": ("к", "ц"),
    "d": ("д",),
    "e": ("е", "э"),
    "f": ("ф",),
    "g": ("г",),
    "h": ("х",),
    "i": ("и",),
    "j": ("й",),
    "k": ("к",),
    "l": ("л",),
    "m": ("м",),
    "n": ("н",),
    "o": ("о",),
    "p": ("п",),
    "q": ("к",),
    "r": ("р",),
    "s": ("с",),
    "t": ("т",),
    "u": ("у",),
    "v": ("в",),
    "w": ("в",),
    "x": ("кс",),
    "y": ("ы", "й", "и"),
    "z": ("з",),
}

_CYRILLIC_LETTERS: frozenset[str] = frozenset("абвгдеёжзийклмнопрстуфхцчшщъыьэюя")
_LATIN_LETTERS: frozenset[str] = frozenset("abcdefghijklmnopqrstuvwxyz")
_MAX_LAT_KEY_LEN: int = max(len(key) for key in LAT_TO_CYR)


def variants(text: object) -> list[str]:
    if not isinstance(text, str) or len(text) > MAX_TEXT:
        return []

    cleaned = " ".join(text.lower().split())
    cyr_count = sum(1 for ch in cleaned if ch in _CYRILLIC_LETTERS)
    lat_count = sum(1 for ch in cleaned if ch in _LATIN_LETTERS)

    if (cyr_count > 0 and lat_count > 0) or (cyr_count + lat_count < MIN_LETTERS):
        return []

    tokens: list[tuple[str, ...]] = []
    if cyr_count > 0:
        for ch in cleaned:
            tokens.append(CYR_TO_LAT.get(ch, (ch,)))
    else:
        index = 0
        total_len = len(cleaned)
        while index < total_len:
            matched = False
            for span in range(min(_MAX_LAT_KEY_LEN, total_len - index), 0, -1):
                chunk = cleaned[index : index + span]
                if chunk in LAT_TO_CYR:
                    tokens.append(LAT_TO_CYR[chunk])
                    index += span
                    matched = True
                    break
            if not matched:
                tokens.append((cleaned[index],))
                index += 1

    results: list[str] = []
    seen: set[str] = set()
    for combo in itertools.product(*tokens):
        candidate = "".join(combo)
        if candidate != cleaned and candidate not in seen:
            seen.add(candidate)
            results.append(candidate)
            if len(results) >= MAX_VARIANTS:
                break

    return results
