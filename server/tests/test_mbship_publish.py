"""FT-745: catalog generation brought from Mac takes effect on production in one transaction.

The generation is built by the real loader from a small dump, but publication is replaced —
as on Mac: song numbers are computed on the copy and move into the `ship` schema. Then
`publish_shipped` does on "production" what the loader would do itself, except instead of
assigning numbers — `adopt` (FT-680).
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from datetime import date
from pathlib import Path
from typing import Any

import asyncpg
import pytest

import app.mbcopy as mbcopy
from app.mbcopy import LIVE, LOADER_LOCK_ID, PUBLISHED, load
from app.mbship import Adopted, ShipRefused
from app.mbship_publish import publish_shipped
from app.migrate import apply
from tests.test_mbcopy import pack_dump


@pytest.fixture
async def db(postgres_url: str) -> AsyncIterator[str]:
    await apply(postgres_url)
    conn = await asyncpg.connect(postgres_url)
    try:
        for live in (*LIVE, "mb_loads"):
            await conn.execute(f"TRUNCATE {live} CASCADE")
        await conn.execute("TRUNCATE public.song_identity CASCADE")
        await conn.execute("DROP SCHEMA IF EXISTS ship CASCADE")
        await conn.execute("DROP SCHEMA IF EXISTS ship_archive CASCADE")
    finally:
        await conn.close()
    yield postgres_url
    # Publication is real (commit) — transfer schemas must not leak to neighbor tests.
    conn = await asyncpg.connect(postgres_url)
    try:
        await conn.execute("DROP SCHEMA IF EXISTS ship CASCADE")
        await conn.execute("DROP SCHEMA IF EXISTS ship_archive CASCADE")
    finally:
        await conn.close()


@pytest.fixture
async def built(
    db: str, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> dict[str, Any]:
    """Generation built "on Mac": generation schema and `ship` with IDs."""
    path = tmp_path / "mbdump.tar.bz2"
    pack_dump(path)
    seen: dict[str, Any] = {}

    async def ship_instead_of_publish(
        conn: asyncpg.Connection, *, schema: str, **_: Any
    ) -> int:
        seen["schema"] = schema
        async with conn.transaction():
            await mbcopy._assign_song_identities(conn)
            await conn.execute("CREATE SCHEMA ship")
            await conn.execute(
                "CREATE TABLE ship.song_identity (LIKE public.song_identity INCLUDING ALL)"
            )
            await conn.execute(
                "CREATE TABLE ship.song_alias (LIKE public.song_alias INCLUDING ALL)"
            )
            await conn.execute(
                "ALTER TABLE ship.song_alias ADD CONSTRAINT ship_alias_fk"
                " FOREIGN KEY (song_id) REFERENCES ship.song_identity (song_id)"
            )
            await conn.execute(
                "INSERT INTO ship.song_identity SELECT * FROM public.song_identity"
            )
            await conn.execute(
                "INSERT INTO ship.song_alias SELECT * FROM public.song_alias"
            )
            # "Production" does not know its numbers for the new generation before transfer.
            await conn.execute("TRUNCATE public.song_identity CASCADE")
        return 0

    monkeypatch.setattr(mbcopy, "_publish_generation", ship_instead_of_publish)
    # In CI Postgres is in another container: loader does not see its volume paths (like test_mbcopy).
    monkeypatch.setattr(mbcopy, "_free_bytes", lambda _path: 2**50)
    meta = await load(db, files=[str(path)], allow_main_volume=True)
    monkeypatch.undo()
    return {"schema": seen["schema"], "meta": meta}


async def _go(db: str, built: dict[str, Any], **over: Any) -> Adopted:
    # Transfer queued behind loader robot — fails in seconds rather than hanging.
    conn = await asyncpg.connect(db, server_settings={"lock_timeout": "5s"})
    try:
        kwargs: dict[str, Any] = {
            "ship": "ship",
            "generation": built["schema"],
            "archive": "ship_archive",
            "meta": built["meta"],
        }
        kwargs.update(over)
        return await publish_shipped(conn, **kwargs)
    finally:
        await conn.close()


async def _val(db: str, sql: str, *args: Any) -> Any:
    conn = await asyncpg.connect(db)
    try:
        return await conn.fetchval(sql, *args)
    finally:
        await conn.close()


async def test_shipped_generation_becomes_current(
    db: str, built: dict[str, Any]
) -> None:
    songs = await _val(db, f'SELECT count(*) FROM "{built["schema"]}".song')
    assert songs > 0
    await _go(db, built)
    assert (
        await _val(
            db, "SELECT schema_name FROM public.catalog_generation WHERE is_current"
        )
        == built["schema"]
    )
    assert (
        await _val(
            db, "SELECT count(*) FROM public.catalog_generation WHERE is_current"
        )
        == 1
    )
    assert await _val(db, "SELECT count(*) FROM public.song") == songs
    for table in PUBLISHED:
        assert (
            await _val(db, "SELECT to_regclass($1)", f'"{built["schema"]}"."{table}"')
            is None
        )


async def test_shipped_numbers_are_live_and_old_ones_wait_in_the_archive(
    db: str, built: dict[str, Any]
) -> None:
    shipped = await _val(db, "SELECT count(*) FROM ship.song_identity")
    adopted = await _go(db, built)
    assert isinstance(adopted, Adopted)
    assert await _val(db, "SELECT count(*) FROM public.song_identity") == shipped
    assert (
        await _val(db, "SELECT to_regclass('ship_archive.song_identity')") is not None
    )
    assert await _val(db, "SELECT to_regclass('ship.song_identity')") is None
    missing = await _val(
        db,
        "SELECT count(*) FROM public.song s WHERE NOT EXISTS"
        " (SELECT 1 FROM public.song_identity i WHERE i.v3_song_id = s.id)",
    )
    assert missing == 0


async def test_the_load_is_recorded_as_shipped_from_the_dump(
    db: str, built: dict[str, Any]
) -> None:
    await _go(db, built)
    row = await _val(
        db,
        "SELECT row(dump_date, replication_sequence, duration_ms, tablespace)::text"
        " FROM public.mb_loads ORDER BY loaded_at DESC LIMIT 1",
    )
    meta = built["meta"]
    assert row is not None
    assert date.fromisoformat(meta["dump_date"]).isoformat() in row
    assert f",{meta['duration_ms']}," in row
    assert row.endswith(",pg_default)")


async def test_a_name_that_is_not_a_generation_is_refused(
    db: str, built: dict[str, Any]
) -> None:
    before = await _val(
        db, "SELECT schema_name FROM public.catalog_generation WHERE is_current"
    )
    assert before != built["schema"]
    with pytest.raises(ShipRefused):
        await _go(db, built, generation="public")
    with pytest.raises(ShipRefused):
        await _go(db, built, generation='catalog_gen_x"; DROP TABLE song; --')
    with pytest.raises(ShipRefused):
        await _go(db, built, generation=built["schema"] + '"; DROP TABLE song; --')
    assert (
        await _val(
            db, "SELECT schema_name FROM public.catalog_generation WHERE is_current"
        )
        == before
    )


async def test_refused_shipment_changes_nothing(db: str, built: dict[str, Any]) -> None:
    before = await _val(
        db, "SELECT schema_name FROM public.catalog_generation WHERE is_current"
    )
    assert before != built["schema"]
    conn = await asyncpg.connect(db)
    try:
        await conn.execute("DELETE FROM ship.song_alias")
        await conn.execute(
            "DELETE FROM ship.song_identity WHERE ctid IN (SELECT ctid FROM ship.song_identity LIMIT 1)"
        )
    finally:
        await conn.close()
    with pytest.raises(ShipRefused):
        await _go(db, built)
    assert (
        await _val(
            db, "SELECT schema_name FROM public.catalog_generation WHERE is_current"
        )
        == before
    )
    assert await _val(db, f'SELECT count(*) FROM "{built["schema"]}".song') > 0
    assert (
        await _val(
            db,
            "SELECT count(*) FROM public.mb_loads WHERE duration_ms = $1",
            built["meta"]["duration_ms"],
        )
        == 0
    )
    assert await _val(db, "SELECT to_regclass('ship.song_identity')") is not None


async def test_a_running_loader_keeps_the_shipment_out(
    db: str, built: dict[str, Any]
) -> None:
    before = await _val(
        db, "SELECT schema_name FROM public.catalog_generation WHERE is_current"
    )
    assert before != built["schema"]
    robot = await asyncpg.connect(db)
    try:
        assert await robot.fetchval("SELECT pg_try_advisory_lock($1)", LOADER_LOCK_ID)
        with pytest.raises(ShipRefused, match="загруз"):
            await _go(db, built)
    finally:
        await robot.close()
    assert (
        await _val(
            db, "SELECT schema_name FROM public.catalog_generation WHERE is_current"
        )
        == before
    )


async def test_the_loader_lock_is_released_afterwards(
    db: str, built: dict[str, Any]
) -> None:
    conn = await asyncpg.connect(db)
    other = await asyncpg.connect(db)
    try:
        await publish_shipped(
            conn,
            ship="ship",
            generation=built["schema"],
            archive="ship_archive",
            meta=built["meta"],
        )
        # Transfer connection is still open — lock is free nonetheless.
        assert await other.fetchval("SELECT pg_try_advisory_lock($1)", LOADER_LOCK_ID)
    finally:
        await other.close()
        await conn.close()


async def test_numbers_are_not_assigned_again_on_the_server(
    db: str, built: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    # That is why transfer was introduced: on production disk assigning IDs takes hours.
    async def forbidden(*_: Any, **__: Any) -> None:
        raise AssertionError("numbers are being assigned on production")

    monkeypatch.setattr(mbcopy, "_assign_song_identities", forbidden)
    await _go(db, built)
    assert (
        await _val(
            db, "SELECT schema_name FROM public.catalog_generation WHERE is_current"
        )
        == built["schema"]
    )
