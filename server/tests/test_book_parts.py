"""FT-665 (R-A99, contract D5): audiobook parts from release file list.

Book is a release as found by source. Part is an audio file of the release. Order
of parts is natural sort of names ("2" before "10"), disc folders
are taken into account. Client does not see file names, so a part does not have them at all: only
sequential number and file index within release.

Contract of module `app/book_parts.py`:
- `book_parts(files) -> list[BookPart]` — `files` as returned by
  the source extension file listing: dicts `{"index", "name", "length"}`. Empty
  list — no audio in release. Garbage input is skipped, no exceptions raised —
  except one: `BookTooLong`, when audio files exceed `MAX_BOOK_PARTS`;
- `BookPart(number, file_index, size, kind)` — immutable record;
- `may_have_chapters(parts) -> bool` — book is a single container file;
- constants `BOOK_SUFFIXES`, `CHAPTER_SUFFIXES`, `MAX_BOOK_PARTS = 3000`.
"""

from __future__ import annotations

import dataclasses
import pathlib
import random
import time

import pytest

from app.book_parts import (
    BOOK_SUFFIXES,
    CHAPTER_SUFFIXES,
    MAX_BOOK_PARTS,
    BookPart,
    BookTooLong,
    book_parts,
    may_have_chapters,
)


def _files(*names: str, size: int = 1000) -> list[dict]:
    return [
        {"index": index, "name": name, "length": size + index}
        for index, name in enumerate(names)
    ]


def _order(*names: str) -> list[str]:
    """Names in the order parts were placed."""
    return [names[part.file_index] for part in book_parts(_files(*names))]


# --- contract -------------------------------------------------------------


def test_constants_are_the_agreed_ones():
    assert BOOK_SUFFIXES == ("mp3", "m4a", "m4b", "aac", "ogg", "opus", "flac")
    assert CHAPTER_SUFFIXES == ("m4b", "m4a")
    assert MAX_BOOK_PARTS == 3000


def test_a_part_carries_number_file_index_size_and_kind_and_nothing_else():
    assert [field.name for field in dataclasses.fields(BookPart)] == [
        "number",
        "file_index",
        "size",
        "kind",
    ]


def test_a_part_cannot_be_changed():
    part = book_parts(_files("a.mp3"))[0]
    with pytest.raises(dataclasses.FrozenInstanceError):
        part.number = 5  # type: ignore[misc]


def test_one_file_is_one_part():
    assert book_parts([{"index": 4, "name": "Book/01.mp3", "length": 777}]) == [
        BookPart(number=1, file_index=4, size=777, kind="mp3")
    ]


def test_numbers_run_from_one_without_gaps_and_keep_the_release_index():
    files = [
        {"index": 0, "name": "cover.jpg", "length": 10},
        {"index": 1, "name": "02.mp3", "length": 200},
        {"index": 2, "name": "about.txt", "length": 10},
        {"index": 3, "name": "01.mp3", "length": 100},
    ]
    assert book_parts(files) == [
        BookPart(number=1, file_index=3, size=100, kind="mp3"),
        BookPart(number=2, file_index=1, size=200, kind="mp3"),
    ]


def test_nothing_to_play_gives_an_empty_list():
    assert book_parts(_files("cover.jpg", "book.cue", "readme.txt")) == []
    assert book_parts([]) == []
    assert book_parts(None) == []


# --- order ----------------------------------------------------------------


def test_two_goes_before_ten():
    assert _order("10.mp3", "2.mp3", "1.mp3") == ["1.mp3", "2.mp3", "10.mp3"]


def test_numbers_inside_a_name_are_compared_as_numbers():
    assert _order("Глава 12 - б.mp3", "Глава 2 - а.mp3", "Глава 100.mp3") == [
        "Глава 2 - а.mp3",
        "Глава 12 - б.mp3",
        "Глава 100.mp3",
    ]


def test_leading_zeros_do_not_change_the_order():
    assert _order("010.mp3", "9.mp3", "0011.mp3") == ["9.mp3", "010.mp3", "0011.mp3"]


def test_several_numbers_in_one_name():
    assert _order("2-10.mp3", "2-9.mp3", "1-11.mp3") == [
        "1-11.mp3",
        "2-9.mp3",
        "2-10.mp3",
    ]


def test_letter_case_does_not_matter():
    assert _order("b.mp3", "A.mp3", "C.mp3") == ["A.mp3", "b.mp3", "C.mp3"]


def test_disc_folders_go_in_natural_order():
    assert _order(
        "Book/CD10/01.mp3",
        "Book/CD2/02.mp3",
        "Book/CD2/01.mp3",
        "Book/CD1/01.mp3",
    ) == [
        "Book/CD1/01.mp3",
        "Book/CD2/01.mp3",
        "Book/CD2/02.mp3",
        "Book/CD10/01.mp3",
    ]


def test_a_folder_is_compared_before_the_file_name():
    # Not "joined string": otherwise "a/10" would end up between "a b/1" and "a b/2".
    assert _order("a b/1.mp3", "a/10.mp3", "a b/2.mp3") == [
        "a/10.mp3",
        "a b/1.mp3",
        "a b/2.mp3",
    ]


def test_windows_separators_are_folders_too():
    assert _order("Book\\CD2\\01.mp3", "Book\\CD1\\02.mp3", "Book\\CD1\\01.mp3") == [
        "Book\\CD1\\01.mp3",
        "Book\\CD1\\02.mp3",
        "Book\\CD2\\01.mp3",
    ]


def test_windows_folders_are_compared_one_by_one_as_well():
    assert _order("a b\\1.mp3", "a\\10.mp3", "a b\\2.mp3") == [
        "a\\10.mp3",
        "a b\\1.mp3",
        "a b\\2.mp3",
    ]


def test_extra_slashes_do_not_change_the_order():
    assert _order("/b/1.mp3", "a/1.mp3") == ["a/1.mp3", "/b/1.mp3"]
    assert _order("a//2.mp3", "a/1.mp3", "a/3.mp3") == [
        "a/1.mp3",
        "a//2.mp3",
        "a/3.mp3",
    ]


def test_the_suffix_does_not_take_part_in_the_order():
    # "1.mp3" before "1 bonus.mp3": compares "1" and "1 bonus", not "1." and "1 ".
    assert _order("1 bonus.mp3", "1.mp3") == ["1.mp3", "1 bonus.mp3"]
    assert _order("2.flac", "1.mp3", "3.aac") == ["1.mp3", "2.flac", "3.aac"]


def test_a_number_goes_before_a_word():
    assert _order("intro.mp3", "1.mp3") == ["1.mp3", "intro.mp3"]


def test_equal_names_keep_the_release_order():
    files = [
        {"index": 7, "name": "01.mp3", "length": 1},
        {"index": 3, "name": "1.mp3", "length": 2},
        {"index": 5, "name": "001.mp3", "length": 3},
    ]
    assert [part.file_index for part in book_parts(files)] == [3, 5, 7]


def test_the_order_does_not_depend_on_how_the_release_lists_files():
    names = [
        f"CD{disc}/{track:02d}.mp3" for disc in range(1, 13) for track in range(1, 30)
    ]
    files = _files(*names)
    wanted = [part.file_index for part in book_parts(files)]
    assert wanted == list(range(len(names)))
    shuffled = files[:]
    random.Random(7).shuffle(shuffled)
    assert [part.file_index for part in book_parts(shuffled)] == wanted


def test_a_very_long_number_does_not_crash_and_still_sorts():
    # Python refuses to convert a string longer than 4300 digits to an integer.
    big = "9" * 5000
    bigger = "1" + "0" * 5000
    assert _order(f"{bigger}.mp3", f"{big}.mp3", "5.mp3") == [
        "5.mp3",
        f"{big}.mp3",
        f"{bigger}.mp3",
    ]


def test_digits_of_other_alphabets_are_just_letters():
    # "²" and "٣" are Unicode digits, but not numbers in file name; parsing does not crash on them.
    assert len(book_parts(_files("глава².mp3", "глава٣.mp3", "глава1.mp3"))) == 3
    assert _order("глава².mp3", "глава1.mp3")[0] == "глава1.mp3"
    assert _order("².mp3", "10.mp3") == ["10.mp3", "².mp3"]


# --- what is considered audio ---------------------------------------------


@pytest.mark.parametrize("suffix", BOOK_SUFFIXES)
def test_every_agreed_format_is_a_part(suffix):
    assert [part.kind for part in book_parts(_files(f"01.{suffix}"))] == [suffix]


def test_the_suffix_is_read_in_any_case():
    assert [part.kind for part in book_parts(_files("01.MP3", "02.M4B"))] == [
        "mp3",
        "m4b",
    ]


@pytest.mark.parametrize(
    "name",
    [
        "cover.jpg",
        "book.cue",
        "book.m3u",
        "book.pdf",
        "01.wav",
        "01.wma",
        "01.mp3.part",
        "mp3",
        "01mp3",
        "folder.mp3/readme.txt",
    ],
)
def test_other_files_are_not_parts(name):
    assert book_parts(_files(name)) == []


@pytest.mark.parametrize(
    "name",
    [
        ".mp3",
        ".hidden.mp3",
        "Book/.trash/01.mp3",
        "__MACOSX/Book/01.mp3",
        "Book/__macosx/01.mp3",
        ".pad/1024",
        "_____padding_file_0_if you see this file.mp3",
        "Book/_____PADDING_FILE_3.mp3",
    ],
)
def test_hidden_and_service_files_are_not_parts(name):
    assert book_parts(_files(name)) == []


def test_a_hidden_windows_folder_is_hidden_too():
    assert book_parts(_files("Book\\.trash\\01.mp3")) == []


def test_a_dot_inside_a_file_name_is_not_the_suffix():
    assert [part.kind for part in book_parts(_files("Глава 1. Начало.mp3"))] == ["mp3"]


def test_a_dot_inside_a_folder_name_does_not_hide_it():
    assert len(book_parts(_files("Автор. Книга (2010)/01.mp3"))) == 1


@pytest.mark.parametrize("length", [0, -5, None, "1000", 12.5, True])
def test_a_file_without_a_real_size_is_not_a_part(length):
    assert book_parts([{"index": 0, "name": "01.mp3", "length": length}]) == []


@pytest.mark.parametrize("index", [-1, None, "0", 1.0, True])
def test_a_file_without_a_real_index_is_not_a_part(index):
    assert book_parts([{"index": index, "name": "01.mp3", "length": 10}]) == []


@pytest.mark.parametrize(
    "name",
    [None, 5, b"01.mp3", "", "/", "\\\\", ["01.mp3"], pathlib.PurePosixPath("01.mp3")],
)
def test_a_file_without_a_real_name_is_not_a_part(name):
    assert book_parts([{"index": 0, "name": name, "length": 10}]) == []


def test_garbage_between_files_is_skipped():
    files = [
        None,
        "01.mp3",
        42,
        ["index", 0],
        {},
        {"name": "01.mp3"},
        {"index": 0, "name": "02.mp3", "length": 10},
    ]
    assert book_parts(files) == [BookPart(number=1, file_index=0, size=10, kind="mp3")]


def test_the_same_index_twice_is_taken_once():
    files = [
        {"index": 0, "name": "02.mp3", "length": 10},
        {"index": 0, "name": "01.mp3", "length": 20},
        {"index": 1, "name": "03.mp3", "length": 30},
    ]
    assert book_parts(files) == [
        BookPart(number=1, file_index=0, size=10, kind="mp3"),
        BookPart(number=2, file_index=1, size=30, kind="mp3"),
    ]


def test_a_skipped_file_does_not_take_the_index():
    files = [
        {"index": 0, "name": "cover.jpg", "length": 10},
        {"index": 0, "name": "01.mp3", "length": 20},
    ]
    assert [part.size for part in book_parts(files)] == [20]


def test_any_iterable_will_do():
    assert len(book_parts(iter(_files("1.mp3", "2.mp3")))) == 2
    assert len(book_parts(tuple(_files("1.mp3", "2.mp3")))) == 2


def test_the_input_is_left_untouched():
    files = _files("2.mp3", "1.mp3")
    before = [dict(item) for item in files]
    book_parts(files)
    assert files == before


# --- limit ----------------------------------------------------------------


def test_the_limit_itself_is_still_a_book():
    names = [f"{n}.mp3" for n in range(MAX_BOOK_PARTS)]
    parts = book_parts(_files(*names))
    assert len(parts) == MAX_BOOK_PARTS
    assert parts[-1].number == MAX_BOOK_PARTS


def test_one_over_the_limit_is_refused():
    names = [f"{n}.mp3" for n in range(MAX_BOOK_PARTS + 1)]
    with pytest.raises(BookTooLong):
        book_parts(_files(*names))


def test_only_audio_counts_towards_the_limit():
    names = [f"{n}.mp3" for n in range(MAX_BOOK_PARTS)] + [
        f"{n}.jpg" for n in range(500)
    ]
    assert len(book_parts(_files(*names))) == MAX_BOOK_PARTS


def test_the_refusal_is_a_value_error_and_names_no_file():
    names = [f"Тайная книга {n}.mp3" for n in range(MAX_BOOK_PARTS + 1)]
    with pytest.raises(ValueError) as caught:
        book_parts(_files(*names))
    assert "Тайная" not in str(caught.value)
    assert "Тайная" not in repr(caught.value)
    assert str(caught.value)


def test_a_part_does_not_remember_the_file_name():
    part = book_parts(_files("Тайная книга/Глава 1.mp3"))[0]
    assert "Тайная" not in repr(part)
    assert "Глава" not in repr(part)


def test_a_full_size_book_is_sorted_quickly():
    names = [
        f"Книга/Диск {disc}/Глава {track:03d} — название главы.mp3"
        for disc in range(1, 31)
        for track in range(1, 101)
    ]
    files = _files(*names)
    random.Random(3).shuffle(files)
    started = time.perf_counter()
    parts = book_parts(files)
    assert time.perf_counter() - started < 1.0
    assert [part.file_index for part in parts] == list(range(len(names)))


# --- chapters -------------------------------------------------------------


@pytest.mark.parametrize("suffix", CHAPTER_SUFFIXES)
def test_a_single_container_file_may_have_chapters(suffix):
    assert may_have_chapters(book_parts(_files(f"book.{suffix}"))) is True


@pytest.mark.parametrize("suffix", ["mp3", "flac", "ogg", "opus", "aac"])
def test_a_single_plain_file_has_no_chapters(suffix):
    assert may_have_chapters(book_parts(_files(f"book.{suffix}"))) is False


def test_several_files_are_parts_already():
    assert may_have_chapters(book_parts(_files("1.m4b", "2.m4b"))) is False


def test_no_parts_no_chapters():
    assert may_have_chapters([]) is False
