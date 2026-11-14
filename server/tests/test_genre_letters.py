"""Genre letter index: where each letter begins in the alphabetical list (FT-514, Р-A54).

Owner feedback 02.10 (J 14, option b): genre artists — alphabetical, Latin at
start, with a letter index on the side so in rock (38,843 names) one does not have to scroll to "K".
`/v1/letters?genre=<genre>` returns letters in list order; each has
how many artists start with it and what `offset` to use when opening it in
`/v1/artists?genre=<genre>`. Without `genre` — previous generic index.
"""

from __future__ import annotations

import json
from pathlib import Path

from fastapi.testclient import TestClient
from test_catalog_browse import _app
from test_genre_alphabet import EXPECTED, _built

from app import catalog
from app.names import norm

CONTRACT = Path(__file__).resolve().parents[2] / "contracts" / "catalog-genre-letters.response.json"

ROCK = [
    ("A", 1, 0),  # a-ha; Dead Lantern without release is excluded from the list (Р-A66)
    ("E", 2, 1),  # Édith Glow, Édith Piaf
    ("G", 1, 3),
    ("V", 1, 4),
    ("Z", 1, 5),
    ("А", 1, 6),  # Cyrillic
    ("Е", 1, 7),  # Yolka
    ("К", 1, 8),
    ("Р", 1, 9),
    ("#", 1, 10),  # 50 Cent
]


def _letters(client: TestClient, genre: str) -> list[dict]:
    response = client.get("/v1/letters", params={"genre": genre})
    assert response.status_code == 200
    return response.json()["letters"]


def test_rock_letters_point_into_the_alphabet(postgres_url: str) -> None:
    url = _built(postgres_url)
    with TestClient(_app(url)) as client:
        letters = _letters(client, "rock")
    assert [(row["letter"], row["artists"], row["offset"]) for row in letters] == ROCK
    assert sum(row["artists"] for row in letters) == len(EXPECTED)


def test_each_offset_opens_its_letter(postgres_url: str) -> None:
    """For both genre paths: replica ("rock") and old catalog ("classic-rock")."""
    url = _built(postgres_url)
    with TestClient(_app(url)) as client:
        for genre in ("rock", "classic-rock"):
            names = [
                item["name"]
                for item in client.get("/v1/artists", params={"genre": genre, "limit": 100}).json()["artists"]
            ]
            letters = _letters(client, genre)
            assert letters, genre
            assert sum(row["artists"] for row in letters) == len(names), genre
            for row in letters:
                first = names[row["offset"]]
                assert catalog.letter_of(norm(first)) == row["letter"] or row["letter"] == "#", (genre, row)
                if row["offset"]:
                    before = names[row["offset"] - 1]
                    assert catalog.letter_of(norm(before)) != row["letter"], (genre, row)


def test_unknown_genre_has_no_letters_and_plain_letters_stay(postgres_url: str) -> None:
    url = _built(postgres_url)
    with TestClient(_app(url)) as client:
        assert _letters(client, "no-such-genre") == []
        plain = client.get("/v1/letters").json()["letters"]
    assert plain and all(set(row) == {"letter", "artists"} for row in plain)


def test_contract_example_has_the_same_shape() -> None:
    example = json.loads(CONTRACT.read_text())
    assert [set(row) for row in example["letters"]] == [{"letter", "artists", "offset"}] * len(example["letters"])
