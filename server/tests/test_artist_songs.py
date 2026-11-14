"""All popular songs of an artist (FT-553) — on real PostgreSQL.

Artist page shows top five songs, arrow opens modal with
all of them. What is guarded here:

1. Crawler stores up to `TOP_STORED` (50) top songs, not ten; artist
   page still returns at most `TOP_TRACKS` (10).
2. `GET /v1/artist/songs` — entire saved top in Last.fm order, same
   rows as page's `top_tracks` (id, `playable`), from own table:
   zero requests to Last.fm. Shape — `contracts/catalog-artist-songs.response.json`.
3. Rows saved with smaller cap are refetched by crawler once,
   not on every pass.

Fixtures and fake Last.fm — from test_lastfm.py.
"""

from __future__ import annotations

import asyncio
import json
from typing import Any

import pytest
from fastapi.testclient import TestClient
from test_catalog_browse import FORBIDDEN, SONGS, _shape, built, db  # noqa: F401
from test_lastfm import (  # noqa: F401
    CONTRACTS,
    LASTFM,
    FakeLastFm,
    FakeMb,
    _app_with,
    _clear,
    _put_loads,
    _robot,
    _rows,
    _take_loads,
    crawled,
)

from app import lastfm

MANY = [f"Song Number {n}" for n in range(1, 61)]


def _crawl(url: str, fake: FakeLastFm) -> None:
    # Like in `crawled` fixture: tracks via MusicBrainz, copy is hidden.
    loads = asyncio.run(_take_loads(url))
    try:
        asyncio.run(_robot(url, fake, mb_client=FakeMb().client).crawl())
    finally:
        asyncio.run(_put_loads(url, loads))


@pytest.fixture
def long_top(built: str, monkeypatch: pytest.MonkeyPatch) -> str:  # noqa: F811
    """Glass Harbor has 60 songs in Last.fm: three real ones first, then fake ones."""
    tracks = [{"name": name} for name in ["Low Tide", "Hidden Song", "Paper Crown", *MANY]]
    monkeypatch.setitem(
        LASTFM,
        ("artist.gettoptracks", "Glass Harbor"),
        {"toptracks": {"track": tracks, "@attr": {"artist": "Glass Harbor"}}},
    )
    asyncio.run(_clear(built))
    _crawl(built, FakeLastFm())
    return built


def _songs(client: TestClient, name: str) -> Any:
    response = client.get("/v1/artist/songs", params={"name": name})
    assert response.status_code == 200, response.text
    return response.json()


# --- 1. how many stored ------------------------------------------------------


def test_robot_keeps_fifty_songs_and_the_page_still_ten(long_top: str) -> None:
    assert lastfm.TOP_STORED == 50
    top = asyncio.run(_rows(long_top))["glass harbor"]["top_tracks"]
    assert list(top) == ["Low Tide", "Hidden Song", "Paper Crown", *MANY[:47]]
    with TestClient(_app_with(long_top, _robot(long_top, FakeLastFm()))) as client:
        page = client.get("/v1/artist", params={"name": "Glass Harbor"}).json()
    assert [row["title"] for row in page["top_tracks"]] == list(top[: lastfm.TOP_TRACKS])


def test_robot_asks_lastfm_for_enough_songs(built: str) -> None:  # noqa: F811
    asyncio.run(_clear(built))
    fake = FakeLastFm()
    _crawl(built, fake)
    asked = [call for call in fake.calls if call["method"] == "artist.gettoptracks"]
    assert asked
    assert all(int(call["limit"]) >= lastfm.TOP_STORED for call in asked)


# --- 2. "all songs" window ----------------------------------------------------


def test_songs_are_the_whole_top_in_order(long_top: str) -> None:
    fake = FakeLastFm()
    with TestClient(_app_with(long_top, _robot(long_top, fake))) as client:
        page = client.get("/v1/artist", params={"name": "Glass Harbor"}).json()
        songs = _songs(client, "Glass Harbor")
    assert fake.calls == []
    tracks = songs["tracks"]
    assert len(tracks) == lastfm.TOP_STORED
    assert [row["title"] for row in tracks[:3]] == ["Low Tide", "Hidden Song", "Paper Crown"]
    # Same rows as on page: studio recording id and "playable".
    assert tracks[: lastfm.TOP_TRACKS] == page["top_tracks"]
    assert tracks[0]["id"] == SONGS["Low Tide"]
    assert (tracks[1]["playable"], tracks[2]["playable"]) == (False, True)
    # Fake songs are not in any release.
    assert not any(row["playable"] for row in tracks[3:])


def test_songs_match_contract_and_say_nothing_about_releases(crawled: str) -> None:  # noqa: F811
    with TestClient(_app_with(crawled, _robot(crawled, FakeLastFm()))) as client:
        response = client.get("/v1/artist/songs", params={"name": "glass harbor"})
    assert response.status_code == 200
    for word in FORBIDDEN:
        assert word not in response.text.casefold(), word
    contract = json.loads((CONTRACTS / "catalog-artist-songs.response.json").read_text())
    answer = response.json()
    assert list(answer) == list(contract)
    assert _shape(answer) == _shape(contract)


def test_unknown_artist_and_no_key_give_an_empty_list(crawled: str) -> None:  # noqa: F811
    with TestClient(_app_with(crawled, _robot(crawled, FakeLastFm()))) as client:
        assert _songs(client, "Velvet Orchard") == {"tracks": []}
    with TestClient(_app_with(crawled, None)) as client:
        assert _songs(client, "Glass Harbor") == {"tracks": []}


# --- 3. old rows ---------------------------------------------------------


def test_rows_saved_with_a_smaller_cap_are_refetched_once(
    built: str,  # noqa: F811
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    asyncio.run(_clear(built))
    monkeypatch.setattr(lastfm, "TOP_STORED", 3)
    _crawl(built, FakeLastFm())
    monkeypatch.setattr(lastfm, "TOP_STORED", 50)

    again = FakeLastFm()
    _crawl(built, again)
    assert "Glass Harbor" in again.artists()

    third = FakeLastFm()
    _crawl(built, third)
    assert third.calls == []
