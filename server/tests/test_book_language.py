"""FT-785: book language reaches from extension to app (Р-A105 items 4–5).

The extension returns `language` (ISO 639-1 or `null`); the core no longer
discards it: `FoundBook.language` and field `language` in
`/v1/books/search` output. A book without language attribute is Russian (Р-A105 item 5).

What is not covered: real extension and app-side filter (separate test).
"""

from __future__ import annotations

from test_book_extension import Ext, ext, item, run


def test_language_from_extension_reaches_found_book() -> None:
    fake = Ext()
    fake.find_body = {"items": [item(1, language="en")]}
    [book] = run(ext(fake).search("dune", 5))
    assert book.language == "en"


def test_book_without_language_is_russian() -> None:
    fake = Ext()
    fake.find_body = {"items": [item(1, language=None)]}
    [book] = run(ext(fake).search("мастер", 5))
    assert book.language == "ru"


def test_bad_language_is_russian_not_an_error() -> None:
    fake = Ext()
    fake.find_body = {"items": [item(1, language="English"), item(2, language=7)]}
    books = run(ext(fake).search("мастер", 5))
    assert len(books) == 2
    assert {b.language for b in books} == {"ru"}
