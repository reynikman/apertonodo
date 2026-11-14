"""Nightly backup of user data (R-A25): the same archive as `scripts/backup.sh`.

The Apertono database is excluded from PBS backups — it is restored from a MusicBrainz
dump. Only user-created data cannot be restored. The nightly dump is created not by a separate
command, but by `scripts/backup.sh` itself (FT-034): its archive is verified by `scripts/restore_check.sh`,
and a plain `pg_dump -t` would lose trigger functions, causing restoration to fail. Therefore:

- the `PERSONAL` list in backup.sh stays in sync with the schema: a new table with
  `user_id` (or child via FK) omitted from the list would be silently lost;
  the list itself is wider — `song_alias` and `song_identity` keep song links
  alive after catalog rebuilds;
- restore_check.sh restores the exact same list;
- other schemas are excluded from the archive: during the weekly catalog swap,
  a `catalog_gen_*` schema of tens of gigabytes resides alongside;
- the script ships in the server image — the nightly task runs it from the active
  container, rather than from a host copy that might lag behind code.
"""

from __future__ import annotations

import asyncio
import os
import re
import subprocess
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

import asyncpg

ROOT = Path(__file__).resolve().parents[2]


def _personal(script: str) -> set[str]:
    match = re.search(
        r"^PERSONAL='([^']*)'", (ROOT / "scripts" / script).read_text(), re.MULTILINE
    )
    assert match, f"no PERSONAL list in scripts/{script}"
    return set(match.group(1).split())


async def _people_tables(conn: asyncpg.Connection) -> set[str]:
    tables = {"users"} | {
        r["table_name"]
        for r in await conn.fetch(
            "SELECT table_name FROM information_schema.columns "
            "WHERE table_schema = 'public' AND column_name = 'user_id'"
        )
    }
    edges = await conn.fetch(
        "SELECT conrelid::regclass::text AS child, confrelid::regclass::text AS parent "
        "FROM pg_constraint WHERE contype = 'f' AND connamespace = 'public'::regnamespace"
    )
    grown = True
    while grown:
        children = {e["child"] for e in edges if e["parent"] in tables}
        grown = not children <= tables
        tables |= children
    return tables


async def test_every_table_of_people_is_in_backup_sh(postgres_url: str) -> None:
    from app.migrate import apply

    await apply(postgres_url)
    conn = await asyncpg.connect(postgres_url)
    try:
        expected = await _people_tables(conn)
    finally:
        await conn.close()
    assert {
        "users",
        "user_tokens",
        "listens",
        "playlists",
        "playlist_items",
        "favorites",
    } <= expected
    personal = _personal("backup.sh")
    assert expected <= personal, f"missing from backup.sh: {sorted(expected - personal)}"


def test_restore_check_restores_the_same_list() -> None:
    assert _personal("restore_check.sh") == _personal("backup.sh")


def test_backup_script_ships_in_the_server_image() -> None:
    dockerfile = (ROOT / "Dockerfile").read_text()
    assert re.search(r"^COPY\s+.*\bscripts/backup\.sh\b", dockerfile, re.MULTILINE), (
        "scripts/backup.sh is not copied into server image — nightly task has nowhere to take it from"
    )


async def test_archive_holds_no_other_schema(postgres_url: str, tmp_path: Path) -> None:
    from app.migrate import apply

    name = f"ft445_{os.getpid()}"
    parts = urlsplit(postgres_url)
    scratch = urlunsplit(parts._replace(path=f"/{name}"))
    admin = await asyncpg.connect(postgres_url)
    try:
        await admin.execute(f"DROP DATABASE IF EXISTS {name} WITH (FORCE)")
        await admin.execute(
            f"CREATE DATABASE {name} TEMPLATE template0 ENCODING 'UTF8'"
        )
        await apply(scratch)
        conn = await asyncpg.connect(scratch)
        try:
            await conn.execute(
                "CREATE SCHEMA catalog_gen_probe;"
                "CREATE TABLE catalog_gen_probe.song_probe (id int);"
                "INSERT INTO catalog_gen_probe.song_probe VALUES (1);"
            )
        finally:
            await conn.close()

        toc = await asyncio.to_thread(_dump_toc, scratch, tmp_path)
        assert " users " in toc, (
            "no users table in archive — check proves nothing"
        )
        assert "catalog_gen_probe" not in toc, (
            "foreign schema catalog_gen_* got into the archive"
        )
    finally:
        await admin.execute(f"DROP DATABASE IF EXISTS {name} WITH (FORCE)")
        await admin.close()


def _dump_toc(url: str, directory: Path) -> str:
    """Archive created by real backup.sh and its table of contents (`pg_restore --list`)."""
    out = subprocess.run(
        [
            "sh",
            str(ROOT / "scripts" / "backup.sh"),
            "--database-url",
            url,
            "--directory",
            str(directory),
        ],
        capture_output=True,
        text=True,
    )
    assert out.returncode == 0, out.stderr
    archives = list(directory.glob("flowtune-backup-*.dump"))
    assert len(archives) == 1, archives
    return subprocess.run(
        [_pg_restore(), "--list", str(archives[0])],
        capture_output=True,
        text=True,
        check=True,
    ).stdout


def _pg_restore() -> str:
    for candidate in (
        os.environ.get("FLOWTUNE_PG_BIN", ""),
        "/opt/homebrew/opt/postgresql@16/bin",
        "/usr/local/opt/postgresql@16/bin",
        *sorted(str(p) for p in Path("/usr/lib/postgresql").glob("*/bin")),
    ):
        if candidate and (Path(candidate) / "pg_restore").is_file():
            return str(Path(candidate) / "pg_restore")
    raise AssertionError("pg_restore not found — same lookup as in scripts/backup.sh")
