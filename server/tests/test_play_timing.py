"""FT-786 (И1а): each Play leaves one row of numbers — where time went and how it ended.

Owner 08.10: measurement first, then everything else about "faster and more reliable". Server log
answers "what happened to this press", but cannot compute weekly median. Table
`play_timing` — only numbers and outcome: track ID, extension name, milliseconds of stages from Play start,
outcome. Neither user, nor title, nor query text, nor address is in it — so it is not personal.

All milliseconds are measured from single start — receipt of `POST /v1/playback`:
`find_ms` (extensions answered) ≤ `prepare_ms` (file ready) ≤ `token_ms` (answer to phone) ≤
`first_byte_ms` (first bytes sent to phone) ≤ `first_256k_ms` (first 256 KB sent).

What tests do not prove: numbers in production and on real releases (report FT-788 after week of
listening); that row survives process restart between Play and sound (does not — stays
`waiting`, as intended); seeders and speed are FT-787 in extension.
"""

from __future__ import annotations

import asyncio
import re
import time
import uuid
from datetime import timedelta
from pathlib import Path
from typing import Any

import asyncpg
import pytest
from fake_extension import AUDIO, make_fake_extension, running_extension
from fastapi import FastAPI
from fastapi.testclient import TestClient
from test_play_failures import _stalling_extension

from app.main import create_app
from app.migrate import apply
from app.store import persist_tracks

ROOT = Path(__file__).resolve().parents[2]
COLUMNS = {
    "id", "at", "track_id", "source", "prepared",
    "find_ms", "prepare_ms", "token_ms", "first_byte_ms", "first_256k_ms", "outcome",
    # FT-787: what extension reported about swarm at ready time — three numbers and one word out of three.
    "peers", "speed_bps", "have_pct", "via",
}
BIG = "Nothing Else Matters"  # 540 KB — larger than 256 KB
SMALL = "Duality"  # 65 KB — smaller


def _track(title: str, artist: str) -> dict[str, Any]:
    return {"id": str(uuid.uuid4()), "title": title, "artist": artist, "duration_ms": 1, "artwork_url": ""}


def _prepare(url: str, track: dict[str, Any]) -> None:
    async def run() -> None:
        await apply(url)
        await persist_tracks(url, [track])

    asyncio.run(run())


def _sql(url: str, sql: str, *args: Any) -> list[dict[str, Any]]:
    async def run() -> list[dict[str, Any]]:
        conn = await asyncpg.connect(url)
        try:
            return [dict(row) for row in await conn.fetch(sql, *args)]
        finally:
            await conn.close()

    return asyncio.run(run())


def _rows(url: str, track: dict[str, Any]) -> list[dict[str, Any]]:
    return _sql(url, "SELECT * FROM play_timing WHERE track_id = $1 ORDER BY id", track["id"])


def _settled(url: str, track: dict[str, Any], outcome: str) -> dict[str, Any]:
    """Record is made outside of audio delivery path — wait up to 3 seconds for it."""
    deadline = time.monotonic() + 3
    rows: list[dict[str, Any]] = []
    while time.monotonic() < deadline:
        rows = _rows(url, track)
        if len(rows) == 1 and rows[0]["outcome"] == outcome:
            return rows[0]
        time.sleep(0.05)
    raise AssertionError(f"expected one row with outcome {outcome}, in database: {rows}")


def _client(url: str, track: dict[str, Any], extensions: dict[str, str]) -> TestClient:
    return TestClient(
        create_app(database_url=url, catalog=[track], extensions=extensions, playback_budget_s=5.0)
    )


def _refusing_extension() -> FastAPI:
    """Extension that confidently names file and cannot prepare it."""
    app = FastAPI()

    @app.get("/v1/info")
    def info() -> dict[str, Any]:
        return {"api": 1, "name": "refuse", "version": "0.1.0", "kind": "music", "features": []}

    @app.post("/v1/find")
    def find() -> dict[str, Any]:
        return {"items": [{"id": "one", "confidence": 0.9, "format": "mp3", "size": 1, "quality": "lossy"}]}

    @app.post("/v1/prepare")
    def prepare() -> dict[str, Any]:
        return {"state": "failed", "reason": "unavailable"}

    return app


def test_played_song_leaves_one_row_with_every_stage(postgres_url: str) -> None:
    track = _track(BIG, "Metallica")
    _prepare(postgres_url, track)
    with running_extension(make_fake_extension()) as ext, _client(postgres_url, track, {"fake": ext}) as client:
        played = client.post("/v1/playback", json={"track_id": track["id"]})
        assert played.status_code == 200, played.text
        token = played.json()["token"]
        assert client.get(f"/v1/stream/{token}").status_code == 200
        row = _settled(postgres_url, track, "played")
        # Seeking and repeated request of same token do not affect row: metric is for first audio.
        assert client.get(f"/v1/stream/{token}", headers={"Range": "bytes=1024-"}).status_code == 206
        time.sleep(0.3)
        assert _rows(postgres_url, track) == [row]

    assert row["source"] == "fake"
    assert row["prepared"] is False
    stages = [row[name] for name in ("find_ms", "prepare_ms", "token_ms", "first_byte_ms", "first_256k_ms")]
    assert all(isinstance(ms, int) and ms >= 0 for ms in stages), row
    assert stages == sorted(stages), f"stages are out of order: {row}"
    assert row["at"] is not None


def test_short_song_is_played_without_the_256k_mark(postgres_url: str) -> None:
    track = _track(SMALL, "Slipknot")
    _prepare(postgres_url, track)
    assert (AUDIO / "tone-440hz-4s.mp3").stat().st_size < 256 * 1024
    with running_extension(make_fake_extension()) as ext, _client(postgres_url, track, {"fake": ext}) as client:
        token = client.post("/v1/playback", json={"track_id": track["id"]}).json()["token"]
        assert client.get(f"/v1/stream/{token}").status_code == 200
        row = _settled(postgres_url, track, "played")
    assert row["first_byte_ms"] is not None and row["first_256k_ms"] is None, row


def test_head_request_is_not_a_sound(postgres_url: str) -> None:
    track = _track(BIG, "Metallica")
    _prepare(postgres_url, track)
    with running_extension(make_fake_extension()) as ext, _client(postgres_url, track, {"fake": ext}) as client:
        token = client.post("/v1/playback", json={"track_id": track["id"]}).json()["token"]
        client.head(f"/v1/stream/{token}")
        time.sleep(0.5)
        row = _settled(postgres_url, track, "waiting")
    assert row["first_byte_ms"] is None, row


def test_token_without_stream_stays_waiting_and_prepare_is_marked(postgres_url: str) -> None:
    track = _track(SMALL, "Slipknot")
    _prepare(postgres_url, track)
    with running_extension(make_fake_extension()) as ext, _client(postgres_url, track, {"fake": ext}) as client:
        played = client.post("/v1/playback", json={"track_id": track["id"], "prepare": True})
        assert played.status_code == 200, played.text
        row = _settled(postgres_url, track, "waiting")
    assert row["prepared"] is True
    assert row["source"] == "fake" and row["token_ms"] is not None
    assert row["first_byte_ms"] is None and row["first_256k_ms"] is None


def test_no_extensions_is_no_source(postgres_url: str) -> None:
    track = _track(SMALL, "Slipknot")
    _prepare(postgres_url, track)
    with _client(postgres_url, track, {}) as client:
        assert client.post("/v1/playback", json={"track_id": track["id"]}).status_code == 409
        row = _settled(postgres_url, track, "no_source")
    assert row["source"] is None and row["prepare_ms"] is None and row["first_byte_ms"] is None
    assert row["token_ms"] is not None, "time to refusal is also a number: how long user waited for 'not found'"


def test_only_weak_candidates_is_low_confidence(postgres_url: str) -> None:
    # Extension only has 'Duality': confidence for another song of same artist is below threshold.
    track = _track("Wait and Bleed", "Slipknot")
    _prepare(postgres_url, track)
    with running_extension(make_fake_extension()) as ext, _client(postgres_url, track, {"fake": ext}) as client:
        assert client.post("/v1/playback", json={"track_id": track["id"]}).status_code == 409
        row = _settled(postgres_url, track, "low_confidence")
    assert row["find_ms"] is not None and row["prepare_ms"] is None and row["source"] is None


def test_candidate_that_never_got_ready_is_not_ready(postgres_url: str) -> None:
    track = _track(SMALL, "Slipknot")
    _prepare(postgres_url, track)
    with running_extension(_refusing_extension()) as ext, _client(postgres_url, track, {"refuse": ext}) as client:
        assert client.post("/v1/playback", json={"track_id": track["id"]}).status_code == 409
        row = _settled(postgres_url, track, "not_ready")
    assert row["source"] == "refuse", "which extension failed to prepare is needed for report"
    assert row["find_ms"] is not None and row["prepare_ms"] is None


def test_stream_that_stalls_is_stalled(postgres_url: str, monkeypatch) -> None:
    import app.extensions as extensions

    monkeypatch.setattr(extensions, "STREAM_READ_S", 0.5)
    track = _track(SMALL, "Slipknot")
    _prepare(postgres_url, track)
    with running_extension(_stalling_extension()) as ext, _client(postgres_url, track, {"stall": ext}) as client:
        token = client.post("/v1/playback", json={"track_id": track["id"]}).json()["token"]
        try:
            client.get(f"/v1/stream/{token}")
        except Exception:  # noqa: BLE001 — disconnect midway through body is seen by client as exception
            pass
        row = _settled(postgres_url, track, "stalled")
    assert row["source"] == "stall"
    assert row["first_byte_ms"] is not None and row["first_256k_ms"] is None, row


def test_table_holds_numbers_and_outcome_only(postgres_url: str) -> None:
    asyncio.run(apply(postgres_url))
    columns = {
        row["column_name"]: row["data_type"]
        for row in _sql(
            postgres_url,
            "SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'play_timing'",
        )
    }
    assert set(columns) == COLUMNS, "new column requires card: table has no user, text or address"
    assert {columns[name] for name in COLUMNS if name.endswith("_ms")} == {"integer"}
    bad = _sql(postgres_url, "SELECT 1 FROM pg_indexes WHERE tablename = 'play_timing' AND indexdef ILIKE '%(at)%'")
    assert bad, "missing index on `at`: cleanup and N-day report would do a full table scan"
    for script in ("backup.sh",):
        text = (ROOT / "scripts" / script).read_text(encoding="utf-8")
        personal = re.search(r"^PERSONAL='([^']*)'", text, re.MULTILINE)
        assert personal and "play_timing" not in personal.group(1).split(), "table is not personal: has no user in it"


def test_unknown_outcome_is_refused_by_the_table(postgres_url: str) -> None:
    asyncio.run(apply(postgres_url))

    async def run() -> None:
        conn = await asyncpg.connect(postgres_url)
        try:
            with pytest.raises(asyncpg.CheckViolationError):
                await conn.execute(
                    "INSERT INTO play_timing (track_id, prepared, outcome) VALUES ($1, false, 'whatever')",
                    str(uuid.uuid4()),
                )
        finally:
            await conn.close()

    asyncio.run(run())


def test_timer_counts_from_one_start() -> None:
    from app.play_timing import OUTCOMES, Timer

    now = [100.0]
    timer = Timer(track_id="t-1", prepared=True, clock=lambda: now[0])
    now[0] = 100.120
    timer.mark("find")
    now[0] = 101.0
    timer.source = "fake"
    timer.mark("prepare")
    now[0] = 101.002
    timer.mark("prepare")  # repeating same stage does not overwrite first measurement
    now[0] = 101.005
    timer.mark("token")
    assert timer.row("waiting") == {
        "track_id": "t-1", "source": "fake", "prepared": True,
        "find_ms": 120, "prepare_ms": 1000, "token_ms": 1005,
        "first_byte_ms": None, "first_256k_ms": None, "outcome": "waiting",
        "peers": None, "speed_bps": None, "have_pct": None, "via": None,
    }
    with pytest.raises(ValueError):
        timer.mark("download")
    with pytest.raises(ValueError):
        timer.row("fine")
    assert set(OUTCOMES) == {
        "waiting", "played", "no_source", "low_confidence", "not_ready", "stalled", "error",
    }


def test_writing_never_breaks_a_play() -> None:
    """Database down — Play does not crash or block: write silently omitted."""
    from app.play_timing import Timer, stream_done, write

    dead = "postgresql://music:music@127.0.0.1:9/none"
    began = time.monotonic()
    assert asyncio.run(write(dead, Timer(track_id="t", prepared=False).row("no_source"))) is None
    assert asyncio.run(write(None, Timer(track_id="t", prepared=False).row("no_source"))) is None
    asyncio.run(stream_done(dead, 1, first_byte_ms=1, first_256k_ms=None, outcome="played"))
    assert time.monotonic() - began < 5


def test_purge_drops_only_old_rows_in_one_statement(postgres_url: str) -> None:
    from app.play_timing import purge

    asyncio.run(apply(postgres_url))
    old, fresh = str(uuid.uuid4()), str(uuid.uuid4())

    async def run() -> int:
        conn = await asyncpg.connect(postgres_url)
        try:
            await conn.execute("DELETE FROM play_timing WHERE at < now() - interval '30 days'")
            await conn.execute(
                "INSERT INTO play_timing (at, track_id, prepared, outcome) "
                "SELECT now() - interval '31 days', $1, false, 'played' FROM generate_series(1, 2000)",
                old,
            )
            await conn.execute(
                "INSERT INTO play_timing (at, track_id, prepared, outcome) "
                "VALUES (now() - interval '29 days', $1, false, 'played')",
                fresh,
            )
            return await purge(conn, timedelta(days=30))
        finally:
            await conn.close()

    assert asyncio.run(run()) == 2000
    assert _sql(postgres_url, "SELECT count(*) AS n FROM play_timing WHERE track_id = $1", old)[0]["n"] == 0
    assert _sql(postgres_url, "SELECT count(*) AS n FROM play_timing WHERE track_id = $1", fresh)[0]["n"] == 1


def test_sweep_purges_timing_older_than_30_days(postgres_url: str) -> None:
    """Cleanup lives alongside expired session sweep: has no separate schedule."""
    track = _track(SMALL, "Slipknot")
    _prepare(postgres_url, track)
    _sql(
        postgres_url,
        "INSERT INTO play_timing (at, track_id, prepared, outcome) "
        "VALUES (now() - interval '40 days', $1, false, 'played') RETURNING id",
        track["id"],
    )
    with _client(postgres_url, track, {}) as client:
        client.app.state.last_sweep = -1e9  # sweep every 10 min — consider expired
        client.post("/v1/playback", json={"track_id": track["id"]})  # Play triggers sweep
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if all(row["outcome"] != "played" for row in _rows(postgres_url, track)):
                break
            time.sleep(0.1)
    assert [row["outcome"] for row in _rows(postgres_url, track)] == ["no_source"]
