from __future__ import annotations

import asyncio
import hashlib
import re
import shutil
import uuid
from collections.abc import AsyncIterator
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

import asyncpg
import pytest

from app.db import MIGRATIONS_DIR
from app.migrate import apply

# sha256 over the statements of 001-020 in order, whole-line comments left out.
# They already ran in production: never edit a statement. Comments may change
# (FT-827 translated them), the database only remembers the version names.
# FT-905 is the one exception: it removed the statements of the retired source path
# (production keeps those objects, see the tests at the end of this file).
# FT-908 is the second: 006, the repeatable scrub of the retired path, became `SELECT 1;`
# (nothing has written those columns since FT-596).
EXECUTED_SQL_SHA256 = "25e6b0d9cfff033e0d2bba4f2c4cd5c25cfdc2ce9473cdd9999d553dcb6893c8"

PL = "00000000-0000-0000-0000-0000000000a1"
TR = "00000000-0000-0000-0000-0000000000b1"
SEED = f"""
INSERT INTO playlists (id, name, created_at) VALUES
  ('{PL}', 'Road', '2026-01-01T00:00:00Z'),
  ('00000000-0000-0000-0000-0000000000a2', 'Night', '2026-01-02T00:00:00Z');
INSERT INTO playlist_items VALUES
  ('{PL}', 'k3', 0, '{TR}', 'Three', 'C', 3000), ('{PL}', 'k1', 1, '{TR}', 'One', 'A', 1000);
INSERT INTO favorites (canonical_key, track_id, title, artist, duration_ms, added_at) VALUES
  ('k2', '{TR}', 'Two', 'B', 2000, '2026-02-01T00:00:00Z');
INSERT INTO listens (canonical_key, track_id, title, artist, duration_ms, played_at) VALUES
  ('k1', '{TR}', 'One', 'A', 1000, '2026-03-01T00:00:00Z'),
  ('k2', '{TR}', 'Two', 'B', 2000, '2026-03-01T00:00:00Z'),
  ('k1', '{TR}', 'One', 'A', 1000, '2026-03-03T00:00:00Z');
DELETE FROM listens WHERE id = 2;
"""
READS = {
    "playlists": "created_at, id",
    "playlist_items": "playlist_id, position",
    "favorites": "added_at DESC",
    "listens": "played_at DESC, id DESC",
}


def executed(migrations: Path) -> list[Path]:
    return [p for p in sorted(migrations.glob("*.sql")) if int(p.name[:3]) <= 20]


async def legacy_apply(url: str, migrations: Path) -> None:
    """The previous release's runner: every statement of 001-020 on each start."""
    conn = await asyncpg.connect(url)
    try:
        for path in executed(migrations):
            for statement in path.read_text().split(";"):
                if statement.strip():
                    await conn.execute(statement)
    finally:
        await conn.close()


@pytest.fixture
async def scratch_db(postgres_url: str) -> AsyncIterator[str]:
    """A throwaway database next to the test one, dropped afterwards."""
    name = f"ft010_{uuid.uuid4().hex[:12]}"
    admin = await asyncpg.connect(postgres_url)
    await admin.execute(f'CREATE DATABASE "{name}"')
    parts = urlsplit(postgres_url)
    try:
        yield urlunsplit(parts._replace(path=f"/{name}"))
    finally:
        await admin.execute(f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE)')
        await admin.close()


@pytest.fixture
async def other_db(postgres_url: str) -> AsyncIterator[str]:
    """A second throwaway database, for comparing two installs."""
    name = f"ft010_{uuid.uuid4().hex[:12]}"
    admin = await asyncpg.connect(postgres_url)
    await admin.execute(f'CREATE DATABASE "{name}"')
    try:
        yield urlunsplit(urlsplit(postgres_url)._replace(path=f"/{name}"))
    finally:
        await admin.execute(f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE)')
        await admin.close()


@pytest.fixture
def migrations(tmp_path: Path) -> Path:
    target = tmp_path / "migrations"
    shutil.copytree(MIGRATIONS_DIR, target)
    return target


async def fetchval(url: str, sql: str) -> object:
    conn = await asyncpg.connect(url)
    try:
        return await conn.fetchval(sql)
    finally:
        await conn.close()


async def snapshot(url: str, columns: dict[str, str]) -> dict[str, str]:
    conn = await asyncpg.connect(url)
    try:
        return {
            table: await conn.fetchval(
                f"SELECT coalesce(json_agg(x)::text, '[]') FROM "
                f"(SELECT {columns[table]} FROM {table} ORDER BY {order}) x"
            )
            for table, order in READS.items()
        }
    finally:
        await conn.close()


def statements(text: str) -> str:
    return "\n".join(
        line for line in text.split("\n") if not line.lstrip().startswith("--")
    )


def test_executed_migrations_unchanged() -> None:
    digest = hashlib.sha256()
    for path in executed(MIGRATIONS_DIR):
        digest.update(statements(path.read_text(encoding="utf-8")).encode())
    assert digest.hexdigest() == EXECUTED_SQL_SHA256


def test_executed_migrations_read_in_english() -> None:
    left = [
        f"{path.name}:{number}"
        for path in executed(MIGRATIONS_DIR)
        for number, line in enumerate(path.read_text(encoding="utf-8").split("\n"), 1)
        if re.search("[\u0400-\u04ff]", line)
    ]
    assert left == []


def test_new_migrations_expand_only() -> None:
    for path in sorted(MIGRATIONS_DIR.glob("*.sql")):
        if path in executed(MIGRATIONS_DIR):
            continue
        assert "down" not in path.name.lower(), path.name
        assert "DROP COLUMN" not in path.read_text().upper(), path.name
        assert "DROP TABLE" not in path.read_text().upper(), path.name


async def test_double_start_applies_once(scratch_db: str, migrations: Path) -> None:
    await apply(scratch_db, migrations)
    await fetchval(scratch_db, "CREATE TABLE ft010_runs (n serial PRIMARY KEY)")
    (migrations / "990_slow.sql").write_text(
        "SELECT pg_sleep(1);\nINSERT INTO ft010_runs DEFAULT VALUES;\n"
    )

    first, second = await asyncio.gather(
        apply(scratch_db, migrations), apply(scratch_db, migrations)
    )

    assert sorted([first, second]) == [[], ["990_slow"]]
    assert await fetchval(scratch_db, "SELECT count(*) FROM ft010_runs") == 1
    assert await apply(scratch_db, migrations) == []


async def test_failed_migration_is_not_marked(
    scratch_db: str, migrations: Path
) -> None:
    await apply(scratch_db, migrations)
    await fetchval(scratch_db, "CREATE TABLE ft010_side (n integer)")
    broken = migrations / "991_fail.sql"
    broken.write_text("INSERT INTO ft010_side VALUES (1);\nSELECT 1 / 0;\n")

    with pytest.raises(asyncpg.DivisionByZeroError):
        await apply(scratch_db, migrations)
    assert await fetchval(scratch_db, "SELECT count(*) FROM ft010_side") == 0
    assert (
        await fetchval(
            scratch_db,
            "SELECT count(*) FROM schema_migrations WHERE version = '991_fail'",
        )
        == 0
    )

    broken.write_text("INSERT INTO ft010_side VALUES (2);\n")
    assert await apply(scratch_db, migrations) == ["991_fail"]
    assert await apply(scratch_db, migrations) == []
    assert await fetchval(scratch_db, "SELECT count(*) FROM ft010_side") == 1


async def test_old_schema_up_then_previous_code(
    scratch_db: str, migrations: Path
) -> None:
    # Snapshot of a production database made by the previous release.
    await legacy_apply(scratch_db, migrations)
    conn = await asyncpg.connect(scratch_db)
    try:
        await conn.execute(SEED)
        columns = {
            table: await conn.fetchval(
                "SELECT string_agg(column_name, ', ' ORDER BY ordinal_position) "
                "FROM information_schema.columns WHERE table_name = $1",
                table,
            )
            for table in READS
        }
    finally:
        await conn.close()
    before = await snapshot(scratch_db, columns)

    # New code adopts the database: 001-020 are re-runnable, now recorded once.
    files = list(migrations.glob("*.sql"))  # noqa: ASYNC240  # test, tiny fixture directory
    assert len(await apply(scratch_db, migrations)) == len(files)
    assert await snapshot(scratch_db, columns) == before

    # Rollback of the application only: the previous runner on the new schema.
    await legacy_apply(scratch_db, migrations)
    assert await snapshot(scratch_db, columns) == before
    new_id = await fetchval(
        scratch_db,
        "INSERT INTO listens (canonical_key, track_id, title, artist, duration_ms) "
        f"VALUES ('k4', '{TR}', 'Four', 'D', 4000) RETURNING id",
    )
    assert new_id > 3

    # Roll forward again: nothing is re-applied.
    assert await apply(scratch_db, migrations) == []


async def test_scrub_is_superseded_and_harmless_on_every_start(
    scratch_db: str, migrations: Path
) -> None:
    """FT-908: 006 is a no-op now; running it on every start changes no data."""
    body = statements((migrations / "006_scrub_indexer_secrets.sql").read_text(encoding="utf-8"))
    assert body.strip() == "SELECT 1;"
    await apply(scratch_db, migrations)
    await fetchval(
        scratch_db,
        "INSERT INTO playback_sessions (token_hash, track_id, state, expires_at, source_locator) "
        f"VALUES ('ft908', '{TR}', 'resolving', now() + interval '1 hour', 'kept')",
    )
    assert await apply(scratch_db, migrations) == []
    assert (
        await fetchval(
            scratch_db,
            "SELECT source_locator FROM playback_sessions WHERE token_hash = 'ft908'",
        )
        == "kept"
    )


# FT-905: a fresh install carries no objects named after the old source path.
SOURCE_WORDS = re.compile(r"magnet|torrent|tracker|info_?hash|rutracker|rqbit|seeder", re.I)
DEAD_TABLES = (
    "source_candidates", "releases", "release_seeders", "release_files",
    "track_sources", "source_usage", "release_mapping",
)
BEFORE_FT905 = Path(__file__).parent / "fixtures" / "migrations_before_ft905"


async def schema_objects(url: str) -> dict[str, set[tuple[str, ...]]]:
    conn = await asyncpg.connect(url)
    try:
        return {
            "tables": {
                (r[0],) for r in await conn.fetch(
                    "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'")
            },
            "columns": {
                (r[0], r[1], r[2]) for r in await conn.fetch(
                    "SELECT table_name, column_name, data_type FROM information_schema.columns "
                    "WHERE table_schema = 'public'")
            },
            "indexes": {(r[0], r[1]) for r in await conn.fetch(
                "SELECT tablename, indexname FROM pg_indexes WHERE schemaname = 'public'")},
            "triggers": {(r[0], r[1]) for r in await conn.fetch(
                "SELECT event_object_table, trigger_name FROM information_schema.triggers "
                "WHERE trigger_schema = 'public'")},
            "functions": {(r[0],) for r in await conn.fetch(
                "SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace "
                "WHERE n.nspname = 'public'")},
        }
    finally:
        await conn.close()


async def test_fresh_schema_has_no_source_words(scratch_db: str, migrations: Path) -> None:
    await apply(scratch_db, migrations)
    found = await schema_objects(scratch_db)
    named = [
        (kind, item) for kind, items in found.items() for item in items
        if any(SOURCE_WORDS.search(part) for part in item)
    ]
    assert named == []
    assert not {t for (t,) in found["tables"]} & set(DEAD_TABLES)
    assert not {i for i in found["triggers"] if i[0] in DEAD_TABLES}
    assert not {f for (f,) in found["functions"] if f.startswith("source_usage")}


async def test_old_database_then_new_files(
    scratch_db: str, other_db: str, migrations: Path, tmp_path: Path
) -> None:
    old = tmp_path / "old"
    shutil.copytree(MIGRATIONS_DIR, old)
    for path in BEFORE_FT905.glob("*.sql"):
        shutil.copy(path, old / path.name)
    await apply(scratch_db, old)
    before = await schema_objects(scratch_db)
    assert ("source_usage",) in before["tables"]  # the old path really is there

    # Production has every version recorded: the new files add no version.
    assert await apply(scratch_db, migrations) == []
    assert await schema_objects(scratch_db) == before

    # What a fresh install has, an old database has too, with the same types and names.
    await apply(other_db, migrations)
    fresh = await schema_objects(other_db)
    for kind in ("tables", "columns", "indexes", "triggers", "functions"):
        assert fresh[kind] - before[kind] == set(), kind
