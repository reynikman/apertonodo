"""FT-905: a fresh database no longer has the tables of the retired source path.

Production still has them, and `scripts/p8_move.py` moves them once. Tests of that
move bring the tables back by running the frozen pre-FT-905 migrations on top of a
migrated database. Every statement in those files is re-runnable, except the first part
of 025 (it reads the pre-uuid owner mark), so only its trigger half is replayed.
"""

from __future__ import annotations

from pathlib import Path

import asyncpg

FROZEN = Path(__file__).parent / "fixtures" / "migrations_before_ft905"
OLD_PATH_FILES = (
    "007_release_index", "011_album_memory", "012_storage", "015_release_hash",
    "016_release_feed", "023_release_mapping",
)


async def add_old_source_path(url: str) -> None:
    conn = await asyncpg.connect(url)
    try:
        for name in OLD_PATH_FILES:
            await conn.execute((FROZEN / f"{name}.sql").read_text(encoding="utf-8"))
        pins = (FROZEN / "025_user_pins.sql").read_text(encoding="utf-8")
        await conn.execute(pins[pins.index("CREATE OR REPLACE FUNCTION source_usage_sync_pins"):])
    finally:
        await conn.close()
