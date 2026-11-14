from __future__ import annotations

import asyncio
import unicodedata
import json
import os
import sys
from pathlib import Path
from typing import Any, NoReturn
from uuid import UUID

import asyncpg
from argon2 import PasswordHasher, Type

from .owner import ensure_owner_id, get_owner_id  # noqa: F401  (re-exported)

PASSWORD_HASHER = PasswordHasher(time_cost=3, memory_cost=65536, parallelism=1, type=Type.ID)


def _fail(msg: str, code: int = 1) -> NoReturn:
    sys.stderr.write(msg)
    sys.exit(code)


def normalize_username(username: str) -> str:
    normalized = unicodedata.normalize("NFKC", username).strip().casefold()
    if not normalized or len(normalized) > 128 or not normalized.isprintable():
        raise ValueError("Invalid username")
    return normalized


async def create_user(
    conn: asyncpg.Connection, username: str, password: str, *, is_admin: bool = False
) -> str:
    """Create a user without ever storing the supplied password."""
    name = normalize_username(username)
    if not password or len(password) > 1024:
        raise ValueError("Invalid password")
    digest = await asyncio.to_thread(PASSWORD_HASHER.hash, password)
    user_id = await conn.fetchval(
        "INSERT INTO users (username, password_hash, is_admin) VALUES ($1, $2, $3) RETURNING id",
        name, digest, is_admin,
    )
    return str(user_id)


def _read_password(prompt: str = "Password: ") -> str:
    if sys.stdin.isatty():
        import getpass
        pw = getpass.getpass(prompt)
    else:
        pw = sys.stdin.readline().rstrip("\r\n")
    if not pw:
        _fail("password cannot be empty\n")
    return pw


async def _cli_add(database_url: str, username: str, is_admin: bool) -> None:
    pw = _read_password("Password: ")
    conn = await asyncpg.connect(database_url)
    try:
        await create_user(conn, username, pw, is_admin=is_admin)
        print("user added")
    except Exception:
        _fail("failed to add user\n")
    finally:
        await conn.close()


async def _cli_list(database_url: str) -> None:
    conn = await asyncpg.connect(database_url)
    try:
        rows = await conn.fetch(
            """SELECT u.id::text, u.username, u.is_admin, u.is_active, u.created_at::text,
                      count(t.id) FILTER (WHERE t.expires_at > now()) AS devices
               FROM users u LEFT JOIN user_tokens t ON u.id = t.user_id
               GROUP BY u.id, u.username, u.is_admin, u.is_active, u.created_at ORDER BY u.username"""
        )
        print("id\tusername\tis_admin\tis_active\tcreated_at\tdevices")
        for r in rows:
            print(f"{r['id']}\t{r['username']}\t{r['is_admin']}\t{r['is_active']}\t{r['created_at']}\t{r['devices']}")
    finally:
        await conn.close()


async def _cli_revoke(database_url: str, username: str) -> None:
    norm = normalize_username(username)
    conn = await asyncpg.connect(database_url)
    try:
        user = await conn.fetchrow("SELECT id FROM users WHERE username = $1", norm)
        if user is None:
            _fail("user not found\n")
        await conn.execute("DELETE FROM user_tokens WHERE user_id = $1", user["id"])
        print("tokens revoked")
    finally:
        await conn.close()


async def _cli_deactivate(database_url: str, username: str) -> None:
    norm = normalize_username(username)
    conn = await asyncpg.connect(database_url)
    try:
        user = await conn.fetchrow("SELECT id FROM users WHERE username = $1", norm)
        if user is None:
            _fail("user not found\n")
        async with conn.transaction():
            await conn.execute("UPDATE users SET is_active = false WHERE id = $1", user["id"])
            await conn.execute("DELETE FROM user_tokens WHERE user_id = $1", user["id"])
        print("user deactivated")
    finally:
        await conn.close()


async def _cli_passwd(database_url: str, username: str) -> None:
    norm = normalize_username(username)
    conn = await asyncpg.connect(database_url)
    try:
        user = await conn.fetchrow("SELECT id FROM users WHERE username = $1", norm)
        if user is None:
            _fail("user not found\n")
        pw = _read_password("New password: ")
        digest = await asyncio.to_thread(PASSWORD_HASHER.hash, pw)
        async with conn.transaction():
            await conn.execute("UPDATE users SET password_hash = $1 WHERE id = $2", digest, user["id"])
            await conn.execute("DELETE FROM user_tokens WHERE user_id = $1", user["id"])
        print("password changed")
    finally:
        await conn.close()


def _write_receipt(receipt_dir: str, username: str, uid: UUID, rows: dict[str, int]) -> Path:
    r_dir = Path(receipt_dir)
    r_dir.mkdir(parents=True, exist_ok=True)
    r_path = r_dir / f"receipt-{uid}.json"
    r_path.write_text(json.dumps({"username": username, "user_id": str(uid), "rows": rows}))
    return r_path


async def _cli_delete(database_url: str, username: str, receipt_dir: str) -> None:
    norm = normalize_username(username)
    if sys.stdin.readline().rstrip("\r\n") != username:
        _fail("confirmation does not match\n")
    conn = await asyncpg.connect(database_url)
    try:
        user = await conn.fetchrow("SELECT id, username FROM users WHERE username = $1", norm)
        if user is None:
            _fail("user not found\n")
        uid = user["id"]
        # Counted and deleted in one transaction; the receipt is written only after the commit.
        async with conn.transaction():
            rows = {t: int(await conn.fetchval(f"SELECT count(*) FROM {t} WHERE user_id = $1", uid))
                    for t in ("user_tokens", "favorites", "playlists", "listens",
                              "user_pins", "playback_sessions", "edition_preference")}
            await conn.execute("DELETE FROM user_tokens WHERE user_id = $1", uid)
            await conn.execute("DELETE FROM favorites WHERE user_id = $1", uid)
            await conn.execute("DELETE FROM playlist_items WHERE playlist_id IN (SELECT id FROM playlists WHERE user_id = $1)", uid)
            await conn.execute("DELETE FROM playlists WHERE user_id = $1", uid)
            await conn.execute("DELETE FROM listens WHERE user_id = $1", uid)
            # Pins of a deleted user would keep their files from eviction forever.
            for table in ("user_pins", "playback_sessions", "edition_preference"):
                await conn.execute(f"DELETE FROM {table} WHERE user_id = $1", uid)
            await conn.execute("DELETE FROM users WHERE id = $1", uid)
        r_path = await asyncio.to_thread(_write_receipt, receipt_dir, user["username"], uid, rows)
        print(f"receipt: {r_path.resolve()}")
    finally:
        await conn.close()


def _parse_cli(argv: list[str]) -> tuple[str, dict[str, Any]]:
    if not argv:
        _fail("usage: app.users command\n", 2)
    cmd, rest = argv[0], argv[1:]
    if cmd == "add":
        admin = "--admin" in rest
        pos = [a for a in rest if a != "--admin" and not a.startswith("-")]
        if len(pos) != 1 or any(a.startswith("-") and a != "--admin" for a in rest):
            _fail("usage: app.users add USERNAME [--admin]\n", 2)
        return "add", {"username": pos[0], "admin": admin}
    if cmd == "list" and not rest:
        return "list", {}
    if cmd in ("revoke", "passwd", "deactivate") and len(rest) == 1 and not rest[0].startswith("-"):
        return cmd, {"username": rest[0]}
    if cmd == "delete":
        dirs = [rest[i + 1] for i in range(len(rest) - 1) if rest[i] == "--receipt-dir"]
        pos = [rest[i] for i in range(len(rest)) if not rest[i].startswith("-") and (i == 0 or rest[i - 1] != "--receipt-dir")]
        if len(pos) == 1 and len(dirs) == 1:
            return "delete", {"username": pos[0], "receipt_dir": dirs[0]}
    _fail("usage error\n", 2)


def main(argv: list[str] | None = None) -> None:
    argv = list(sys.argv[1:] if argv is None else argv)
    cmd, kwargs = _parse_cli(argv)
    db_url = os.environ.get("DATABASE_URL")
    if not db_url:
        _fail("DATABASE_URL not set\n")
    if cmd == "add":
        asyncio.run(_cli_add(db_url, kwargs["username"], kwargs["admin"]))
    elif cmd == "list":
        asyncio.run(_cli_list(db_url))
    elif cmd == "revoke":
        asyncio.run(_cli_revoke(db_url, kwargs["username"]))
    elif cmd == "deactivate":
        asyncio.run(_cli_deactivate(db_url, kwargs["username"]))
    elif cmd == "passwd":
        asyncio.run(_cli_passwd(db_url, kwargs["username"]))
    elif cmd == "delete":
        asyncio.run(_cli_delete(db_url, kwargs["username"], kwargs["receipt_dir"]))


if __name__ == "__main__":
    main()
