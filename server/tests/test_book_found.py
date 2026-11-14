"""Lead check FT-672: source output -> list of found books (contract D5a).

FT-720 (R-A88): finding uses key `asset` and opaque hint `hint`
of the extension, seeders count is `popularity`.
"""

from __future__ import annotations

from typing import Any

import pytest

from app import book_found
from app.book_found import (
    MAX_BOOK_BYTES,
    MAX_FOUND_BOOKS,
    MAX_HINT,
    MAX_HITS,
    MIN_BOOK_BYTES,
    FoundBook,
    found_books,
)

MB = 1024**2
ASSET_A = "bt:" + "a" * 40
ASSET_B = "bt:" + "b" * 40
HINT_A = "opaque-hint-a"


def hit(**changes: Any) -> dict[str, Any]:
    """Finding in the form returned by the book extension."""
    base: dict[str, Any] = {
        "title": "Толстой Лев - Война и мир [Иванов Иван, 2015, 96 kbps, MP3]",
        "asset": ASSET_A,
        "hint": HINT_A,
        "size": 700 * MB,
        "popularity": 12,
    }
    base.update(changes)
    return base


def other(n: int, **changes: Any) -> dict[str, Any]:
    fields: dict[str, Any] = {
        "title": f"Автор - Книга {n}",
        "asset": f"bt:{n:040x}",
        "hint": f"hint-{n}",
    }
    fields.update(changes)
    return hit(**fields)


def titles(books: list[FoundBook]) -> list[str]:
    return [book.title for book in books]


def test_constants() -> None:
    assert MAX_FOUND_BOOKS == 50
    assert MIN_BOOK_BYTES == 5 * 1024**2
    assert MAX_BOOK_BYTES == 20 * 1024**3
    assert MAX_HINT == 8192
    assert MAX_HITS == 1000


def test_a_release_becomes_a_found_book() -> None:
    assert found_books([hit()]) == [
        FoundBook(
            title="Война и мир",
            author="Толстой Лев",
            narrator="Иванов Иван",
            year=2015,
            size_bytes=700 * MB,
            popularity=12,
            asset=ASSET_A,
            hint=HINT_A,
        )
    ]


def test_the_book_is_frozen_and_has_exactly_these_fields() -> None:
    book = found_books([hit()])[0]
    assert list(FoundBook.__dataclass_fields__) == [
        "title",
        "author",
        "narrator",
        "year",
        "size_bytes",
        "popularity",
        "asset",
        "hint",
        "language",
    ]
    with pytest.raises(AttributeError):
        book.title = "x"  # type: ignore[misc]


def test_the_printed_book_shows_neither_the_release_nor_the_address() -> None:
    book = found_books([hit()])[0]
    for text in (repr(book), str(book)):
        assert ASSET_A not in text and HINT_A not in text


@pytest.mark.parametrize("hits", [None, "x", b"x", 5, {"a": 1}, iter([hit()]), {1, 2}])
def test_not_a_list_gives_nothing(hits: object) -> None:
    assert found_books(hits) == []


def test_a_tuple_is_read_like_a_list() -> None:
    assert titles(found_books((hit(),))) == ["Война и мир"]


def test_an_empty_answer_gives_nothing() -> None:
    assert found_books([]) == []


@pytest.mark.parametrize("bad", [None, "x", 5, ["title"], ("a", "b")])
def test_a_hit_that_is_not_a_mapping_is_skipped(bad: object) -> None:
    assert titles(found_books([bad, hit()])) == ["Война и мир"]


# --- key and hint --------------------------------------------------------


def test_the_key_is_trimmed_and_keeps_its_case() -> None:
    book = found_books([hit(asset="  bt:AbC-1\n")])[0]
    assert book.asset == "bt:AbC-1"


@pytest.mark.parametrize(
    "bad",
    [None, "", "   ", 5, b"bt:a", "abc", ":abc", "BT:abc", "bt:", "bt:a b", "bt:a/b"],
)
def test_a_release_without_a_usable_key_is_skipped(bad: object) -> None:
    assert found_books([hit(asset=bad)]) == []


def test_a_missing_key_field_is_skipped() -> None:
    broken = hit()
    del broken["asset"]
    assert found_books([broken]) == []


def test_the_hint_is_opaque_and_trimmed() -> None:
    for raw in ("anything://at/all?x=1", "ftp://x", "простой текст"):
        assert found_books([hit(hint=f"  {raw}\n")])[0].hint == raw


@pytest.mark.parametrize(
    "bad", [None, "", "   ", 5, b"opaque", "a\x00b", "h" * (MAX_HINT + 1)]
)
def test_a_release_without_a_usable_hint_is_skipped(bad: object) -> None:
    assert found_books([hit(hint=bad)]) == []


def test_the_hint_may_be_exactly_at_the_limit() -> None:
    assert len(found_books([hit(hint="h" * MAX_HINT)])) == 1


def test_an_object_that_only_prints_like_a_hint_is_skipped() -> None:
    class Sly:
        def __str__(self) -> str:
            return HINT_A

    assert found_books([hit(hint=Sly())]) == []


def test_a_missing_hint_field_is_skipped() -> None:
    broken = hit()
    del broken["hint"]
    assert found_books([broken]) == []


# --- size ----------------------------------------------------------------


@pytest.mark.parametrize("size", [MIN_BOOK_BYTES, 700 * MB, MAX_BOOK_BYTES])
def test_a_size_within_the_bounds_is_kept(size: int) -> None:
    assert found_books([hit(size=size)])[0].size_bytes == size


@pytest.mark.parametrize("size", [0, 1, MIN_BOOK_BYTES - 1, MAX_BOOK_BYTES + 1, 10**15])
def test_a_size_out_of_bounds_is_not_a_book(size: int) -> None:
    assert found_books([hit(size=size)]) == []


@pytest.mark.parametrize("size", [None, -1, "700", 7.5e8, True])
def test_an_unknown_size_is_shown_as_zero(size: object) -> None:
    assert found_books([hit(size=size)])[0].size_bytes == 0


def test_a_missing_size_field_is_an_unknown_size() -> None:
    lean = hit()
    del lean["size"]
    assert found_books([lean])[0].size_bytes == 0


def test_the_server_can_lower_the_upper_bound() -> None:
    hits = [other(1, size=300 * MB), other(2, size=301 * MB)]
    assert titles(found_books(hits, max_bytes=300 * MB)) == ["Книга 1"]


# --- seeders -------------------------------------------------------------


def test_a_release_nobody_gives_out_is_skipped() -> None:
    assert found_books([hit(popularity=0)]) == []


@pytest.mark.parametrize("popularity", [None, -1, "12", 3.0, True])
def test_an_unknown_number_of_givers_is_kept_as_unknown(popularity: object) -> None:
    assert found_books([hit(popularity=popularity)])[0].popularity is None


def test_a_missing_givers_field_is_unknown() -> None:
    lean = hit()
    del lean["popularity"]
    assert found_books([lean])[0].popularity is None


# --- title ---------------------------------------------------------------


@pytest.mark.parametrize("title", [None, "", "   ", 5, "[MP3]", " - ", "x" * 1001])
def test_a_release_whose_title_gives_no_book_is_skipped(title: object) -> None:
    assert found_books([hit(title=title)]) == []


def test_a_title_without_an_author_is_still_a_book() -> None:
    book = found_books([hit(title="Сказки народов мира")])[0]
    assert (book.title, book.author, book.narrator, book.year) == (
        "Сказки народов мира",
        "",
        "",
        None,
    )


# --- duplicates ----------------------------------------------------------


def test_the_same_release_twice_is_one_book_with_more_givers() -> None:
    hits = [
        hit(popularity=3),
        hit(popularity=40, title="Автор - Другое название"),
        hit(popularity=7),
    ]
    books = found_books(hits)
    assert len(books) == 1
    assert (books[0].popularity, books[0].title) == (40, "Другое название")


def test_the_same_key_with_spaces_is_the_same_release() -> None:
    hits = [
        hit(popularity=3),
        hit(popularity=5, asset=f" {ASSET_A} ", hint="another-hint"),
    ]
    books = found_books(hits)
    assert len(books) == 1 and books[0].popularity == 5


def test_a_known_number_of_givers_beats_an_unknown_one() -> None:
    for hits in (
        [hit(popularity=None), hit(popularity=1)],
        [hit(popularity=1), hit(popularity=None)],
    ):
        books = found_books(hits)
        assert len(books) == 1 and books[0].popularity == 1


def test_with_equal_givers_the_bigger_copy_stays() -> None:
    for hits in (
        [hit(size=100 * MB), hit(size=900 * MB)],
        [hit(size=900 * MB), hit(size=100 * MB)],
    ):
        assert found_books(hits)[0].size_bytes == 900 * MB


def test_fully_equal_copies_keep_the_first() -> None:
    hits = [
        hit(hint="first"),
        hit(hint="second"),
    ]
    assert found_books(hits)[0].hint == "first"


def test_a_key_that_differs_only_in_case_is_another_release() -> None:
    hits = [hit(asset="bt:abc", popularity=2), hit(asset="bt:ABC", popularity=9)]
    assert [book.popularity for book in found_books(hits)] == [9, 2]


def test_the_same_book_from_two_releases_stays_twice() -> None:
    hits = [hit(), hit(asset=ASSET_B, hint="hint-b", popularity=2)]
    assert titles(found_books(hits)) == ["Война и мир", "Война и мир"]


# --- order and count -----------------------------------------------------


def test_more_givers_come_first_and_unknown_come_last() -> None:
    hits = [
        other(1, popularity=5),
        other(2, popularity=None),
        other(3, popularity=50),
        other(4, popularity=1),
    ]
    assert titles(found_books(hits)) == ["Книга 3", "Книга 1", "Книга 4", "Книга 2"]


def test_givers_matter_more_than_size() -> None:
    hits = [
        other(1, popularity=1, size=900 * MB),
        other(2, popularity=5, size=100 * MB),
    ]
    assert titles(found_books(hits)) == ["Книга 2", "Книга 1"]


def test_with_equal_givers_the_bigger_comes_first() -> None:
    hits = [other(1, size=100 * MB), other(2, size=900 * MB), other(3, size=None)]
    assert titles(found_books(hits)) == ["Книга 2", "Книга 1", "Книга 3"]


def test_fully_equal_releases_keep_the_order_of_the_source() -> None:
    hits = [other(n) for n in (3, 1, 2)]
    assert titles(found_books(hits)) == ["Книга 3", "Книга 1", "Книга 2"]


def test_no_more_than_fifty_by_default() -> None:
    hits = [other(n, popularity=1000 - n) for n in range(1, 81)]
    books = found_books(hits)
    assert len(books) == MAX_FOUND_BOOKS
    assert (
        titles(books)[:2] == ["Книга 1", "Книга 2"] and titles(books)[-1] == "Книга 50"
    )


def test_the_limit_is_applied_after_ordering() -> None:
    hits = [other(1, popularity=1), other(2, popularity=2), other(3, popularity=3)]
    assert titles(found_books(hits, limit=2)) == ["Книга 3", "Книга 2"]


@pytest.mark.parametrize("limit", [0, -3])
def test_a_senseless_limit_gives_nothing(limit: int) -> None:
    assert found_books([other(n) for n in range(1, 8)], limit=limit) == []


def test_only_the_first_thousand_hits_are_read() -> None:
    hits = [other(n, popularity=1) for n in range(1, MAX_HITS + 1)] + [
        other(5000, popularity=999)
    ]
    books = found_books(hits, limit=5000)
    assert len(books) == MAX_HITS
    assert "Книга 5000" not in titles(books)


def test_garbage_around_does_not_hide_good_releases() -> None:
    hits = [
        None,
        hit(size=1),
        other(1),
        hit(asset="no key"),
        "x",
        other(2, popularity=0),
        other(3),
    ]
    assert titles(found_books(hits)) == ["Книга 1", "Книга 3"]


def test_the_input_is_left_as_it_was() -> None:
    hits = [hit(), other(1)]
    before = [dict(item) for item in hits]
    found_books(hits)
    assert hits == before


def test_the_module_writes_nothing_to_the_log() -> None:
    source = open(book_found.__file__, encoding="utf-8").read()
    assert "logging" not in source and "print(" not in source
