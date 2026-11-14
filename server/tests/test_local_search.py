"""Tests for FT-025 local search: search, suggestions, robot top tracks, and indexes."""

from __future__ import annotations

import json
import tempfile
from pathlib import Path
from typing import Any
from uuid import UUID

import asyncpg
import httpx
import pytest

import app.catalog_songs as catalog_songs
import app.local_search as local_search
import app.mbcopy as mbcopy
from app.lastfm import LastFm
from app.migrate import apply
from app.musicbrainz import MetadataCache, MusicBrainzCatalog, MusicBrainzClient
from tests.test_mbcopy import pack_dump


class ExplodingHttpClient:
    async def get_json(self, url: str, params: dict[str, str]) -> dict[str, Any]:
        raise AssertionError(f"unexpected HTTP request to {url}")


class FakeRecordingHttpClient:
    def __init__(self, recordings: list[dict[str, Any]]) -> None:
        self.recordings, self.calls = recordings, 0

    async def get_json(self, url: str, params: dict[str, str]) -> dict[str, Any]:
        self.calls += 1
        return {"recordings": self.recordings}


class CountingConnection:
    def __init__(self, conn: asyncpg.Connection) -> None:
        self._conn, self.total_fetched = conn, 0

    def __getattr__(self, name: str) -> Any:
        return getattr(self._conn, name)

    async def fetch(self, query: str, *args: Any, **kwargs: Any) -> list[Any]:
        rows = await self._conn.fetch(query, *args, **kwargs)
        self.total_fetched += len(rows)
        return rows

    def transaction(self, *args: Any, **kwargs: Any) -> Any:
        return self._conn.transaction(*args, **kwargs)


@pytest.fixture(autouse=True)
async def cleanup_db(postgres_url: str):
    await apply(postgres_url)
    for i in range(2):
        conn = await asyncpg.connect(postgres_url)
        try:
            await conn.execute("TRUNCATE mb_loads, artist_photos, song, mb_artist, lastfm_artists, catalog_artists CASCADE")
        finally:
            await conn.close()
        if i == 0:
            yield


async def _seed_local_deep_song(url: str) -> dict[str, Any]:
    oasis, deep_rec = UUID(int=1), UUID(int=101)
    conn = await asyncpg.connect(url)
    try:
        await conn.execute("INSERT INTO mb_artist (mbid, name, sort_name, ended) VALUES ($1, 'Oasis', 'Oasis', false) ON CONFLICT DO NOTHING", oasis)
        song_id = await conn.fetchval("INSERT INTO song (artist_mbid, title, original_recording_mbid) VALUES ($1, 'B-side Only', $2) RETURNING id", oasis, deep_rec)
        await conn.execute("INSERT INTO mb_recording (mbid, artist_mbid, title, length_ms) VALUES ($1, $2, 'B-side Only', 180000) ON CONFLICT DO NOTHING", deep_rec, oasis)
        await conn.execute("INSERT INTO song_version (song_id, recording_mbid, kind, year) VALUES ($1, $2, 'original', 1995) ON CONFLICT DO NOTHING", song_id, deep_rec)
        await conn.execute("INSERT INTO catalog_artists (genre, artist_key, name, letter, popularity) VALUES ('rock', 'oasis', 'Oasis', 'O', 100) ON CONFLICT DO NOTHING")
        await conn.execute("INSERT INTO lastfm_artists (artist_key, found, top_tracks) VALUES ('oasis', true, ARRAY['Wonderwall']) ON CONFLICT DO NOTHING")
        return {"oasis": oasis, "song_id": song_id, "deep_rec": deep_rec}
    finally:
        await conn.close()


async def test_published_copy_search_answers_deep_song_locally_without_network(postgres_url: str) -> None:
    conn = await asyncpg.connect(postgres_url)
    try:
        await conn.execute("INSERT INTO mb_loads (dump_date, replication_sequence, row_counts, duration_ms, tablespace, size_bytes) VALUES ('2026-09-19', 189107, '{}'::jsonb, 100, 'pg_default', 1000)")
    finally:
        await conn.close()

    ids = await _seed_local_deep_song(postgres_url)
    port = MusicBrainzCatalog(MusicBrainzClient(http=ExplodingHttpClient(), cache=MetadataCache()), database_url=postgres_url)
    results = await port.search("B-side Only", limit=20)
    assert len(results) == 1
    track = results[0]
    assert "song_id" not in track and track["id"] == str(ids["deep_rec"])
    assert set(track.keys()) == {"id", "title", "artist", "duration_ms", "artwork_url"}
    assert track["title"] == "B-side Only" and track["artist"] == "Oasis" and track["duration_ms"] == 180000


async def test_unpublished_copy_search_falls_back_to_old_way(postgres_url: str) -> None:
    fake_rec = {"id": "11111111-1111-1111-1111-111111111111", "title": "Enter Sandman", "artist-credit": [{"name": "Metallica"}], "length": 331000, "score": 100}
    fake_http = FakeRecordingHttpClient([fake_rec])
    port = MusicBrainzCatalog(MusicBrainzClient(http=fake_http, cache=MetadataCache()), database_url=postgres_url)
    results = await port.search("enter sandman", limit=10)
    assert fake_http.calls > 0 and len(results) == 1
    assert results[0]["id"] == "11111111-1111-1111-1111-111111111111" and results[0]["title"] == "Enter Sandman" and results[0]["artist"] == "Metallica"


async def test_robot_with_published_copy_resolves_top_track_ids_locally(postgres_url: str) -> None:
    metal, sandman = UUID(int=2), UUID(int=201)
    conn = await asyncpg.connect(postgres_url)
    try:
        await conn.execute("INSERT INTO mb_loads (dump_date, replication_sequence, row_counts, duration_ms, tablespace, size_bytes) VALUES ('2026-09-19', 189107, '{}'::jsonb, 100, 'pg_default', 1000) ON CONFLICT DO NOTHING")
        await conn.execute("INSERT INTO mb_artist (mbid, name, sort_name, ended) VALUES ($1, 'Metallica', 'Metallica', false) ON CONFLICT DO NOTHING", metal)
        s_id = await conn.fetchval("INSERT INTO song (artist_mbid, title, original_recording_mbid) VALUES ($1, 'Enter Sandman', $2) RETURNING id", metal, sandman)
        await conn.execute("INSERT INTO mb_recording (mbid, artist_mbid, title, length_ms) VALUES ($1, $2, 'Enter Sandman', 330000) ON CONFLICT DO NOTHING", sandman, metal)
        await conn.execute("INSERT INTO song_version (song_id, recording_mbid, kind, year) VALUES ($1, $2, 'original', 1991) ON CONFLICT DO NOTHING", s_id, sandman)
        await conn.execute("INSERT INTO catalog_artists (genre, artist_key, name, letter, popularity) VALUES ('metal', 'metallica', 'Metallica', 'M', 500) ON CONFLICT DO NOTHING")
    finally:
        await conn.close()

    def fake_lastfm_client() -> httpx.Client:
        def handler(req: httpx.Request) -> httpx.Response:
            m = dict(httpx.QueryParams(req.url.query)).get("method")
            if m == "artist.getinfo":
                return httpx.Response(200, json={"artist": {"name": "Metallica", "stats": {"listeners": "5000000"}, "bio": {"summary": "Metal."}, "tags": {"tag": []}}})
            if m == "artist.getsimilar":
                return httpx.Response(200, json={"similarartists": {"artist": []}})
            if m == "artist.gettoptracks":
                return httpx.Response(200, json={"toptracks": {"track": [{"name": "Enter Sandman"}]}})
            return httpx.Response(200, json={})
        return httpx.Client(transport=httpx.MockTransport(handler))

    robot = LastFm(api_key="test-key", database_url=postgres_url, client=fake_lastfm_client,
                   mb_client=lambda: (_ for _ in ()).throw(AssertionError("robot asked MusicBrainz HTTP")), pause_s=0, limit=5)
    saved, _ = await robot.crawl()
    assert saved >= 1
    conn = await asyncpg.connect(postgres_url)
    try:
        row = await conn.fetchrow("SELECT top_track_ids FROM lastfm_artists WHERE artist_key = 'metallica'")
        assert row is not None
        ids = json.loads(row["top_track_ids"]) if isinstance(row["top_track_ids"], str) else (row["top_track_ids"] or {})
        assert ids.get("enter sandman", {}).get("id") == str(sandman) and ids.get("enter sandman", {}).get("duration_ms") == 330000
    finally:
        await conn.close()


async def test_index_usage_on_all_local_search_queries(postgres_url: str, monkeypatch: pytest.MonkeyPatch) -> None:
    # In CI Postgres is another container: the loader must not stat its paths (see test_mbcopy).
    monkeypatch.setattr("app.mbcopy._free_bytes", lambda _path: 2**50)
    with tempfile.TemporaryDirectory() as tmp:
        dump_path = Path(tmp) / "mbdump.tar.bz2"
        pack_dump(dump_path)
        await mbcopy.load(postgres_url, files=[str(dump_path)], allow_main_volume=True)
        await catalog_songs.build(postgres_url)

    conn = await asyncpg.connect(postgres_url)
    try:
        await conn.execute("SET enable_seqscan = off")
        await conn.execute("SET plan_cache_mode = force_custom_plan")
        plan_search = "\n".join(r[0] for r in await conn.fetch("EXPLAIN " + local_search.SEARCH_CANDIDATES_SQL, "metallica", "metallica%", ["metallica"], ["one%"]))
        assert "Seq Scan on song" not in plan_search and "Seq Scan on mb_recording" not in plan_search and "Seq Scan on mb_artist" not in plan_search
        # The main path is btree only: a trigram recheck over millions of rows is what timed out on the real copy.
        for idx in ("song_title_lower", "mb_recording_new_title_lower", "mb_artist_new_name_lower", "mb_artist_alias_new_name_lower"):
            assert idx in plan_search, idx
        assert "trgm" not in plan_search

        plan_fuzzy = "\n".join(r[0] for r in await conn.fetch("EXPLAIN " + local_search.FUZZY_CANDIDATES_SQL, "metalica"))
        assert "song_title_trgm" in plan_fuzzy and "mb_artist_new_name_trgm" in plan_fuzzy

        plan_sug = "\n".join(r[0] for r in await conn.fetch("EXPLAIN " + local_search.SUGGEST_SQL, "Met%", 10))
        assert "Seq Scan on song" not in plan_sug and "Seq Scan on mb_recording" not in plan_sug and "Seq Scan on mb_artist" not in plan_sug

        plan_top = "\n".join(r[0] for r in await conn.fetch("EXPLAIN " + local_search.TOP_TRACKS_SQL, "Metallica", ["Enter Sandman"], ["enter sandman"], "Metallica", [], []))
        assert "Seq Scan on mb_recording" not in plan_top and "Seq Scan on mb_artist" not in plan_top
    finally:
        await conn.close()


async def test_row_budget_bounds_fetches_and_results(postgres_url: str) -> None:
    art1, art2 = UUID(int=50000), UUID(int=50001)
    conn = await asyncpg.connect(postgres_url)
    try:
        await conn.execute("INSERT INTO mb_artist (mbid, name, sort_name, ended) VALUES ($1, 'Budget Artist', 'Budget Artist', false)", art1)
        await conn.execute("INSERT INTO mb_artist (mbid, name, sort_name, ended) VALUES ($1, 'Prolific Artist', 'Prolific Artist', false)", art2)
        await conn.execute("INSERT INTO mb_recording (mbid, artist_mbid, title, length_ms) SELECT gen_random_uuid(), $1, 'Budget Track ' || i, 200000 FROM generate_series(1, 5000) AS i", art1)
        await conn.execute("INSERT INTO song (artist_mbid, title, original_recording_mbid) SELECT $1, 'Budget Song ' || i, gen_random_uuid() FROM generate_series(1, 5000) AS i", art1)
        await conn.execute("INSERT INTO song (artist_mbid, title, original_recording_mbid) SELECT $1, 'Prolific Song ' || i, gen_random_uuid() FROM generate_series(1, 2000) AS i", art2)

        wrapped = CountingConnection(conn)
        res_search = await local_search.search(wrapped, "Budget", limit=20)
        assert len(res_search) <= 20 and wrapped.total_fetched <= 500

        wrapped.total_fetched = 0
        res_artist = await local_search.search(wrapped, "Prolific Artist", limit=20)
        assert len(res_artist) <= 20 and wrapped.total_fetched <= 200

        wrapped.total_fetched = 0
        hints = await local_search.suggest(wrapped, "Bud", limit=10)
        assert len(hints) <= 10 and wrapped.total_fetched <= 500
    finally:
        await conn.close()


async def test_published_copy_local_search_error_never_falls_back_to_http(postgres_url: str, monkeypatch: pytest.MonkeyPatch) -> None:
    conn = await asyncpg.connect(postgres_url)
    try:
        await conn.execute("INSERT INTO mb_loads (dump_date, replication_sequence, row_counts, duration_ms, tablespace, size_bytes) VALUES ('2026-09-19', 189107, '{}'::jsonb, 100, 'pg_default', 1000) ON CONFLICT DO NOTHING")
    finally:
        await conn.close()

    fake_http = FakeRecordingHttpClient([{"id": "rec-1", "title": "Never Reached", "length": 200000, "artist-credit": [{"name": "Oasis"}]}])
    port = MusicBrainzCatalog(MusicBrainzClient(http=fake_http, cache=MetadataCache()), database_url=postgres_url)

    async def exploding_search(*args: Any, **kwargs: Any) -> list[dict[str, Any]]:
        raise RuntimeError("database timeout during search")

    monkeypatch.setattr(local_search, "search", exploding_search)
    with pytest.raises(RuntimeError):
        await port.search("Oasis", limit=10)
    assert fake_http.calls == 0


async def test_published_path_client_shape_and_duration_filter(postgres_url: str) -> None:
    conn = await asyncpg.connect(postgres_url)
    try:
        await conn.execute("INSERT INTO mb_loads (dump_date, replication_sequence, row_counts, duration_ms, tablespace, size_bytes) VALUES ('2026-09-19', 189107, '{}'::jsonb, 100, 'pg_default', 1000) ON CONFLICT DO NOTHING")
        art_id, rec_good, rec_zero = UUID(int=60000), UUID(int=60001), UUID(int=60002)
        await conn.execute("INSERT INTO mb_artist (mbid, name, sort_name, ended) VALUES ($1, 'Shape Artist', 'Shape Artist', false) ON CONFLICT DO NOTHING", art_id)
        await conn.execute("INSERT INTO mb_recording (mbid, artist_mbid, title, length_ms) VALUES ($1, $2, 'Shape Good', 210000) ON CONFLICT DO NOTHING", rec_good, art_id)
        await conn.execute("INSERT INTO mb_recording (mbid, artist_mbid, title, length_ms) VALUES ($1, $2, 'Shape Zero', 0) ON CONFLICT DO NOTHING", rec_zero, art_id)
        s1 = await conn.fetchval("INSERT INTO song (artist_mbid, title, original_recording_mbid) VALUES ($1, 'Shape Good', $2) RETURNING id", art_id, rec_good)
        s2 = await conn.fetchval("INSERT INTO song (artist_mbid, title, original_recording_mbid) VALUES ($1, 'Shape Zero', $2) RETURNING id", art_id, rec_zero)
        await conn.execute("INSERT INTO song_version (song_id, recording_mbid, kind, year) VALUES ($1, $2, 'original', 2020) ON CONFLICT DO NOTHING", s1, rec_good)
        await conn.execute("INSERT INTO song_version (song_id, recording_mbid, kind, year) VALUES ($1, $2, 'original', 2020) ON CONFLICT DO NOTHING", s2, rec_zero)
    finally:
        await conn.close()

    port = MusicBrainzCatalog(MusicBrainzClient(http=ExplodingHttpClient(), cache=MetadataCache()), database_url=postgres_url)
    results = await port.search("Shape", limit=10)
    assert len(results) == 1
    track = results[0]
    assert track["id"] == str(rec_good) and track["title"] == "Shape Good" and track["duration_ms"] == 210000
    assert "song_id" not in track and "artist_id" not in track
    assert set(track.keys()) == {"id", "title", "artist", "duration_ms", "artwork_url"}


async def test_query_with_wildcard_characters_matches_literal_only(postgres_url: str) -> None:
    art_id = UUID(int=70000)
    rec1, rec2, rec3, rec4 = UUID(int=70001), UUID(int=70002), UUID(int=70003), UUID(int=70004)
    conn = await asyncpg.connect(postgres_url)
    try:
        await conn.execute("INSERT INTO mb_artist (mbid, name, sort_name, ended) VALUES ($1, 'Wild Artist', 'Wild Artist', false) ON CONFLICT DO NOTHING", art_id)
        for rec, title in ((rec1, "100% Hits"), (rec2, "1000 Hits"), (rec3, "Track_One"), (rec4, "Track-One")):
            await conn.execute("INSERT INTO mb_recording (mbid, artist_mbid, title, length_ms) VALUES ($1, $2, $3, 200000) ON CONFLICT DO NOTHING", rec, art_id, title)
            s = await conn.fetchval("INSERT INTO song (artist_mbid, title, original_recording_mbid) VALUES ($1, $2, $3) RETURNING id", art_id, title, rec)
            await conn.execute("INSERT INTO song_version (song_id, recording_mbid, kind, year) VALUES ($1, $2, 'original', 2020) ON CONFLICT DO NOTHING", s, rec)

        res_percent = await local_search.search(conn, "100%", limit=10)
        assert any(t["title"] == "100% Hits" for t in res_percent) and not any(t["title"] == "1000 Hits" for t in res_percent)

        res_underscore = await local_search.search(conn, "Track_One", limit=10)
        assert any(t["title"] == "Track_One" for t in res_underscore) and not any(t["title"] == "Track-One" for t in res_underscore)

        sug_percent = await local_search.suggest(conn, "100%", limit=10)
        assert "100% Hits" in sug_percent and "1000 Hits" not in sug_percent

        sug_underscore = await local_search.suggest(conn, "Track_O", limit=10)
        assert "Track_One" in sug_underscore and "Track-One" not in sug_underscore
    finally:
        await conn.close()


async def test_search_candidates_avoids_fanout(postgres_url: str) -> None:
    conn = await asyncpg.connect(postgres_url)
    try:
        art_id = UUID(int=80000)
        await conn.execute("INSERT INTO mb_artist (mbid, name, sort_name, ended) VALUES ($1, 'Fanout Art', 'Fanout Art', false) ON CONFLICT DO NOTHING", art_id)
        await conn.execute("INSERT INTO mb_artist_alias (artist_mbid, name) SELECT $1, 'Fanout Alias ' || i FROM generate_series(1, 40) AS i", art_id)
        await conn.execute("INSERT INTO mb_recording (mbid, artist_mbid, title, length_ms) SELECT ('00000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid, $1, 'Fanout Song ' || i, 200000 FROM generate_series(80001, 80050) AS i ON CONFLICT DO NOTHING", art_id)
        await conn.execute("INSERT INTO song (artist_mbid, title, original_recording_mbid) SELECT $1, 'Fanout Song ' || i, ('00000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid FROM generate_series(80001, 80050) AS i", art_id)
        await conn.execute("""
            WITH pairs AS (
                SELECT s.id AS song_id, s.title, v.i AS v_idx, ('00000000-0000-0000-0001-' || lpad((s.id * 100 + v.i)::text, 12, '0'))::uuid AS rec_mbid
                FROM song s CROSS JOIN generate_series(1, 40) AS v(i) WHERE s.artist_mbid = $1
            ), ins_rec AS (
                INSERT INTO mb_recording (mbid, artist_mbid, title, length_ms) SELECT rec_mbid, $1, title || ' v' || v_idx, 200000 FROM pairs
            ) INSERT INTO song_version (song_id, recording_mbid, kind, year) SELECT song_id, rec_mbid, 'cover', 2021 FROM pairs
        """, art_id)
        res = await conn.fetchval(f"EXPLAIN (ANALYZE, FORMAT JSON) {local_search.SEARCH_CANDIDATES_SQL}", "fanout", "fanout%", ["fanout", "art"], ["art%", "fanout%"])
        def check_node(n: dict[str, Any]) -> None:
            assert int(n.get("Actual Rows", 0) * n.get("Actual Loops", 1)) <= 5000
            for child in n.get("Plans", []):
                check_node(child)
        check_node(json.loads(res)[0]["Plan"])
    finally:
        await conn.close()


async def test_top_track_ids_escapes_like_wildcard(postgres_url: str) -> None:
    conn = await asyncpg.connect(postgres_url)
    try:
        a1, a2, r1, r2 = UUID(int=91001), UUID(int=91002), UUID(int=92001), UUID(int=92002)
        await conn.execute("INSERT INTO mb_artist (mbid, name, sort_name, ended) VALUES ($1, 'A_B', 'A_B', false), ($2, 'AxB', 'AxB', false) ON CONFLICT DO NOTHING", a1, a2)
        await conn.execute("INSERT INTO mb_recording (mbid, artist_mbid, title, length_ms) VALUES ($1, $2, 'Wild Hit', 180000), ($3, $4, 'Wild Hit', 240000) ON CONFLICT DO NOTHING", r1, a1, r2, a2)
        s1 = await conn.fetchval("INSERT INTO song (artist_mbid, title, original_recording_mbid) VALUES ($1, 'Wild Hit', $2) RETURNING id", a1, r1)
        s2 = await conn.fetchval("INSERT INTO song (artist_mbid, title, original_recording_mbid) VALUES ($1, 'Wild Hit', $2) RETURNING id", a2, r2)
        await conn.execute("INSERT INTO song_version (song_id, recording_mbid, kind, year) VALUES ($1, $2, 'original', 2020), ($3, $4, 'original', 2020) ON CONFLICT DO NOTHING", s1, r1, s2, r2)
        res = await local_search.top_track_ids(conn, "A_B", ["Wild Hit"])
        assert res == {"wild hit": {"id": str(r1), "duration_ms": 180000}}
    finally:
        await conn.close()


async def _seed_artist_songs(url: str, artist: str, titles: list[str], alias: str | None = None) -> None:
    conn = await asyncpg.connect(url)
    try:
        art = await conn.fetchval("INSERT INTO mb_artist (mbid, name, sort_name, ended) VALUES (gen_random_uuid(), $1, $1, false) RETURNING mbid", artist)
        if alias:
            await conn.execute("INSERT INTO mb_artist_alias (artist_mbid, name) VALUES ($1, $2)", art, alias)
        for title in titles:
            rec = await conn.fetchval("INSERT INTO mb_recording (mbid, artist_mbid, title, length_ms) VALUES (gen_random_uuid(), $1, $2, 200000) RETURNING mbid", art, title)
            song = await conn.fetchval("INSERT INTO song (artist_mbid, title, original_recording_mbid) VALUES ($1, $2, $3) RETURNING id", art, title, rec)
            await conn.execute("INSERT INTO song_version (song_id, recording_mbid, kind, year) VALUES ($1, $2, 'original', 2004)", song, rec)
    finally:
        await conn.close()


async def test_artist_and_title_in_either_order(postgres_url: str) -> None:
    await _seed_artist_songs(postgres_url, "Slipknot", ["Duality", "Before I Forget"])
    await _seed_artist_songs(postgres_url, "Кино", ["Кукушка"], alias="Kino")
    await _seed_artist_songs(postgres_url, "Duality Tribute", ["Something Else"])
    conn = await asyncpg.connect(postgres_url)
    try:
        for query in ("slipknot duality", "Duality Slipknot", "slipknot before i", "kino кукушка", "Кукушка Кино"):
            hits = await local_search.search(conn, query, limit=5)
            assert hits and hits[0]["artist"] in ("Slipknot", "Кино"), (query, hits)
            assert hits[0]["title"] in ("Duality", "Before I Forget", "Кукушка"), (query, hits)
    finally:
        await conn.close()


async def test_typo_is_found_only_through_fuzzy_fallback(postgres_url: str) -> None:
    await _seed_artist_songs(postgres_url, "Oasis", ["Wonderwall"])
    conn = await asyncpg.connect(postgres_url)
    try:
        wrapped = CountingConnection(conn)
        assert [t["title"] for t in await local_search.search(wrapped, "Wondervall", limit=5)] == ["Wonderwall"]
        exact = await conn.fetch(local_search.SEARCH_CANDIDATES_SQL, "wondervall", "wondervall%", [], [])
        assert exact == []  # the exact path is prefix-only; the typo came from the fallback
    finally:
        await conn.close()


async def test_fuzzy_fallback_timeout_keeps_exact_answer(postgres_url: str, monkeypatch: pytest.MonkeyPatch) -> None:
    await _seed_artist_songs(postgres_url, "Oasis", ["Wonderwall"])
    monkeypatch.setattr(local_search, "FUZZY_CANDIDATES_SQL", "SELECT pg_sleep(5), $1::text")
    conn = await asyncpg.connect(postgres_url)
    try:
        assert [t["title"] for t in await local_search.search(conn, "wonderwall", limit=5)] == ["Wonderwall"]
        assert await conn.fetchval("SELECT 1") == 1  # the connection survived the cancelled savepoint
    finally:
        await conn.close()


async def test_search_indexes_builds_missing_once(postgres_url: str) -> None:
    from app import search_indexes

    conn = await asyncpg.connect(postgres_url)
    try:
        for name, _table, _expr in search_indexes.MB_INDEXES:
            await conn.execute(f"DROP INDEX IF EXISTS {name}")
        await conn.execute("DROP INDEX IF EXISTS song_title_lower")
        first = await search_indexes.ensure(conn)
        assert sorted(first) == sorted([n for n, _t, _e in search_indexes.MB_INDEXES] + ["song_title_lower"])
        assert await search_indexes.ensure(conn) == []
    finally:
        await conn.close()


async def test_artist_query_puts_lastfm_top_first(postgres_url: str) -> None:
    # 30.09 on production: "metallica" opened with "[instrumental jam]", the hits were further down.
    await _seed_artist_songs(postgres_url, "Metallica", ["[instrumental jam]", "Aaa Deep Cut", "One"])
    conn = await asyncpg.connect(postgres_url)
    try:
        one = await conn.fetchval("SELECT original_recording_mbid::text FROM song WHERE title = 'One'")
        await conn.execute(
            "INSERT INTO lastfm_artists (artist_key, found, top_track_ids) VALUES ('metallica', true, $1::jsonb)",
            json.dumps({"one": {"id": one, "duration_ms": 200000}}),
        )
        hits = await local_search.search(conn, "metallica", limit=5)
        assert hits[0]["title"] == "One" and hits[0]["duration_ms"] == 200000
    finally:
        await conn.close()
