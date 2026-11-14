"""FT-687: podcast language from the feed's `<language>` field."""

from __future__ import annotations

import inspect

import pytest

from app import podcast_lang
from app.podcast_lang import MAX_RAW, NAMES, THREE_LETTER, language_of


def test_constants() -> None:
    assert MAX_RAW == 35
    assert (
        THREE_LETTER["rus"] == "ru"
        and THREE_LETTER["ger"] == "de"
        and THREE_LETTER["chi"] == "zh"
    )
    assert len(THREE_LETTER) == 28
    assert NAMES["русский"] == "ru" and len(NAMES) == 10
    assert all(len(code) == 2 for code in (*THREE_LETTER.values(), *NAMES.values()))


@pytest.mark.parametrize(
    ("raw", "code"),
    [
        ("en", "en"),
        ("EN", "en"),
        ("en-us", "en"),
        ("en-US", "en"),
        ("ru-RU", "ru"),
        ("pt_BR", "pt"),
        ("  de \n", "de"),
        ("zh-Hant-TW", "zh"),
        ("xx", "xx"),
        ("rus", "ru"),
        ("RUS", "ru"),
        ("eng-GB", "en"),
        ("fre", "fr"),
        ("kaz", "kk"),
        ("English", "en"),
        (" russian ", "ru"),
        ("Русский", "ru"),
        ("английский", "en"),
    ],
)
def test_known_language(raw: str, code: str) -> None:
    assert language_of(raw) == code


@pytest.mark.parametrize(
    "raw",
    [
        "",
        "   ",
        "e",
        "e-us",
        "abc",
        "xyz-US",
        "engl",
        "english-us",
        "Klingon",
        "en us",
        "e1",
        "12",
        "-en",
        "_ru",
        "i-klingon",
        "x-pig-latin",
        "ру",
        "en" + "-a" * 17,
        None,
        5,
        b"en",
        ["en"],
    ],
)
def test_unknown_gives_nothing(raw: object) -> None:
    assert language_of(raw) is None


def test_length_limit_is_exact() -> None:
    assert language_of("en-" + "a" * (MAX_RAW - 3)) == "en"
    assert language_of("en-" + "a" * (MAX_RAW - 2)) is None


def test_module_is_pure() -> None:
    source = inspect.getsource(podcast_lang)
    for word in ("logging", "print(", "asyncpg", "httpx", "open("):
        assert word not in source
