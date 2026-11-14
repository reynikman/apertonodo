"""Lists by genre and by letter — only those known to Last.fm (Р-A73 item 7, FT-558).

Measurement on 04.10 on production: 173,516 artists with releases in lists, Last.fm
knows 18,885; the remaining ~152k are "nameless" rows not worth browsing.
Search and artist page still find anyone.

"Known" — a row in `lastfm_artists` with `found = true` (nightly robot, `app/lastfm.py`).
Not asked by robot and `found = false` — not known. If Last.fm knows no one
(robot not enabled: self-hosted server without Last.fm key) — lists stay as before.
Mark is updated by catalog build (`python -m app.catalog build`).
"""

from __future__ import annotations

import asyncio

import asyncpg
from fastapi.testclient import TestClient
from test_catalog_browse import _extension, _app, _seed

from app import search

KNOWN = ["Glass Harbor", "Velvet Orchard"]
NOT_FOUND = "Édith Glow"  # robot asked, Last.fm does not know
NEVER_ASKED = "Ржавый Ключ"  # robot did not ask


async def _lastfm(url: str, known: list[str], not_found: list[str]) -> None:
    conn = await asyncpg.connect(url)
    try:
        await conn.execute("DELETE FROM lastfm_artists")
        for name, found in [*((n, True) for n in known), *((n, False) for n in not_found)]:
            key = await conn.fetchval("SELECT artist_key FROM catalog_artists WHERE name = $1 LIMIT 1", name)
            assert key, name
            await conn.execute(
                "INSERT INTO lastfm_artists (artist_key, found, listeners) VALUES ($1, $2, $3)",
                key, found, 1000 if found else None,
            )
    finally:
        await conn.close()


def _built(url: str, known: list[str], not_found: list[str]) -> str:
    asyncio.run(_seed(url))
    asyncio.run(_extension().build_catalog(url))
    asyncio.run(_lastfm(url, known, not_found))
    asyncio.run(_extension().build_catalog(url))
    return url


def _names(client: TestClient, **params: str) -> tuple[list[str], int]:
    body = client.get("/v1/artists", params={**params, "limit": "500"}).json()
    return [item["name"] for item in body["artists"]], body["total"]


def _letters(client: TestClient, **params: str) -> dict[str, int]:
    rows = client.get("/v1/letters", params=params).json()["letters"]
    return {row["letter"]: row["artists"] for row in rows}


async def _search(url: str, query: str) -> list[str]:
    conn = await asyncpg.connect(url)
    try:
        return [row["name"] for row in await search.artists(conn, query)]
    finally:
        await conn.close()


def test_genre_lists_only_known(postgres_url: str) -> None:
    url = _built(postgres_url, KNOWN, [NOT_FOUND])
    with TestClient(_app(url)) as client:
        rock, total = _names(client, genre="rock")
        assert sorted(rock) == sorted(KNOWN)
        assert total == len(KNOWN)
        counts = {row["id"]: row["artists"] for row in client.get("/v1/genres").json()["genres"]}
        assert counts["rock"] == len(KNOWN)
        # Genre letters — only from known: "E" (Édith) and "Р" have no one in rock.
        letters = _letters(client, genre="rock")
        assert "E" not in letters and "Р" not in letters
        assert sum(letters.values()) == len(KNOWN)


def test_letter_and_alphabet_list_only_known(postgres_url: str) -> None:
    url = _built(postgres_url, KNOWN, [NOT_FOUND])
    with TestClient(_app(url)) as client:
        everyone, total = _names(client)
        assert NOT_FOUND not in everyone and NEVER_ASKED not in everyone
        assert set(KNOWN) <= set(everyone)
        assert total == len(everyone)
        assert _names(client, letter="E") == ([], 0)
        assert _names(client, letter="Р") == ([], 0)
        letters = _letters(client)
        assert "E" not in letters and "Р" not in letters


def test_search_and_page_still_find_anyone(postgres_url: str) -> None:
    url = _built(postgres_url, KNOWN, [NOT_FOUND])
    assert NOT_FOUND in asyncio.run(_search(url, "edith glow"))
    assert NEVER_ASKED in asyncio.run(_search(url, "ржавый ключ"))
    with TestClient(_app(url)) as client:
        for name in (NOT_FOUND, NEVER_ASKED):
            response = client.get("/v1/artist", params={"name": name})
            assert response.status_code == 200, name
            assert response.json()["artist"]["name"] == name


def test_without_lastfm_lists_stay_as_before(postgres_url: str) -> None:
    """Last.fm knows no one — robot not enabled; lists do not become empty."""
    url = _built(postgres_url, [], [NOT_FOUND])
    with TestClient(_app(url)) as client:
        rock, total = _names(client, genre="rock")
        assert {*KNOWN, NOT_FOUND, NEVER_ASKED} <= set(rock)
        assert total == len(rock)
        assert NOT_FOUND in _names(client, letter="E")[0]
