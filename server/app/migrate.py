from __future__ import annotations

import asyncio
import os
import sys
from pathlib import Path

import asyncpg

from app.db import MIGRATIONS_DIR

# Session-level advisory lock key shared by every runner ("MIGR").
LOCK_ID = 1297040210

VERSIONS_TABLE = """
CREATE TABLE IF NOT EXISTS schema_migrations (
    version text PRIMARY KEY,
    applied_at timestamptz NOT NULL DEFAULT now()
)
"""
MARK = "INSERT INTO schema_migrations (version) VALUES ($1) ON CONFLICT DO NOTHING"

# Written for the old runner that replayed every file on every start: the
# scrub of indexer keys must keep running each start, not just once.
REPEATABLE = frozenset({"006_scrub_indexer_secrets"})


async def apply(database_url: str, migrations_dir: Path = MIGRATIONS_DIR) -> list[str]:
    """Apply pending migrations once; return the versions applied by this call.

    One runner at a time: a second start blocks on the advisory lock, then
    sees the versions the first one recorded and skips them. Each file runs
    in its own transaction together with its version row, so a failing file
    leaves neither a partial effect nor a mark. Closing the connection
    releases the lock, even when a migration or the connection itself failed.
    """
    conn = await asyncpg.connect(database_url)
    applied: list[str] = []
    try:
        await conn.execute("SELECT pg_advisory_lock($1)", LOCK_ID)
        await conn.execute(VERSIONS_TABLE)
        done = {row["version"] for row in await conn.fetch("SELECT version FROM schema_migrations")}
        for path in sorted(migrations_dir.glob("*.sql")):  # noqa: ASYNC240  # CLI only via asyncio.run(main)
            version = path.stem
            if version in done and version not in REPEATABLE:
                continue
            sql = await asyncio.to_thread(path.read_text)
            try:
                async with conn.transaction():
                    await conn.execute(sql)
                    await conn.execute(MARK, version)
            except Exception:
                print(f"migration {version} failed, not marked applied", file=sys.stderr)
                raise
            if version not in done:
                applied.append(version)
    finally:
        await conn.close()
    return applied


def main() -> None:
    url = os.environ["DATABASE_URL"]
    applied = asyncio.run(apply(url))
    print(f"migrations applied: {len(applied)}")


if __name__ == "__main__":
    main()
