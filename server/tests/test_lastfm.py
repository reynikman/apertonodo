"""Last.fm for artist page (Phase F2) — on real PostgreSQL.

What is guarded here and why:

1. Privacy. Opening artist page — zero requests to Last.fm:
   blocks are read from own table. Only the robot queries Last.fm, across all
   popular artists in the catalog sequentially, in order of popularity. It is woken
   by browsing catalog, not by opening artist page. The second test prevents
   "fixing" the first by turning off the robot entirely — as in test_search_is_free.py.
2. No key — no robot and no blocks, even if table is full.
3. Similar — only those present in catalog (i.e. playable); top songs — with
   `playable` according to catalog rules. Bio — without HTML and links.
4. Pace, Last.fm conditions and log: pause between requests, key failure or rate limit
   stops the crawl; neither key nor names appear in the log.

Last.fm responses — in their JSON API format, artists are fictitious (as in
test_catalog_browse.py). No network needed: httpx.MockTransport instead of Last.fm.
"""

from __future__ import annotations

import asyncio
import json
import logging
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs
from uuid import UUID

import asyncpg
import httpx
import pytest
from fastapi.testclient import TestClient
from test_catalog_browse import (  # noqa: F401
    FORBIDDEN,
    SONGS,
    FakeMusicBrainz,
    _app,
    _credit,
    _shape,
    _wait,
    built,
    db,
)

from app import lastfm
from app.lastfm import LastFm, clean_bio, studio_recording

KEY = "lastfm-test-key-" + "7" * 16
CONTRACTS = Path(__file__).resolve().parents[2] / "contracts"

BIO = (
    'Glass Harbor is a rock band from <b>Oslo</b> &amp; Bergen. They pirated their first demo '
    "via a torrent site. See https://example.org/glass for more. "
    '<a href="https://www.last.fm/music/Glass+Harbor">Read more on Last.fm</a>'
)

# Last.fm responses by (method, artist). Format — as in ws.audioscrobbler.com.
LASTFM: dict[tuple[str, ...], dict[str, Any]] = {
    ("artist.getinfo", "Glass Harbor"): {
        "artist": {
            "name": "Glass Harbor",
            "image": [{"#text": "https://lastfm.freetls.fastly.net/i/u/34s/x.png", "size": "small"}],
            "stats": {"listeners": "1200", "playcount": "34000"},
            "bio": {"summary": BIO, "content": BIO + " User-contributed text is available under CC BY-SA."},
            "tags": {
                "tag": [
                    {"name": "indie", "url": "https://www.last.fm/tag/indie"},
                    {"name": "rock", "url": "https://www.last.fm/tag/rock"},
                ]
            },
        }
    },
    ("artist.getsimilar", "Glass Harbor"): {
        "similarartists": {
            "artist": [
                {"name": "Nowhere Band", "match": "1"},  # not in catalog
                {"name": "Velvet Orchard", "match": "0.9"},
                {"name": "Dead Lantern", "match": "0.8"},  # torrent is dead
                {"name": "glass harbor", "match": "0.7"},  # itself
                {"name": "Ржавый ключ", "match": "0.6"},  # in catalog as "Ржавый Ключ"
            ],
            "@attr": {"artist": "Glass Harbor"},
        }
    },
    ("artist.gettoptracks", "Glass Harbor"): {
        "toptracks": {
            "track": [
                {"name": "Low Tide", "playcount": "900", "@attr": {"rank": "1"}},
                {"name": "Hidden Song", "playcount": "800", "@attr": {"rank": "2"}},
                {"name": "low tide", "playcount": "700", "@attr": {"rank": "3"}},
                {"name": "Paper Crown", "playcount": "600", "@attr": {"rank": "4"}},
            ],
            "@attr": {"artist": "Glass Harbor", "page": "1", "total": "4"},
        }
    },
}
# No Russian bio: Last.fm returns a single link, English bio is separate.
LASTFM[("artist.getinfo", "Édith Glow", "ru")] = {
    "artist": {"name": "Édith Glow", "bio": {"summary": ' <a href="https://www.last.fm/music/x">Read more on Last.fm</a>'}}
}
LASTFM[("artist.getinfo", "Édith Glow")] = {
    "artist": {"name": "Édith Glow", "bio": {"summary": "Édith Glow is a singer from Lyon."}}
}
UNKNOWN = {"error": 6, "message": "The artist you supplied could not be found", "links": []}


def _mb_rec(
    title: str,
    rec_id: str,
    *,
    length: int = 240000,
    isrc: bool = True,
    live: bool = False,
    video: bool = False,
) -> dict[str, Any]:
    group = {"primary-type": "Album", "secondary-types": ["Live"] if live else []}
    return {
        "id": rec_id,
        "title": title,
        "length": length,
        "isrcs": ["USUM71100001"] if isrc else [],
        "video": True if video else None,
        "disambiguation": "live, 2008" if live else None,
        "artist-credit": _credit("Glass Harbor"),
        "releases": [{"status": "Official", "title": "Low Tide", "release-group": group}],
    }


MB_TOP = {
    "recordings": [
        _mb_rec("Low Tide", SONGS["Low Tide"]),
        _mb_rec("Hidden Song", SONGS["Hidden Song"]),
        _mb_rec("Paper Crown", SONGS["Paper Crown"]),
        _mb_rec("Low Tide", "aaaaaaaa-0000-4000-8000-000000000001", length=90000, isrc=False),
        _mb_rec("Low Tide", "bbbbbbbb-0000-4000-8000-000000000002", length=600000, live=True),
    ]
}


class FakeMb:
    """MusicBrainz for Last.fm robot: returns same response, counts requests."""

    def __init__(self, payload: dict[str, Any] | None = None) -> None:
        self.calls = 0
        self.payload = payload or MB_TOP

    def client(self) -> httpx.Client:
        def handler(request: httpx.Request) -> httpx.Response:
            self.calls += 1
            return httpx.Response(200, json=self.payload)

        return httpx.Client(transport=httpx.MockTransport(handler))


class FakeLastFm:
    """Last.fm that responds from `LASTFM` and records what was requested."""

    def __init__(self, fail_on: str | None = None) -> None:
        self.calls: list[dict[str, str]] = []
        self.fail_on = fail_on

    def handler(self, request: httpx.Request) -> httpx.Response:
        params = {key: values[0] for key, values in parse_qs(request.url.query.decode()).items()}
        self.calls.append(params)
        if self.fail_on == "connect":
            raise httpx.ConnectError(f"cannot reach {request.url}", request=request)
        if self.fail_on == "limit":
            return httpx.Response(429, json={"error": 29, "message": "Rate limit exceeded"})
        if self.fail_on == "http":
            return httpx.Response(502, text="<html>bad gateway</html>")
        wanted = (params["method"], params["artist"])
        payload = LASTFM.get((*wanted, params.get("lang", "")), LASTFM.get(wanted, UNKNOWN))
        return httpx.Response(200, json=payload)

    def client(self) -> httpx.Client:
        return httpx.Client(transport=httpx.MockTransport(self.handler))

    def artists(self) -> list[str]:
        return list(dict.fromkeys(call["artist"] for call in self.calls))


def _robot(url: str, fake: FakeLastFm, **kwargs: Any) -> LastFm:
    return LastFm(KEY, url, client=fake.client, pause_s=0, **kwargs)


async def _rows(url: str) -> dict[str, Any]:
    conn = await asyncpg.connect(url)
    try:
        return {row["artist_key"]: dict(row) for row in await conn.fetch("SELECT * FROM lastfm_artists")}
    finally:
        await conn.close()


@pytest.fixture
def crawled(built: str) -> str:  # noqa: F811
    asyncio.run(_clear(built))
    # Robot here is tested via MusicBrainz path. Catalog fixture
    # publishes a copy (mb_loads row), and robot uses it to fetch ids from own
    # copy (FT-025, test_local_search) — hide the row during crawl.
    loads = asyncio.run(_take_loads(built))
    try:
        asyncio.run(_robot(built, FakeLastFm(), mb_client=FakeMb().client).crawl())
    finally:
        asyncio.run(_put_loads(built, loads))
    return built


async def _take_loads(url: str) -> list[asyncpg.Record]:
    conn = await asyncpg.connect(url)
    try:
        return await conn.fetch("DELETE FROM mb_loads RETURNING dump_date, row_counts, duration_ms")
    finally:
        await conn.close()


async def _put_loads(url: str, rows: list[asyncpg.Record]) -> None:
    conn = await asyncpg.connect(url)
    try:
        await conn.executemany(
            "INSERT INTO mb_loads (dump_date, row_counts, duration_ms) VALUES ($1, $2, $3)",
            [tuple(row) for row in rows],
        )
    finally:
        await conn.close()


async def _clear(url: str) -> None:
    conn = await asyncpg.connect(url)
    try:
        await conn.execute("DELETE FROM lastfm_artists")
    finally:
        await conn.close()


def _app_with(url: str, robot: LastFm | None) -> Any:
    app = _app(url, FakeMusicBrainz())
    app.state.lastfm = robot
    return app


# --- 1. privacy -------------------------------------------------------------


def test_artist_page_never_asks_lastfm(crawled: str) -> None:
    fake = FakeLastFm()
    mb = FakeMusicBrainz()
    app = _app(crawled, mb)
    app.state.lastfm = _robot(crawled, fake)
    with TestClient(app) as client:
        body = client.get("/v1/artist", params={"name": "Glass Harbor"}).json()
        robot = client.app.state.lastfm
    # Blocks present — means data came from own table.
    assert body["top_tracks"] and body["similar"] and body["bio"]
    # Exactly zero, and robot not woken: crawl timestamp does not reveal what was opened.
    assert fake.calls == [], f"artist page went to Last.fm {len(fake.calls)} time(s)"
    assert robot.thread is None
    assert all("/recording" not in url for url, _params in mb.calls)


def test_browsing_the_catalog_wakes_the_robot(built: str) -> None:  # noqa: F811
    """Positive control: robot is alive and woken by genres, not disabled."""
    asyncio.run(_clear(built))
    fake = FakeLastFm()
    with TestClient(_app_with(built, _robot(built, fake))) as client:
        client.get("/v1/genres")
        robot = client.app.state.lastfm
        _wait(lambda: robot.thread is not None and not robot.thread.is_alive())
    assert fake.artists(), "browsing catalog must wake the robot"


def test_robot_walks_popular_artists_in_catalog_order(built: str) -> None:  # noqa: F811
    """Order — catalog popularity, not what was opened; and only top N."""
    asyncio.run(_clear(built))
    fake = FakeLastFm()
    saved, unknown = asyncio.run(_robot(built, fake, limit=3).crawl())
    # Seeders: Glass Harbor 30+5+7 (disc image doesn't count), Velvet Orchard
    # 50+2, Ржавый Ключ 10, Édith Glow 3; Dead Lantern is dead and not in catalog.
    assert fake.artists() == ["Velvet Orchard", "Glass Harbor", "Ржавый Ключ"]
    assert (saved, unknown) == (3, 2)
    # Unknown to Last.fm — one query, known — three.
    assert len(fake.calls) == 1 + 3 + 1
    assert {call["api_key"] for call in fake.calls} == {KEY}
    # Second crawl does not query fresh data again.
    again = FakeLastFm()
    assert asyncio.run(_robot(built, again, limit=3).crawl()) == (0, 0)
    assert again.calls == []


def test_robot_revisits_rows_saved_before_top_track_ids(crawled: str) -> None:
    """Row before migration 018 (NULL ids) — into queue immediately, not via REFRESH."""
    asyncio.run(_forget_ids(crawled, "glass harbor"))
    fake = FakeLastFm()
    asyncio.run(_robot(crawled, fake, mb_client=FakeMb().client).crawl())
    assert fake.artists() == ["Glass Harbor"]
    assert asyncio.run(_rows(crawled))["glass harbor"]["top_track_ids"] is not None


async def _forget_ids(url: str, key: str) -> None:
    conn = await asyncpg.connect(url)
    try:
        await conn.execute("UPDATE lastfm_artists SET top_track_ids = NULL WHERE artist_key = $1", key)
    finally:
        await conn.close()


async def _photo(url: str, key: str) -> None:
    conn = await asyncpg.connect(url)
    try:
        await conn.execute(
            "INSERT INTO artist_photos (artist_key, mbid, path, author, license) "
            "VALUES ($1, $2, 'p.jpg', 'Author', 'CC BY-SA 4.0') ON CONFLICT (artist_key) DO NOTHING",
            key,
            UUID(int=7),
        )
    finally:
        await conn.close()


# --- 2. without key -------------------------------------------------------


def test_without_key_there_are_no_blocks_and_no_robot(crawled: str) -> None:
    with TestClient(_app(crawled, FakeMusicBrainz())) as client:
        assert client.app.state.lastfm is None
        client.get("/v1/genres")
        body = client.get("/v1/artist", params={"name": "Glass Harbor"}).json()
    assert body["albums"]
    assert not {"top_tracks", "similar", "bio"} & set(body)


# --- 3. block contents ----------------------------------------------------


def test_blocks_show_only_what_plays(crawled: str) -> None:
    asyncio.run(_photo(crawled, "velvet orchard"))
    with TestClient(_app_with(crawled, _robot(crawled, FakeLastFm()))) as client:
        body = client.get("/v1/artist", params={"name": "Glass Harbor"}).json()
        velvet = client.get("/v1/artist", params={"name": "Velvet Orchard"}).json()
    # Similar: only from catalog, keeping its spelling; dead, foreign, or self are excluded.
    # With photo, like in genre list (finding 30.09: similar previously had only letters).
    assert body["similar"] == [
        {"name": "Velvet Orchard", "photo": f"/v1/photos/{UUID(int=7)}"},
        {"name": "Ржавый Ключ", "photo": None},
    ]
    # Top: no duplicates; "Hidden Song" is not in any release.
    assert [(row["title"], row["playable"]) for row in body["top_tracks"]] == [
        ("Low Tide", True),
        ("Hidden Song", False),
        ("Paper Crown", True),
    ]
    # ID is the studio recording that the crawler saved to the table.
    assert body["top_tracks"][0]["id"] == SONGS["Low Tide"]
    assert body["top_tracks"][0]["duration_ms"] == 240000
    assert body["top_tracks"][2]["id"] == SONGS["Paper Crown"]
    # Last.fm does not know the artist: no blocks, page remains the same.
    assert velvet.get("status") != "catalog_unavailable"
    assert not {"top_tracks", "similar", "bio"} & set(velvet)


def test_studio_recording_skips_live_demo_and_short_without_isrc() -> None:
    payload = {
        "recordings": [
            _mb_rec("Low Tide", "11111111-1111-4111-8111-111111111111", length=90000, isrc=False),
            _mb_rec("Low Tide", "22222222-2222-4222-8222-222222222222", length=600000, live=True),
            _mb_rec("Low Tide", SONGS["Low Tide"], length=240000, isrc=True),
            _mb_rec("Low Tide (Live)", "33333333-3333-4333-8333-333333333333", length=240000),
            _mb_rec("Low Tide", "44444444-4444-4444-8444-444444444444", length=240000, video=True),
        ]
    }
    track = studio_recording(payload, "Low Tide")
    assert track is not None
    assert track["id"] == SONGS["Low Tide"]
    assert track["duration_ms"] == 240000


def test_top_track_id_is_known_to_playback(crawled: str) -> None:
    """Pressing Play on a top track ID: server recognizes the song (not 404)."""
    with TestClient(_app_with(crawled, _robot(crawled, FakeLastFm()))) as client:
        body = client.get("/v1/artist", params={"name": "Glass Harbor"}).json()
        track_id = body["top_tracks"][0]["id"]
        play = client.post("/v1/playback", json={"track_id": track_id})
    assert play.status_code == 409, play.text


def test_top_remaster_rows_fold_into_the_song(crawled: str) -> None:
    """"My Sweet Lord (2014 Remaster)" by George Harrison was an unlinked entry, and clicking it redirected
    to search. An entry stored before the rule: suffix trimmed, duplicate removed, ID found in local copy."""
    low_tide = SONGS["Low Tide"]

    async def old_row(add: bool) -> None:
        conn = await asyncpg.connect(crawled)
        try:
            if not add:
                await conn.execute("DELETE FROM song_version WHERE recording_mbid = $1::uuid", low_tide)
                await conn.execute("DELETE FROM song WHERE original_recording_mbid = $1::uuid", low_tide)
                return
            await conn.execute(
                "UPDATE lastfm_artists SET top_tracks = $2, top_track_ids = $3 WHERE artist_key = $1",
                "glass harbor",
                ["Paper Crown", "Low Tide (2014 Remaster)", "Paper Crown - Remastered 2011"],
                json.dumps({"paper crown": {"id": SONGS["Paper Crown"], "duration_ms": 240000}}),
            )
            song = await conn.fetchval(
                "INSERT INTO song (artist_mbid, title, original_recording_mbid) "
                "SELECT mbid, 'Low Tide', $1::uuid FROM mb_artist WHERE name = 'Glass Harbor' RETURNING id",
                low_tide,
            )
            await conn.execute(
                "INSERT INTO song_version (song_id, recording_mbid, kind, year) VALUES ($1, $2::uuid, 'original', 2004)",
                song, low_tide,
            )
        finally:
            await conn.close()

    asyncio.run(old_row(True))
    try:
        with TestClient(_app_with(crawled, _robot(crawled, FakeLastFm()))) as client:
            body = client.get("/v1/artist", params={"name": "Glass Harbor"}).json()
    finally:
        asyncio.run(old_row(False))
    assert [(row["title"], row.get("id"), row["playable"]) for row in body["top_tracks"]] == [
        ("Paper Crown", SONGS["Paper Crown"], True),
        ("Low Tide", low_tide, True),
    ]


def test_robot_keeps_top_titles_without_remaster_tail() -> None:
    robot = LastFm(KEY, "postgresql://unused", pause_s=0)

    def answer(request: httpx.Request) -> httpx.Response:
        method = request.url.params["method"]
        if method == "artist.gettoptracks":
            names = ["My Sweet Lord", "My Sweet Lord (2014 Remaster)", "What Is Life - Remastered 2014", "Wah-Wah"]
            return httpx.Response(200, json={"toptracks": {"track": [{"name": n} for n in names]}})
        if method == "artist.getinfo":
            return httpx.Response(200, json={"artist": {"name": "George Harrison", "bio": {"summary": "Bio."}}})
        return httpx.Response(200, json={})

    with httpx.Client(transport=httpx.MockTransport(answer)) as client:
        _found, _bio, top, *_rest = robot.fetch(client, "George Harrison")
    assert top == ["My Sweet Lord", "What Is Life", "Wah-Wah"]


def test_artist_outside_the_crawl_has_no_blocks(built: str) -> None:  # noqa: F811
    asyncio.run(_clear(built))
    asyncio.run(_robot(built, FakeLastFm(), limit=1).crawl())
    with TestClient(_app_with(built, _robot(built, FakeLastFm()))) as client:
        body = client.get("/v1/artist", params={"name": "Glass Harbor"}).json()
    assert body["albums"]
    assert not {"top_tracks", "similar", "bio"} & set(body)


def test_bio_is_short_plain_text(crawled: str) -> None:
    bio = asyncio.run(_rows(crawled))["glass harbor"]["bio"]
    assert bio == "Glass Harbor is a rock band from Oslo & Bergen."
    long = clean_bio(("A sentence here. " * 80) + '<a href="https://x">Read more on Last.fm</a>')
    assert long is not None and len(long) <= lastfm.BIO_CHARS and long.endswith(".")
    assert clean_bio('<a href="https://www.last.fm/music/X">Read more on Last.fm</a>') is None


def test_bio_never_ends_mid_word() -> None:
    # Last.fm's own summary stops mid-sentence (Depeche Mode, 30.09): the full text wins.
    info = {"artist": {"bio": {
        "summary": 'Группа из Бэзилдона. Эта группа создала собственный <a href="https://www.last.fm/music/x">Read more on Last.fm</a>',
        "content": "Группа из Бэзилдона. Эта группа создала собственный стиль. User-contributed text is available under CC BY-SA.",
    }}}
    assert lastfm._bio(info) == "Группа из Бэзилдона. Эта группа создала собственный стиль."
    # Only a truncated summary, as stored before the fix: served up to the last whole sentence.
    assert lastfm.whole_sentences("Группа из Бэзилдона. Эта группа создала собственный") == "Группа из Бэзилдона."
    assert len(lastfm.whole_sentences("Длинное предложение без конца " * 40)) <= lastfm.BIO_CHARS + 1


def test_bio_falls_back_to_english_when_russian_is_empty(crawled: str) -> None:
    rows = {row["bio"] for row in asyncio.run(_rows(crawled)).values()}
    assert "Édith Glow is a singer from Lyon." in rows


RECORDED = Path(__file__).resolve().parent / "fixtures" / "lastfm"
# Real responses from ws.audioscrobbler.com, captured on 2026-09-19 via home egress.
RECORDED_FILES = {
    ("artist.getinfo", "Metallica", "ru"): "metallica-getinfo-ru",
    ("artist.getsimilar", "Metallica", ""): "metallica-getsimilar",
    ("artist.gettoptracks", "Metallica", ""): "metallica-gettoptracks",
    ("artist.getinfo", "Arkadia", "ru"): "arkadia-getinfo-ru",
    ("artist.getinfo", "Arkadia", ""): "arkadia-getinfo",
}


def test_recorded_answers_give_short_russian_bio_and_clean_lists() -> None:
    calls: list[tuple[str, str, str]] = []

    def answer(request: httpx.Request) -> httpx.Response:
        params = request.url.params
        wanted = (params["method"], params["artist"], params.get("lang", ""))
        calls.append(wanted)
        name = RECORDED_FILES.get(wanted, "unknown-getinfo-ru")
        return httpx.Response(200, content=(RECORDED / f"{name}.json").read_bytes())

    robot = LastFm(KEY, "postgresql://unused", pause_s=0)
    with httpx.Client(transport=httpx.MockTransport(answer)) as client:
        found, bio, top, similar, listeners, tags = robot.fetch(client, "Metallica")
        namesakes = robot.fetch(client, "Arkadia")
        unknown = robot.fetch(client, "Qzxv Nonexistent Band 7731")
    assert found and bio is not None
    assert bio.startswith("Metallica — американская") and len(bio) <= lastfm.BIO_CHARS
    assert "<" not in bio and "http" not in bio and "Read more" not in bio
    assert top[:4] == ["Enter Sandman", "Nothing Else Matters", "Master of Puppets", "One"]
    assert len(top) == lastfm.TOP_TRACKS
    assert similar[:3] == ["Megadeth", "Slayer", "Pantera"] and len(similar) == 30
    # Namesakes: no Russian bio; English "There are multiple artists…" is not a biography.
    assert namesakes[0] and namesakes[1] is None
    assert unknown == (False, None, [], [], None, [])
    assert "metal" in tags and "http" not in "".join(tags)
    # Listeners are extracted from the same response as bio: no extra request.
    assert isinstance(listeners, int) and listeners > 0
    assert calls.count(("artist.getinfo", "Arkadia", "")) == 1


def test_only_needed_fields_are_kept(crawled: str) -> None:
    """Neither images, links, nor play counts are kept.

    One number is kept intentionally — how many people listen to the artist
    (`listeners`): it makes up half of the search ranking weight (owner decision
    from 2026-09-20). Everything else Last.fm returns in that response remains
    on Last.fm: images, links, and `playcount` (34000 for Glass Harbor).
    """
    rows = asyncio.run(_rows(crawled))
    text = json.dumps(rows, default=str)
    for word in ("http", "fastly", "image", "34000", "playcount"):
        assert word not in text, word
    assert rows["glass harbor"]["listeners"] == 1200
    assert list(rows["glass harbor"]["tags"]) == ["indie", "rock"]


def test_blocks_have_no_words_about_releases_and_match_contract(crawled: str) -> None:
    with TestClient(_app_with(crawled, _robot(crawled, FakeLastFm()))) as client:
        response = client.get("/v1/artist", params={"name": "Glass Harbor"})
    for word in FORBIDDEN:
        assert word not in response.text.casefold(), word
    # Cover was not fetched in this test (`cover: null`); its schema is guarded by contract.
    contract = json.loads((CONTRACTS / "catalog-artist-lastfm.response.json").read_text())
    answer = response.json()
    assert list(answer) == list(contract)
    for block in ("top_tracks", "similar", "bio"):
        assert _shape(answer[block]) == _shape(contract[block]), block


# --- 4. pace, failures, and log ------------------------------------------


def test_robot_keeps_the_pace(built: str, monkeypatch: pytest.MonkeyPatch) -> None:  # noqa: F811
    asyncio.run(_clear(built))
    pauses: list[float] = []
    monkeypatch.setattr(lastfm.time, "sleep", pauses.append)
    fake = FakeLastFm()
    asyncio.run(LastFm(KEY, built, client=fake.client, limit=2).crawl())
    assert len(pauses) == len(fake.calls) > 0
    assert min(pauses) >= 1.0


@pytest.mark.parametrize("fail_on", ["limit", "connect", "http"])
def test_refusal_stops_the_crawl_without_saving(
    built: str, fail_on: str, caplog: pytest.LogCaptureFixture  # noqa: F811
) -> None:
    asyncio.run(_clear(built))
    caplog.set_level(logging.DEBUG)
    fake = FakeLastFm(fail_on=fail_on)
    assert asyncio.run(_robot(built, fake).crawl()) == (0, 0)
    # Rate limit or network error: stop asking, failure not recorded as "unknown".
    assert len(fake.calls) == 1
    assert asyncio.run(_rows(built)) == {}
    assert "lastfm: stopped after 0 artists" in caplog.text
    assert KEY not in caplog.text


def test_log_has_no_key_and_no_names(built: str, caplog: pytest.LogCaptureFixture) -> None:  # noqa: F811
    asyncio.run(_clear(built))
    caplog.set_level(logging.DEBUG)
    with TestClient(_app_with(built, _robot(built, FakeLastFm()))) as client:
        client.get("/v1/genres")
        robot = client.app.state.lastfm
        _wait(lambda: robot.thread is not None and not robot.thread.is_alive())
        client.get("/v1/artist", params={"name": "Glass Harbor"})
    text = caplog.text
    # Positive control: crawler log line is present.
    assert "lastfm: 4 artists in" in text
    assert KEY not in text and "api_key" not in text and "audioscrobbler" not in text
    for name in ("glass", "harbor", "velvet", "ржавый", "low tide"):
        assert name not in text.casefold(), name
