"""FT-669: extracting author, title, narrator and year of an audiobook from the release title."""

from __future__ import annotations

from dataclasses import dataclass
import re

MAX_RAW_TITLE: int = 1000
MAX_BOOK_TEXT: int = 500

_YEAR_RE: re.Pattern[str] = re.compile(r"^([0-9]{4})(?: ?[гГ]\.?)?$")
_BARE_NUMBER_RE: re.Pattern[str] = re.compile(r"^[0-9]+$")
_BITRATE_RE: re.Pattern[str] = re.compile(
    r"^~? ?[0-9]+(?: ?[-–—] ?[0-9]+)? ?(?:kbps|kbit/s|kb/s|кбит/сек|кбит/с|кб/с)$",
    re.IGNORECASE,
)
_FORMAT_WORDS: frozenset[str] = frozenset(
    {
        "mp3",
        "m4b",
        "m4a",
        "aac",
        "ogg",
        "opus",
        "flac",
        "wav",
        "wma",
        "vbr",
        "cbr",
    }
)
_SEPARATORS: tuple[str, ...] = (" - ", " – ", " — ")
_HEAD_STRIP_CHARS: str = " -–—"

__all__ = ["MAX_BOOK_TEXT", "MAX_RAW_TITLE", "BookTitle", "book_title"]


@dataclass(frozen=True, slots=True)
class BookTitle:
    title: str
    author: str
    narrator: str
    year: int | None


def _parse_year(mark: str) -> int | None:
    match = _YEAR_RE.match(mark)
    if not match:
        return None
    val = int(match.group(1))
    if 1500 <= val <= 2099:
        return val
    return None


def _is_technical(mark: str) -> bool:
    if _BARE_NUMBER_RE.match(mark):
        return True
    if _BITRATE_RE.match(mark):
        return True
    words = mark.lower().split()
    if words and all(w in _FORMAT_WORDS for w in words):
        return True
    return False


def _trim_field(text: str) -> str:
    if len(text) > MAX_BOOK_TEXT:
        return text[:MAX_BOOK_TEXT].rstrip()
    return text.rstrip()


def book_title(raw: object) -> BookTitle | None:
    """Extracts audiobook fields from a raw release title.

    Returns BookTitle with four fields, or None if the title
    could not be extracted. Never raises exceptions to the caller.
    """
    if not isinstance(raw, str) or len(raw) > MAX_RAW_TITLE:
        return None

    try:
        cleaned_chars: list[str] = []
        for ch in raw:
            if ch.isspace() or not ch.isprintable():
                cleaned_chars.append(" ")
            else:
                cleaned_chars.append(ch)
        cleaned = " ".join("".join(cleaned_chars).split())
        if not cleaned:
            return None

        bracket_idx = cleaned.find("[")
        if bracket_idx != -1:
            head = cleaned[:bracket_idx]
            remainder = cleaned[bracket_idx + 1 :]
            close_idx = remainder.find("]")
            if close_idx != -1:
                marks_part = remainder[:close_idx]
            else:
                marks_part = remainder
        else:
            head = cleaned
            marks_part = ""

        head = head.strip(_HEAD_STRIP_CHARS)
        if not head:
            return None

        earliest_pos = -1
        for sep in _SEPARATORS:
            pos = head.find(sep)
            if pos != -1:
                if earliest_pos == -1 or pos < earliest_pos:
                    earliest_pos = pos

        if earliest_pos != -1:
            author = head[:earliest_pos].strip()
            title = head[earliest_pos + 3 :].strip()
        else:
            author = ""
            title = head.strip()

        author = _trim_field(author)
        title = _trim_field(title)
        if not title:
            return None

        narrators: list[str] = []
        year: int | None = None
        collecting_narrators = True

        raw_marks = marks_part.split(",")
        for item in raw_marks:
            mark = item.strip()
            if not mark:
                continue

            year_val = _parse_year(mark)
            if year_val is not None:
                if year is None:
                    year = year_val
                collecting_narrators = False
                continue

            if _is_technical(mark):
                collecting_narrators = False
                continue

            if collecting_narrators:
                narrators.append(mark)

        narrator = _trim_field(", ".join(narrators))

        return BookTitle(
            title=title,
            author=author,
            narrator=narrator,
            year=year,
        )
    except Exception:
        return None
