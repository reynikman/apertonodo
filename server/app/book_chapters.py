from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
import math

MAX_CHAPTERS: int = 3000
MAX_CHAPTER_TITLE: int = 200
MAX_FILE_MS: int = 30 * 24 * 3600 * 1000


@dataclass(frozen=True, slots=True)
class Chapter:
    number: int
    start_ms: int
    end_ms: int
    title: str


def _parse_seconds(val: object) -> int | None:
    if val is None or isinstance(val, bool):
        return None
    if isinstance(val, (int, float)):
        if isinstance(val, float) and (math.isnan(val) or math.isinf(val)):
            return None
        if val < 0:
            return None
        if val > MAX_FILE_MS:
            return None
        try:
            ms = round(val * 1000)
        except (OverflowError, ValueError):
            return None
        if 0 <= ms <= MAX_FILE_MS:
            return ms
        return None
    if isinstance(val, str):
        if not val.isascii():
            return None
        if "," in val:
            return None
        try:
            sec = float(val)
        except (ValueError, OverflowError):
            return None
        if math.isnan(sec) or math.isinf(sec) or sec < 0:
            return None
        try:
            ms = round(sec * 1000)
        except (OverflowError, ValueError):
            return None
        if 0 <= ms <= MAX_FILE_MS:
            return ms
        return None
    return None


def _parse_ticks(ticks: object, time_base: object) -> int | None:
    if not isinstance(ticks, int) or isinstance(ticks, bool):
        return None
    if ticks < 0:
        return None
    if ticks.bit_length() > 100:
        return None
    if not isinstance(time_base, str):
        return None
    if not time_base.isascii():
        return None
    tb = time_base.strip()
    parts = tb.split("/")
    if len(parts) != 2:
        return None
    num_s = parts[0].strip()
    den_s = parts[1].strip()
    if not num_s.isdigit() or not den_s.isdigit():
        return None
    if len(num_s) > 30 or len(den_s) > 30:
        return None
    num = int(num_s)
    den = int(den_s)
    if num == 0 or den == 0:
        return None
    try:
        ms_float = (ticks * num * 1000) / den
        ms = round(ms_float)
    except (OverflowError, ZeroDivisionError, ValueError):
        return None
    if 0 <= ms <= MAX_FILE_MS:
        return ms
    return None


def _parse_time(
    time_field: object, ticks_field: object, time_base_field: object
) -> int | None:
    if time_field is not None:
        ms = _parse_seconds(time_field)
        if ms is not None:
            return ms
    return _parse_ticks(ticks_field, time_base_field)


def _parse_title(item: Mapping[object, object]) -> str:
    tags = item.get("tags")
    if not isinstance(tags, Mapping):
        return ""
    raw_title: object = None
    if "title" in tags:
        raw_title = tags["title"]
    else:
        for k, v in tags.items():
            if isinstance(k, str) and k.lower() == "title":
                raw_title = v
                break
    if not isinstance(raw_title, str):
        return ""
    cleaned_chars: list[str] = []
    for char in raw_title:
        if char.isspace() or not char.isprintable():
            cleaned_chars.append(" ")
        else:
            cleaned_chars.append(char)
    title = " ".join("".join(cleaned_chars).split())
    if len(title) > MAX_CHAPTER_TITLE:
        title = title[:MAX_CHAPTER_TITLE].rstrip()
    return title


def book_chapters(probe: object, *, duration_ms: object = None) -> list[Chapter]:
    if not isinstance(probe, Mapping):
        return []
    chapters_raw = probe.get("chapters")
    if not isinstance(chapters_raw, list):
        return []
    if len(chapters_raw) > MAX_CHAPTERS or len(chapters_raw) < 2:
        return []

    valid_duration_ms: int | None = None
    if isinstance(duration_ms, int) and not isinstance(duration_ms, bool):
        if 1 <= duration_ms <= MAX_FILE_MS:
            valid_duration_ms = duration_ms

    raw_chapters: list[tuple[int, int, str]] = []
    seen_starts: set[int] = set()

    for item in chapters_raw:
        if not isinstance(item, Mapping):
            continue
        time_base = item.get("time_base")
        start_ms = _parse_time(item.get("start_time"), item.get("start"), time_base)
        if start_ms is None:
            continue
        end_ms = _parse_time(item.get("end_time"), item.get("end"), time_base)
        if end_ms is None:
            continue
        if end_ms <= start_ms:
            continue
        if valid_duration_ms is not None and start_ms >= valid_duration_ms:
            continue
        if start_ms in seen_starts:
            continue
        seen_starts.add(start_ms)
        title = _parse_title(item)
        raw_chapters.append((start_ms, end_ms, title))

    if len(raw_chapters) < 2:
        return []

    raw_chapters.sort(key=lambda c: c[0])
    max_end = max(c[1] for c in raw_chapters)

    result: list[Chapter] = []
    n = len(raw_chapters)
    for i, (start, _end, title) in enumerate(raw_chapters):
        ch_start = 0 if i == 0 else start
        if i < n - 1:
            ch_end = raw_chapters[i + 1][0]
        else:
            ch_end = valid_duration_ms if valid_duration_ms is not None else max_end
        result.append(
            Chapter(number=i + 1, start_ms=ch_start, end_ms=ch_end, title=title)
        )

    return result
