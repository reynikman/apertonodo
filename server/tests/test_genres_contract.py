"""Genres in the extension contract match the core genres (FT-748, FT-594a).

A `GET /v1/catalog` dump row may carry `genre`: the extension translates its section to a word from
`contracts/genres.txt`. Core builds genre screens using `GENRE_NAMES`; if they diverge, the genre silently disappears.
"""

from __future__ import annotations

from pathlib import Path

from app.genres import GENRE_NAMES

ROOT = Path(__file__).resolve().parents[2]


def test_contract_genres_are_the_core_genres_in_order() -> None:
    lines = (ROOT / "contracts" / "genres.txt").read_text(encoding="utf-8").splitlines()
    words = [line for line in lines if line and not line.startswith("#")]
    assert words == list(GENRE_NAMES)


def test_contract_names_the_genre_list_and_has() -> None:
    text = (ROOT / "contracts" / "extension-api.md").read_text(encoding="utf-8")
    assert "contracts/genres.txt" in text
    assert "POST /v1/has" in text
