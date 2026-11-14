"""FT-686: alternate alphabet spelling for fallback search."""

from __future__ import annotations

import inspect
import time

import pytest

from app import translit
from app.translit import MAX_TEXT, MAX_VARIANTS, MIN_LETTERS, variants


def test_constants() -> None:
    assert (MAX_VARIANTS, MIN_LETTERS, MAX_TEXT) == (8, 2, 200)


@pytest.mark.parametrize(
    ("text", "first"),
    [
        ("zemfira", "земфира"),
        ("kino", "кино"),
        ("Земфира", "zemfira"),
        ("Кино", "kino"),
        ("ЛЮБЭ", "lyube"),
        ("bi-2", "би-2"),
        ("би 2", "bi 2"),
        ("khleb", "хлеб"),
        ("shchuka", "щука"),
        ("zhuki", "жуки"),
        ("chaif", "чаиф"),
        ("Чайф", "chayf"),
        ("splin", "сплин"),
        ("Сплин", "splin"),
        ("Алиса", "alisa"),
        ("  Мумий   Тролль ", "mumiy troll"),
        ("max", "макс"),
        ("Щука", "schuka"),
        ("Пьер", "per"),
        ("Объект", "obekt"),
        ("Хор", "hor"),
    ],
)
def test_the_usual_spelling_comes_first(text: str, first: str) -> None:
    assert variants(text)[0] == first


def test_letters_with_several_spellings() -> None:
    assert variants("Йорш") == ["yorsh", "jorsh", "iorsh"]
    assert variants("Ёлка") == ["elka", "yolka"]
    assert variants("Ёж") == ["ezh", "yozh"]
    assert variants("Цой") == ["tsoy", "tsoj", "tsoi", "coy", "coj", "coi"]
    assert variants("cello") == ["келло", "кэлло", "целло", "цэлло"]
    assert variants("yuri") == ["юри"]
    assert variants("jaguar") == ["ягуар"]
    assert variants("xyz") == ["ксыз", "ксйз", "ксиз"]


def test_at_most_eight_unique_and_never_the_input() -> None:
    for text in ("Йорш Цой Ёлка Хор Щука", "yeye yeye yeye", "cecece", "Бьюик"):
        found = variants(text)
        assert 1 <= len(found) <= MAX_VARIANTS
        assert len(set(found)) == len(found)
        assert " ".join(text.lower().split()) not in found
    assert len(variants("Йорш Цой Ёлка Хор Щука")) == 8


def test_same_answer_every_time() -> None:
    assert variants("Цой Йорш") == variants("Цой Йорш")


def test_spaces_and_case_are_folded_first() -> None:
    assert variants("  KINO  ") == variants("kino")
    assert variants("Мумий\tТролль") == variants("мумий тролль")


@pytest.mark.parametrize(
    "text",
    [
        "",
        "   ",
        "я",
        "a",
        "a 1",
        "1234",
        "!!!",
        "Metallica кино",
        "kinoкино",
        "ΑΒΓΔ",
        "メタリカ",
        "x" * (MAX_TEXT + 1),
        None,
        5,
        b"kino",
        ["kino"],
    ],
)
def test_nothing_to_transliterate(text: object) -> None:
    assert variants(text) == []


def test_two_letters_are_enough_and_digits_do_not_count() -> None:
    # "Bi-2": two letters is already a name; one letter ("Ya") is noise.
    assert variants("Би-2") == ["bi-2"]
    assert variants("ab") == ["аб"]
    assert variants("a1") == []
    assert variants("я 2") == []
    assert variants("x" * MAX_TEXT) != []


def test_other_characters_stay_as_they_are() -> None:
    assert variants("ac/dc") == ["ак/дк", "ак/дц", "ац/дк", "ац/дц"]
    assert variants("Ночные снайперы 2")[0] == "nochnye snaypery 2"
    assert variants("kino ü")[0] == "кино ü"


def test_a_long_name_is_fast() -> None:
    started = time.perf_counter()
    for _ in range(200):
        variants("йцх" * 60)
        variants("yce" * 66)
    assert time.perf_counter() - started < 1.0


def test_module_is_pure() -> None:
    source = inspect.getsource(translit)
    for word in ("logging", "print(", "asyncpg", "httpx", "open("):
        assert word not in source
