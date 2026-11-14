"""The owner account's id, without the password machinery of app.users.

Catalog code (editions) needs the owner's users.id but must not pull argon2
into modules that run without it.
"""

from __future__ import annotations

from uuid import UUID

import asyncpg


async def get_owner_id(conn: asyncpg.Connection) -> UUID | None:
    """Return owner user id if owner exists, else None."""
    return await conn.fetchval("SELECT id FROM users WHERE username = 'owner'")


async def ensure_owner_id(conn: asyncpg.Connection) -> UUID:
    """Return owner user id, creating unpassworded owner if it does not exist.

    A concurrent insert wins the conflict; its is_active flag is left untouched.
    """
    owner_id = await get_owner_id(conn)
    if owner_id is not None:
        return owner_id
    row = await conn.fetchrow(
        """
        INSERT INTO users (username, password_hash, is_admin, is_active)
        VALUES ('owner', NULL, true, true)
        ON CONFLICT (username) DO UPDATE SET username = EXCLUDED.username
        RETURNING id
        """
    )
    return row["id"]
