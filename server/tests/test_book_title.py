"""FT-669 (P-A99, contract C5): author, title, narrator and year of book from release title.

There is no dedicated book catalog: what is known about book is written in release title. Typical title shape —
"Author - Title [Narrator, 2015, 96 kbps, MP3]". The module extracts four fields from it and invents nothing:
what is missing from title is omitted from response.

Contract of module `app/book_title.py`:
- `MAX_RAW_TITLE = 1000`, `MAX_BOOK_TEXT = 500`;
- `BookTitle(title, author, narrator, year)` — frozen class with `slots`;
- `book_title(raw) -> BookTitle | None` — `None` if title could not be extracted. No external exceptions.

What tests do not prove: that real release titles look like this (samples based on lead's memory
of how they are formatted; verified against live source during wiring); that author and narrator are not
swapped in non-standard releases.
"""

from __future__ import annotations

import dataclasses
import time

import pytest

from app import book_title as module
from app.book_title import MAX_BOOK_TEXT, MAX_RAW_TITLE, BookTitle, book_title


def test_constants_are_the_agreed_ones():
    assert MAX_RAW_TITLE == 1000
    assert MAX_BOOK_TEXT == 500


def test_the_answer_has_exactly_four_fields_and_is_frozen():
    assert [f.name for f in dataclasses.fields(BookTitle)] == [
        "title",
        "author",
        "narrator",
        "year",
    ]
    answer = BookTitle("Книга", "", "", None)
    with pytest.raises(dataclasses.FrozenInstanceError):
        answer.title = "Другая"  # type: ignore[misc]
    assert not hasattr(answer, "__dict__")


# --- typical shape -----------------------------------------------------------


def test_the_usual_title():
    assert book_title(
        "Толстой Лев - Война и мир [Клюквин Александр, 2019, 96 kbps, MP3]"
    ) == BookTitle(
        title="Война и мир",
        author="Толстой Лев",
        narrator="Клюквин Александр",
        year=2019,
    )


@pytest.mark.parametrize("dash", [" - ", " – ", " — "])
def test_any_dash_with_spaces_separates_the_author(dash):
    answer = book_title(f"Кинг Стивен{dash}Оно [Булдаков Олег, 2020]")
    assert (answer.author, answer.title) == ("Кинг Стивен", "Оно")


def test_only_the_first_dash_separates_the_author():
    answer = book_title("Автор - Книга - Часть 2 — Финал [Чтец, 2011]")
    assert (answer.author, answer.title) == ("Автор", "Книга - Часть 2 — Финал")


def test_the_earliest_dash_wins_whatever_its_kind():
    answer = book_title("Автор — Книга - Часть 2 [Чтец]")
    assert (answer.author, answer.title) == ("Автор", "Книга - Часть 2")


def test_a_hyphen_without_spaces_is_part_of_a_name():
    answer = book_title("Сент-Экзюпери Антуан - Маленький принц [Чтец, 2015]")
    assert (answer.author, answer.title) == ("Сент-Экзюпери Антуан", "Маленький принц")
    assert book_title("Какой-то сборник [2010]").title == "Какой-то сборник"


def test_no_author_is_an_empty_author():
    assert book_title("Сборник сказок [2010, MP3]") == BookTitle(
        "Сборник сказок", "", "", 2010
    )


def test_round_brackets_stay_in_the_title():
    answer = book_title(
        "Кинг Стивен - Оно (Тёмная башня 1) [Булдаков Олег, 2020, AAC, 64 kbps]"
    )
    assert answer.title == "Оно (Тёмная башня 1)"
    assert (answer.narrator, answer.year) == ("Булдаков Олег", 2020)


def test_no_brackets_at_all():
    assert book_title("Автор - Книга") == BookTitle("Книга", "Автор", "", None)


def test_only_the_first_square_brackets_are_read():
    answer = book_title("Автор - Книга [Чтец, 2015] [Обновлено, 2021]")
    assert (answer.title, answer.narrator, answer.year) == ("Книга", "Чтец", 2015)


def test_text_after_the_brackets_is_not_the_title():
    assert book_title("Автор - Книга [Чтец] полная версия").title == "Книга"


def test_an_unclosed_bracket_is_read_to_the_end():
    answer = book_title("Автор - Книга [Чтец, 2015")
    assert (answer.title, answer.narrator, answer.year) == ("Книга", "Чтец", 2015)


# --- narrator ----------------------------------------------------------------


def test_several_narrators_are_kept_in_order():
    answer = book_title(
        "Автор - Книга [Иванов Иван, Петров Пётр, Сидорова Анна, 2015 г., 128 kbps, MP3]"
    )
    assert answer.narrator == "Иванов Иван, Петров Пётр, Сидорова Анна"
    assert answer.year == 2015


def test_names_end_at_the_first_technical_mark():
    # Everything after year, bitrate or format are uploader notes, not narrators.
    answer = book_title("Автор - Книга [Чтец, MP3, Отличное качество, 2015]")
    assert (answer.narrator, answer.year) == ("Чтец", 2015)
    answer = book_title("Автор - Книга [2015, Не чтец]")
    assert (answer.narrator, answer.year) == ("", 2015)


@pytest.mark.parametrize(
    "mark",
    [
        "96 kbps",
        "96kbps",
        "~64 kbps",
        "~ 64 kbps",
        "64-128 kbps",
        "64 - 128 kbps",
        "128 Kbps",
        "128 kbit/s",
        "128 kb/s",
        "96 кбит/с",
        "96 кбит/сек",
        "96 кб/с",
        "MP3",
        "mp3",
        "M4B",
        "m4a",
        "AAC",
        "OGG",
        "Opus",
        "FLAC",
        "WAV",
        "WMA",
        "VBR",
        "CBR",
        "MP3 VBR",
        "AAC M4B",
        "128",
        "64",
    ],
)
def test_bitrates_and_formats_are_not_narrators(mark):
    assert book_title(f"Автор - Книга [{mark}, Чтец, 2015]").narrator == ""
    assert book_title(f"Автор - Книга [Чтец, {mark}]").narrator == "Чтец"


@pytest.mark.parametrize(
    "name",
    [
        "MP3 Иванов",
        "Аас Пётр",
        "96 Иванов",
        "96 kbps Иванов",
        "kbps",
        "Чтец 96 kbps студии",
        "١٢٨",
    ],
)
def test_a_name_that_only_looks_technical_is_a_name(name):
    assert book_title(f"Автор - Книга [{name}, 2015]").narrator == name


def test_only_a_comma_separates_marks():
    answer = book_title("Автор - Книга [Иванов; Петров, 2015]")
    assert (answer.narrator, answer.year) == ("Иванов; Петров", 2015)


def test_empty_places_between_commas_are_skipped():
    answer = book_title("Автор - Книга [ , Чтец ,, , 2015 ,]")
    assert (answer.narrator, answer.year) == ("Чтец", 2015)


def test_empty_brackets_give_nothing():
    assert book_title("Автор - Книга []") == BookTitle("Книга", "Автор", "", None)


# --- year --------------------------------------------------------------------


@pytest.mark.parametrize(
    ("mark", "year"),
    [
        ("2015", 2015),
        ("2015 г.", 2015),
        ("2015г", 2015),
        ("2015 г", 2015),
        ("1500", 1500),
        ("1999", 1999),
        ("2099", 2099),
    ],
)
def test_a_year_is_read(mark, year):
    assert book_title(f"Автор - Книга [Чтец, {mark}, MP3]").year == year


@pytest.mark.parametrize(
    "mark",
    [
        "1499",
        "2100",
        "215",
        "20155",
        "2015-2016",
        "год 2015",
        "2015 год",
        "٢٠١٥",
        "20١٥",
        "1٩99",
        "2015.0",
    ],
)
def test_what_is_not_a_year_is_not_a_year(mark):
    answer = book_title(f"Автор - Книга [{mark}]")
    assert answer.year is None


def test_the_first_year_wins():
    assert book_title("Автор - Книга [Чтец, 2011, MP3, 2019]").year == 2011


def test_a_year_in_the_title_is_not_the_year_of_the_book():
    answer = book_title("Оруэлл Джордж - 1984 [Чтец]")
    assert (answer.title, answer.year) == ("1984", None)


# --- edge cases --------------------------------------------------------------


def test_spaces_and_control_characters_are_cleaned():
    answer = book_title("  Автор \t-\n Книга\x00\x07  первая  [ Чтец Иван ,\n2015 ] ")
    assert answer == BookTitle("Книга первая", "Автор", "Чтец Иван", 2015)


@pytest.mark.parametrize(
    ("raw", "title"),
    [
        ("- Только название [Чтец]", "Только название"),
        (" - Только название", "Только название"),
        ("Только название - [Чтец]", "Только название"),
        ("Только название —", "Только название"),
        ("— Только название –", "Только название"),
    ],
)
def test_a_dash_at_the_edge_is_not_a_separator(raw, title):
    answer = book_title(raw)
    assert (answer.author, answer.title) == ("", title)


@pytest.mark.parametrize(
    "raw",
    [
        None,
        5,
        b"Book",
        ["Автор - Книга"],
        "",
        "   ",
        "\n\t",
        "[Чтец, 2015]",
        " - ",
        "—",
        " [",
        "- - [x]",
    ],
)
def test_no_title_is_none(raw):
    assert book_title(raw) is None


def test_a_title_longer_than_the_limit_is_refused_whole():
    assert book_title("А" * MAX_RAW_TITLE) is not None
    assert book_title("А" * (MAX_RAW_TITLE + 1)) is None


def test_each_field_is_cut_to_the_limit_without_a_trailing_space():
    answer = book_title("Б" * (MAX_BOOK_TEXT - 1) + " хвост автора - " + "К" * 300)
    assert answer.author == "Б" * (MAX_BOOK_TEXT - 1)
    assert answer.title == "К" * 300
    long_title = book_title("Т" * 600 + " [" + "Ч" * 380 + "]")
    assert long_title.title == "Т" * MAX_BOOK_TEXT
    assert long_title.narrator == "Ч" * 380


def test_many_narrators_are_cut_to_the_limit():
    names = ", ".join(f"Чтец Номер{n}" for n in range(60))
    answer = book_title(f"А - К [{names}]")
    assert len(answer.narrator) <= MAX_BOOK_TEXT
    assert answer.narrator.startswith("Чтец Номер0, Чтец Номер1, ")
    assert not answer.narrator.endswith(" ")


def test_a_title_in_latin_works_the_same():
    assert book_title(
        "Tolkien J.R.R. - The Hobbit [Rob Inglis, 1991, 64 kbps, MP3]"
    ) == BookTitle("The Hobbit", "Tolkien J.R.R.", "Rob Inglis", 1991)


# --- privacy contract and size --------------------------------------------


def test_nothing_is_logged(caplog):
    with caplog.at_level("DEBUG"):
        book_title("Тайный автор - Тайная книга [Тайный чтец, 2015]")
        book_title("[Тайный чтец]")
        book_title(None)
    assert caplog.text == ""


def test_the_module_keeps_to_the_standard_library():
    source = open(module.__file__, encoding="utf-8").read()
    for word in ("import logging", "asyncpg", "httpx", "print("):
        assert word not in source


def test_a_nasty_title_is_fast():
    nasty = ("- " * 200 + "[" * 100 + ", " * 200)[:MAX_RAW_TITLE]
    started = time.perf_counter()
    for _ in range(200):
        book_title(nasty)
        book_title("9" * 999)
        book_title("~" + " " * 900 + "kbps")
    assert time.perf_counter() - started < 1.0
