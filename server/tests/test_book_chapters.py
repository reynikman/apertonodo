"""FT-668 (R-A99, contract D5): audiobook chapters from ffprobe output.

Single-file book (`m4b`) is split into chapters: each chapter is a part with start and end inside file.
Server queries `ffprobe -show_chapters -of json`, and this module converts the parsed response into chapters.

Contract of module `app/book_chapters.py`:
- `MAX_CHAPTERS = 3000`, `MAX_CHAPTER_TITLE = 200`, `MAX_FILE_MS` — 30 days in milliseconds;
- `Chapter(number, start_ms, end_ms, title)` — frozen class with `slots`;
- `book_chapters(probe, *, duration_ms=None) -> list[Chapter]` — chapters sequential and without gaps, first starting at zero;
  empty list means "no chapters, file plays as a whole". No exceptions raised on any input.

What tests do not prove: that `ffprobe` is executed and that its output on real books is as shown here
(will be verified on live source upon wiring); that player plays a chapter from beginning to end.
"""

from __future__ import annotations

import dataclasses
import json
import time
from typing import Any

import pytest

from app import book_chapters as module
from app.book_chapters import (
    MAX_CHAPTER_TITLE,
    MAX_CHAPTERS,
    MAX_FILE_MS,
    Chapter,
    book_chapters,
)


def ch(begin: Any, finish: Any, title: Any = None, **over: Any) -> dict[str, Any]:
    """Chapter as printed by ffprobe: seconds as string with six digits."""
    real_begin = isinstance(begin, (int, float)) and not isinstance(begin, bool)
    real_finish = isinstance(finish, (int, float)) and not isinstance(finish, bool)
    item: dict[str, Any] = {
        "id": 0,
        "time_base": "1/1000",
        "start": int(begin * 1000) if real_begin else 0,
        "start_time": f"{begin:.6f}" if real_begin else begin,
        "end": int(finish * 1000) if real_finish else 0,
        "end_time": f"{finish:.6f}" if real_finish else finish,
    }
    if title is not None:
        item["tags"] = {"title": title}
    item.update(over)
    return item


def probe(*chapters: Any) -> dict[str, Any]:
    return {"chapters": list(chapters)}


def spans(chapters: list[Chapter]) -> list[tuple[int, int, int]]:
    return [(c.number, c.start_ms, c.end_ms) for c in chapters]


# --- contract -------------------------------------------------------------


def test_constants_are_the_agreed_ones():
    assert MAX_CHAPTERS == 3000
    assert MAX_CHAPTER_TITLE == 200
    assert MAX_FILE_MS == 30 * 24 * 3600 * 1000


def test_a_chapter_has_exactly_four_fields_and_is_frozen():
    assert [f.name for f in dataclasses.fields(Chapter)] == [
        "number",
        "start_ms",
        "end_ms",
        "title",
    ]
    chapter = Chapter(1, 0, 10, "")
    with pytest.raises(dataclasses.FrozenInstanceError):
        chapter.number = 2  # type: ignore[misc]
    assert not hasattr(chapter, "__dict__")


# --- normal book ---------------------------------------------------------


def test_a_real_ffprobe_answer_becomes_chapters():
    answer = json.loads(
        """{"chapters": [
          {"id": 0, "time_base": "1/1000", "start": 0, "start_time": "0.000000",
           "end": 754321, "end_time": "754.321000", "tags": {"title": "Глава 1"}},
          {"id": 1, "time_base": "1/1000", "start": 754321, "start_time": "754.321000",
           "end": 1500000, "end_time": "1500.000000", "tags": {"title": "Глава 2"}},
          {"id": 2, "time_base": "1/1000", "start": 1500000, "start_time": "1500.000000",
           "end": 2400500, "end_time": "2400.500000", "tags": {"title": "Эпилог"}}
        ]}"""
    )
    assert book_chapters(answer) == [
        Chapter(1, 0, 754321, "Глава 1"),
        Chapter(2, 754321, 1500000, "Глава 2"),
        Chapter(3, 1500000, 2400500, "Эпилог"),
    ]


def test_chapters_come_out_in_time_order_whatever_the_input_order():
    answer = probe(ch(200, 300, "C"), ch(0, 100, "A"), ch(100, 200, "B"))
    assert [c.title for c in book_chapters(answer)] == ["A", "B", "C"]
    assert spans(book_chapters(answer)) == [
        (1, 0, 100000),
        (2, 100000, 200000),
        (3, 200000, 300000),
    ]


def test_the_input_is_not_changed():
    answer = probe(ch(200, 300, "C"), ch(0, 100, "A"))
    before = json.dumps(answer, sort_keys=True)
    book_chapters(answer)
    assert json.dumps(answer, sort_keys=True) == before


def test_milliseconds_are_rounded_not_cut():
    answer = probe(ch("0.000000", "1.999600"), ch("1.999600", "3.000400"))
    assert spans(book_chapters(answer)) == [(1, 0, 2000), (2, 2000, 3000)]


# --- without gaps or overlaps --------------------------------------------


def test_a_gap_between_chapters_belongs_to_the_earlier_one():
    answer = probe(ch(0, 90), ch(100, 200))
    assert spans(book_chapters(answer)) == [(1, 0, 100000), (2, 100000, 200000)]


def test_an_overlap_is_cut_at_the_next_start():
    answer = probe(ch(0, 150), ch(100, 200))
    assert spans(book_chapters(answer)) == [(1, 0, 100000), (2, 100000, 200000)]


def test_the_book_starts_at_zero_even_if_the_first_chapter_is_marked_later():
    answer = probe(ch(5, 100, "A"), ch(100, 200, "B"))
    assert book_chapters(answer) == [
        Chapter(1, 0, 100000, "A"),
        Chapter(2, 100000, 200000, "B"),
    ]


def test_the_last_chapter_ends_at_the_latest_end_seen():
    # Enclosing "wrapper chapter" over the entire file must not shorten the book.
    answer = probe(ch(0, 900, "Вся книга"), ch(300, 600, "Середина"))
    assert spans(book_chapters(answer)) == [(1, 0, 300000), (2, 300000, 900000)]


def test_two_chapters_from_the_same_place_keep_the_first():
    answer = probe(
        ch(0, 100, "A"), ch(100, 200, "B"), ch(100, 250, "B2"), ch(250, 300, "C")
    )
    assert [c.title for c in book_chapters(answer)] == ["A", "B", "C"]
    assert spans(book_chapters(answer))[-1] == (3, 250000, 300000)


# --- file duration -------------------------------------------------------


def test_a_known_file_length_ends_the_last_chapter():
    answer = probe(ch(0, 100), ch(100, 200))
    assert spans(book_chapters(answer, duration_ms=230_000))[-1] == (2, 100000, 230000)
    assert spans(book_chapters(answer, duration_ms=180_000))[-1] == (2, 100000, 180000)


def test_chapters_past_the_end_of_the_file_are_dropped():
    answer = probe(
        ch(0, 100, "A"), ch(100, 200, "B"), ch(200, 300, "C"), ch(300, 400, "D")
    )
    chapters = book_chapters(answer, duration_ms=200_000)
    assert [c.title for c in chapters] == ["A", "B"]
    assert spans(chapters) == [(1, 0, 100000), (2, 100000, 200000)]


def test_a_file_too_short_for_two_chapters_has_none():
    answer = probe(ch(0, 100), ch(100, 200))
    assert book_chapters(answer, duration_ms=100_000) == []
    assert book_chapters(answer, duration_ms=100_001) != []


@pytest.mark.parametrize(
    "length", [None, 0, -5, True, "230000", 230000.0, MAX_FILE_MS + 1]
)
def test_a_strange_file_length_is_ignored(length):
    answer = probe(ch(0, 100), ch(100, 200))
    assert spans(book_chapters(answer, duration_ms=length)) == [
        (1, 0, 100000),
        (2, 100000, 200000),
    ]


def test_the_longest_allowed_file_length_counts():
    answer = probe(ch(0, 100), ch(100, 200))
    assert book_chapters(answer, duration_ms=MAX_FILE_MS)[-1].end_ms == MAX_FILE_MS


# --- when there are no chapters ------------------------------------------


@pytest.mark.parametrize(
    "answer",
    [
        None,
        5,
        "chapters",
        [],
        {},
        {"chapters": None},
        {"chapters": "0-100"},
        {"chapters": 5},
        {"chapters": True},
        {"chapters": {"0": ch(0, 100)}},
        {"chapters": []},
        {"streams": [ch(0, 100), ch(100, 200)]},
    ],
)
def test_an_answer_without_chapters_gives_none(answer):
    assert book_chapters(answer) == []


def test_one_chapter_is_the_whole_file_so_there_are_none():
    assert book_chapters(probe(ch(0, 3600, "Вся книга"))) == []


def test_one_good_chapter_among_broken_ones_is_none():
    answer = probe(ch(0, 100), ch("nope", 200), None, "x", 7)
    assert book_chapters(answer) == []


def test_exactly_the_limit_is_still_chapters_and_one_more_is_none():
    def many(count: int) -> dict[str, Any]:
        return probe(*[ch(n, n + 1) for n in range(count)])

    assert len(book_chapters(many(MAX_CHAPTERS))) == MAX_CHAPTERS
    assert book_chapters(many(MAX_CHAPTERS + 1)) == []


def test_the_limit_counts_what_ffprobe_sent_not_what_survived():
    broken = [ch("nope", 1) for _ in range(MAX_CHAPTERS)]
    assert book_chapters(probe(ch(0, 100), ch(100, 200), *broken[:-2])) != []
    assert book_chapters(probe(ch(0, 100), ch(100, 200), *broken)) == []


# --- broken chapters -----------------------------------------------------


@pytest.mark.parametrize(
    "bad",
    [
        None,
        "глава",
        5,
        ["0", "100"],
        {},
        ch(100, 100),
        ch(150, 120),
        ch(-5, 100),
        ch("nan", 150),
        ch(120, "inf"),
        ch("-inf", 150),
        ch("", 150, start=None, time_base=None),
        ch("12,5", 150, start=None),
        ch("١٢٠", 150, start=None),
        ch("1" * 41, 150, start=None),
        ch(120, 30 * 24 * 3600 + 1),
        ch(True, 150, start=True),
        ch(None, 150, start=None),
        ch(None, None, start=120000, end=150000, time_base=None),
        ch(None, None, start=120000, end=150000, time_base="1000"),
        ch(None, None, start=120000, end=150000, time_base="1/0"),
        ch(None, None, start=120000, end=150000, time_base="0/1000"),
        ch(None, None, start=120000, end=150000, time_base="a/b"),
        ch(None, None, start=120000, end=150000, time_base="-1/1000"),
        ch(None, None, start=120000, end=150000, time_base="1/" + "9" * 13),
        ch(None, None, start="120000", end=150000),
        ch(None, None, start=120000.0, end=150000),
        ch(None, None, start=10**19, end=10**19 + 5),
        # Numbers where ordinary arithmetic crashes rather than miscalculating.
        ch(None, None, start=10**400, end=10**400 + 5),
        ch(None, None, start=120000, end=150000, time_base="9" * 400 + "/1"),
        ch(None, None, start=120000, end=150000, time_base="1/" + "9" * 5000),
        ch("9" * 5000, 150, start=None),
    ],
)
def test_a_broken_chapter_is_skipped_and_the_rest_stay(bad):
    answer = probe(ch(0, 100, "A"), bad, ch(200, 300, "B"))
    assert book_chapters(answer) == [
        Chapter(1, 0, 200000, "A"),
        Chapter(2, 200000, 300000, "B"),
    ]


def test_time_falls_back_to_ticks_when_there_are_no_seconds():
    answer = probe(
        {"time_base": "1/44100", "start": 0, "end": 4_410_000},
        {"time_base": "1/44100", "start": 4_410_000, "end": 8_820_000},
        {"time_base": " 1/1000 ", "start": 200_000, "end": 260_500},
    )
    assert spans(book_chapters(answer)) == [
        (1, 0, 100000),
        (2, 100000, 200000),
        (3, 200000, 260500),
    ]


def test_seconds_win_over_ticks():
    answer = probe(
        ch(0, 100),
        {
            "time_base": "1/1000",
            "start": 999_000,
            "end": 999_999,
            "start_time": "100.0",
            "end_time": "200.0",
        },
    )
    assert spans(book_chapters(answer)) == [(1, 0, 100000), (2, 100000, 200000)]


def test_seconds_may_come_as_numbers():
    answer = probe(
        {"start_time": 0, "end_time": 100.5},
        {"start_time": 100.5, "end_time": 200},
    )
    assert spans(book_chapters(answer)) == [(1, 0, 100500), (2, 100500, 200000)]


# --- titles ----------------------------------------------------------------


def test_titles_are_cleaned():
    answer = probe(
        ch(0, 100, "  Глава \n\t первая\x00\x07  "),
        ch(100, 200, "Г" * (MAX_CHAPTER_TITLE + 30)),
        ch(200, 300, "Д" * (MAX_CHAPTER_TITLE - 1) + " хвост"),
    )
    titles = [c.title for c in book_chapters(answer)]
    assert titles == [
        "Глава первая",
        "Г" * MAX_CHAPTER_TITLE,
        "Д" * (MAX_CHAPTER_TITLE - 1),
    ]


@pytest.mark.parametrize(
    "tags",
    [
        None,
        "Глава",
        5,
        [],
        {},
        {"title": None},
        {"title": 5},
        {"title": ["Глава"]},
        {"artist": "Чтец"},
    ],
)
def test_a_chapter_without_a_usable_title_has_an_empty_one(tags):
    answer = probe(ch(0, 100, tags=tags), ch(100, 200, tags=tags))
    assert [c.title for c in book_chapters(answer)] == ["", ""]


@pytest.mark.parametrize("key", ["title", "TITLE", "Title"])
def test_the_title_tag_is_found_in_any_case(key):
    answer = probe(ch(0, 100, tags={key: "A"}), ch(100, 200, tags={5: "x", key: "B"}))
    assert [c.title for c in book_chapters(answer)] == ["A", "B"]


# --- privacy contract and volume -----------------------------------------


def test_nothing_is_logged(caplog):
    with caplog.at_level("DEBUG"):
        book_chapters(
            probe(
                ch(0, 100, "Тайная глава"), ch("nope", 1, "Тайная битая"), ch(100, 200)
            )
        )
        book_chapters({"chapters": "Тайная строка"})
    assert caplog.text == ""


def test_the_module_keeps_to_the_standard_library():
    source = open(module.__file__, encoding="utf-8").read()
    for word in ("import logging", "subprocess", "asyncpg", "httpx", "print("):
        assert word not in source


def test_three_thousand_chapters_are_fast():
    answer = probe(
        *[ch(n * 60, n * 60 + 60, f"Глава {n}") for n in reversed(range(MAX_CHAPTERS))]
    )
    started = time.perf_counter()
    chapters = book_chapters(answer)
    assert time.perf_counter() - started < 1.0
    assert len(chapters) == MAX_CHAPTERS
    assert chapters[0].title == "Глава 0" and chapters[-1].number == MAX_CHAPTERS
