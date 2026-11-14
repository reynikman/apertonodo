"""Audiobook parts from the release file list (FT-665, P-A99, contract D5)."""

from __future__ import annotations

from dataclasses import dataclass
import re
from typing import Any, Iterable

BOOK_SUFFIXES: tuple[str, ...] = ("mp3", "m4a", "m4b", "aac", "ogg", "opus", "flac")
CHAPTER_SUFFIXES: tuple[str, ...] = ("m4b", "m4a")
MAX_BOOK_PARTS: int = 3000

_SPLIT_DIGITS = re.compile(r"([0-9]+)")


class BookTooLong(ValueError):
    """The release contains too many audio files."""


@dataclass(frozen=True, slots=True)
class BookPart:
    number: int
    file_index: int
    size: int
    kind: str


def _chunk_key(chunk: str) -> tuple[tuple[int, int | str, str], ...]:
    tokens: list[tuple[int, int | str, str]] = []
    for part in _SPLIT_DIGITS.split(chunk):
        if not part:
            continue
        if "0" <= part[0] <= "9":
            stripped = part.lstrip("0")
            tokens.append((0, len(stripped), stripped))
        else:
            tokens.append((1, part.lower(), ""))
    return tuple(tokens)


def _path_sort_key(
    segments: list[str], stem: str
) -> tuple[tuple[tuple[int, int | str, str], ...], ...]:
    chunks = tuple(segments[:-1]) + (stem,)
    return tuple(_chunk_key(chunk) for chunk in chunks)


def book_parts(files: Iterable[Any] | None) -> list[BookPart]:
    """Converts a release file list into ordered book parts."""
    if files is None:
        return []

    try:
        iterator = iter(files)
    except TypeError:
        return []

    seen_indices: set[int] = set()
    candidates: list[tuple[tuple[Any, int], int, int, str]] = []

    for item in iterator:
        if not isinstance(item, dict):
            continue

        file_index = item.get("index")
        if (
            not isinstance(file_index, int)
            or isinstance(file_index, bool)
            or file_index < 0
        ):
            continue

        size = item.get("length")
        if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
            continue

        name = item.get("name")
        if not isinstance(name, str):
            continue

        segments = [s for s in name.replace("\\", "/").split("/") if s]
        if not segments:
            continue

        is_hidden_or_service = False
        for seg in segments:
            if seg.startswith("."):
                is_hidden_or_service = True
                break
            seg_lower = seg.lower()
            if seg_lower == "__macosx" or seg_lower.startswith("_____padding_file"):
                is_hidden_or_service = True
                break
        if is_hidden_or_service:
            continue

        filename = segments[-1]
        stem, dot, ext = filename.rpartition(".")
        if not dot or not stem:
            continue

        kind = ext.lower()
        if kind not in BOOK_SUFFIXES:
            continue

        if file_index in seen_indices:
            continue
        seen_indices.add(file_index)

        if len(candidates) >= MAX_BOOK_PARTS:
            raise BookTooLong(f"Audiobook exceeds limit of {MAX_BOOK_PARTS} parts")

        key = (_path_sort_key(segments, stem), file_index)
        candidates.append((key, file_index, size, kind))

    candidates.sort(key=lambda c: c[0])

    return [
        BookPart(number=number, file_index=file_index, size=size, kind=kind)
        for number, (_, file_index, size, kind) in enumerate(candidates, start=1)
    ]


def may_have_chapters(parts: list[BookPart] | None) -> bool:
    """Checks whether the release may contain embedded chapters."""
    if not parts or len(parts) != 1:
        return False
    return parts[0].kind in CHAPTER_SUFFIXES
