"""FT-672: source output -> list of found books (contract D5a).

FT-720 (P-A88): a found item is identified by the `asset` key and an opaque `hint`
from the extension; core does not parse the hint. `popularity` is how many people seed
the item, the extension has its own scale; 0 means nobody, such items are omitted.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field

from app.book_title import book_title
from app.books import normalize_asset

MAX_FOUND_BOOKS: int = 50
MIN_BOOK_BYTES: int = 5 * 1024**2
MAX_BOOK_BYTES: int = 20 * 1024**3
MAX_HINT: int = 8192
MAX_HITS: int = 1000

__all__ = [
    "MAX_BOOK_BYTES",
    "MAX_FOUND_BOOKS",
    "MAX_HITS",
    "MAX_HINT",
    "MIN_BOOK_BYTES",
    "FoundBook",
    "found_books",
]


@dataclass(frozen=True, slots=True)
class FoundBook:
    title: str
    author: str
    narrator: str
    year: int | None
    size_bytes: int
    popularity: int | None
    asset: str = field(repr=False)
    hint: str = field(repr=False)
    language: str = "ru"


def _rank(book: FoundBook) -> tuple[int, int]:
    popularity = -1 if book.popularity is None else book.popularity
    return (popularity, book.size_bytes)


def found_books(
    hits: object,
    *,
    limit: int = MAX_FOUND_BOOKS,
    max_bytes: int = MAX_BOOK_BYTES,
) -> list[FoundBook]:
    """Convert source results into a sorted list of found books."""
    try:
        if not isinstance(hits, (list, tuple)):
            return []
        if not isinstance(limit, int) or isinstance(limit, bool) or limit < 1:
            return []
        if not isinstance(max_bytes, int) or isinstance(max_bytes, bool):
            effective_max_bytes = MAX_BOOK_BYTES
        else:
            effective_max_bytes = max_bytes

        by_key: dict[str, FoundBook] = {}

        for raw_hit in hits[:MAX_HITS]:
            try:
                if not isinstance(raw_hit, Mapping):
                    continue

                asset = normalize_asset(raw_hit.get("asset"))
                if asset is None:
                    continue

                raw_hint = raw_hit.get("hint")
                if type(raw_hint) is not str:
                    continue
                hint = raw_hint.strip()
                if not hint or len(hint) > MAX_HINT or "\x00" in hint:
                    continue
                # Lone surrogate: `save_book` will reject it.
                hint.encode()

                raw_popularity = raw_hit.get("popularity")
                if type(raw_popularity) is int and raw_popularity >= 0:
                    if raw_popularity == 0:
                        continue
                    popularity: int | None = raw_popularity
                else:
                    popularity = None

                raw_size = raw_hit.get("size")
                if type(raw_size) is int and raw_size >= 0:
                    if raw_size < MIN_BOOK_BYTES or raw_size > effective_max_bytes:
                        continue
                    size_bytes = raw_size
                else:
                    size_bytes = 0

                raw_title = raw_hit.get("title")
                parsed_title = book_title(raw_title)
                if parsed_title is None:
                    continue

                raw_lang = raw_hit.get("language")
                if (
                    isinstance(raw_lang, str)
                    and len(raw_lang) == 2
                    and raw_lang.isascii()
                    and raw_lang.islower()
                    and raw_lang.isalpha()
                ):
                    language = raw_lang
                else:
                    language = "ru"

                book = FoundBook(
                    title=parsed_title.title,
                    author=parsed_title.author,
                    narrator=parsed_title.narrator,
                    year=parsed_title.year,
                    size_bytes=size_bytes,
                    popularity=popularity,
                    asset=asset,
                    hint=hint,
                    language=language,
                )

                existing = by_key.get(asset)
                if existing is None or _rank(book) > _rank(existing):
                    by_key[asset] = book
            except Exception:
                continue

        sorted_books = sorted(by_key.values(), key=_rank, reverse=True)
        return sorted_books[:limit]
    except Exception:
        return []
