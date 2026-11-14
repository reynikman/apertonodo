"""Import refusals and default list names follow the phone language (FT-826, P9).

The app shows the server text of an import refusal as is. An old app sends no
`accept-language` and keeps getting Russian; a phone that says anything but Russian
gets English.
"""

# Fixtures `db`/`prepared_db` come from test_library.py through test_imports.py:
# pytest finds a fixture by the imported name.
# ruff: noqa: F401, F811

from __future__ import annotations

import ast
import re
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient

from app import import_messages
from test_imports import _b64, catalog
from test_library import _client, db, prepared_db

CYRILLIC = re.compile("[Ѐ-ӿ]")
APP = Path(__file__).resolve().parents[1] / "app"
IMPORT_MODULES = ("import_formats.py", "imports.py", "import_xspf.py")

TOO_MANY = "\n".join(f"Band {i} - Song {i}" for i in range(10_001))
REFUSALS = [
    ("big.txt", b"a" * (10 * 1024 * 1024 + 1), 413, "too_large"),
    ("Liked_Songs.csv", "Song,Singer\nLithium,Nirvana\n", 422, "bad_columns"),
    (None, " \n\n ", 422, "empty"),
    (None, TOO_MANY, 422, "too_many_rows"),
]
NO_SONGS = "В файле нет песен."


def _post(client: TestClient, name: str | None, data: bytes | str, lang: str | None) -> Any:
    headers = {} if lang is None else {"accept-language": lang}
    return client.post("/v1/imports", json={"name": name, "data": _b64(data)}, headers=headers)


def _raised_messages() -> set[str]:
    """Every text an import module puts into ImportFormatError."""
    found: set[str] = set()
    for name in IMPORT_MODULES:
        for node in ast.walk(ast.parse((APP / name).read_text())):
            if (
                isinstance(node, ast.Call)
                and getattr(node.func, "id", "") == "ImportFormatError"
                and len(node.args) == 2
                and isinstance(node.args[1], ast.Constant)
            ):
                found.add(node.args[1].value)
    return found


def test_every_refusal_has_an_english_text() -> None:
    raised = _raised_messages()
    assert len(raised) >= 20, "the scan found too few refusals: it no longer sees them"
    missing = sorted(raised - set(import_messages.MESSAGES))
    assert not missing, missing
    for russian, english in import_messages.MESSAGES.items():
        assert CYRILLIC.search(russian), russian
        assert english.strip() and not CYRILLIC.search(english), english


@pytest.mark.parametrize(
    ("header", "russian"),
    [
        (None, True),
        ("", True),
        ("ru", True),
        ("ru-RU,ru;q=0.9,en;q=0.8", True),
        ("en", False),
        ("en-US,en;q=0.9,ru;q=0.5", False),
        ("de-DE", False),
    ],
)
def test_language_is_chosen_by_the_first_language_of_the_header(
    header: str | None, russian: bool
) -> None:
    text = import_messages.localized(NO_SONGS, header)
    assert text == (NO_SONGS if russian else import_messages.MESSAGES[NO_SONGS]), header
    assert bool(CYRILLIC.search(text)) is russian, (header, text)


def test_unknown_text_is_returned_as_is() -> None:
    assert import_messages.localized("нет такого текста", "en") == "нет такого текста"


@pytest.mark.real_auth
def test_refusals_come_in_english_to_an_english_phone(catalog: str) -> None:
    client = _client(catalog)
    for name, data, status, code in REFUSALS:
        answer = _post(client, name, data, "en-GB,en;q=0.9")
        assert answer.status_code == status, code
        assert answer.json()["status"] == code
        message = answer.json()["message"]
        assert message and not CYRILLIC.search(message), (code, message)
    broken = client.post(
        "/v1/imports",
        json={"name": "x.csv", "data": "%%% not base64 %%%"},
        headers={"accept-language": "en"},
    )
    assert broken.status_code == 422
    assert broken.json()["message"] and not CYRILLIC.search(broken.json()["message"])


@pytest.mark.real_auth
def test_old_app_and_russian_phone_keep_russian(catalog: str) -> None:
    client = _client(catalog)
    for lang in (None, "ru-RU"):
        for name, data, status, code in REFUSALS:
            answer = _post(client, name, data, lang)
            assert answer.status_code == status, code
            assert CYRILLIC.search(answer.json()["message"]), (lang, code)


@pytest.mark.real_auth
def test_default_list_name_follows_the_language(catalog: str) -> None:
    client = _client(catalog)
    song = "Metallica - Enter Sandman"
    english = _post(client, None, song, "en").json()
    assert [row["name"] for row in english["lists"]] == ["Import"]
    for lang in (None, "ru"):
        russian = _post(client, None, song, lang).json()
        assert [row["name"] for row in russian["lists"]] == ["Импорт"], lang
    named = _post(client, "Road_Trip.txt", song, "en").json()
    assert [row["name"] for row in named["lists"]] == ["Road Trip"]
