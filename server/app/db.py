from __future__ import annotations

from pathlib import Path

MIGRATIONS_DIR = Path(__file__).resolve().parents[1] / "migrations"


def migration_sql() -> str:
    parts = [path.read_text() for path in sorted(MIGRATIONS_DIR.glob("*.sql"))]
    return "\n".join(parts)
