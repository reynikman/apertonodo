"""The test database understands Cyrillic just like prod (FT-446).

30.09.2026: `FLOWTUNE_FRESH_DB=1` recreated the test database with `--locale=C`, and in
such a database `lower('Кукушка')` remains "Кукушка". A search for "kino кукушка" there
found nothing, and the search test was red — not because of the code, but because of the database.
On prod it is `en_US.utf8`, and `lower` lowercases Cyrillic. The agent environment
runs in this mode, so a fresh database must be just like prod.
"""

from __future__ import annotations

import re
from pathlib import Path

import asyncpg

ROOT = Path(__file__).resolve().parents[2]


def test_fresh_test_database_is_created_with_utf8_ctype() -> None:
    script = (ROOT / "scripts" / "backend_ci.sh").read_text()
    createdb = [line for line in script.splitlines() if "/createdb" in line]
    assert createdb, "no createdb in backend_ci.sh"
    for line in createdb:
        assert re.search(r"--(locale|lc-ctype)=\S*utf-?8", line, re.IGNORECASE), line


async def test_test_database_lowercases_cyrillic(postgres_url: str) -> None:
    conn = await asyncpg.connect(postgres_url)
    try:
        assert await conn.fetchval("SELECT lower('Кукушка Ёж')") == "кукушка ёж"
    finally:
        await conn.close()
