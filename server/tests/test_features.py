"""FT-800: телефон узнаёт, что на этом сервере настроено, одним запросом.

Книги настроены, когда у сервера есть хоть одно расширение книг; подкасты —
когда включён живой справочник (`PODCASTS_LIVE=1`). Без этого плитка
в приложении открывала бы экран, который отвечает одним «недоступно».
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.guard import API_KEY_HEADER
from app.main import create_app

ROOT = Path(__file__).resolve().parents[2]
CATALOG = json.loads((ROOT / "contracts" / "fixtures" / "catalog.json").read_text())["tracks"]
KEY = "features-test-key-" + "x" * 20
AUTH = {API_KEY_HEADER.decode(): KEY}


def _client(**extra: object) -> TestClient:
    return TestClient(create_app(database_url=None, catalog=CATALOG, api_key=KEY, **extra))


def test_nothing_configured_says_so() -> None:
    response = _client(book_extensions={}).get("/v1/features", headers=AUTH)
    assert response.status_code == 200
    assert response.json() == {"books": False, "podcasts": False}


def test_book_extension_turns_books_on() -> None:
    client = _client(book_extensions={"bt-books": "http://books.invalid:8080"})
    assert client.get("/v1/features", headers=AUTH).json() == {
        "books": True,
        "podcasts": False,
    }


def test_live_directory_turns_podcasts_on(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("PODCASTS_LIVE", "1")
    with _client(book_extensions={}) as client:
        assert client.get("/v1/features", headers=AUTH).json() == {
            "books": False,
            "podcasts": True,
        }


def test_answer_is_closed_without_a_key() -> None:
    """Белый список открытых путей не растёт: что настроено — не для прохожего."""
    response = _client(book_extensions={}).get("/v1/features")
    assert response.status_code == 401


def test_answer_names_no_addresses() -> None:
    client = _client(book_extensions={"bt-books": "http://books.invalid:8080"})
    text = client.get("/v1/features", headers=AUTH).text
    assert "books.invalid" not in text and "bt-books" not in text


def test_contract_example_matches() -> None:
    example = json.loads((ROOT / "contracts" / "features.response.json").read_text())
    assert set(example) == {"books", "podcasts"}
    assert all(isinstance(value, bool) for value in example.values())
