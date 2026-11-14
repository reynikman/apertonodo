"""Shared PostgreSQL login counters and a bounded local Argon2 queue."""

from __future__ import annotations

import asyncio
import hashlib
import math
from collections.abc import AsyncIterator, Callable, Iterator
from contextlib import asynccontextmanager, contextmanager
from contextvars import ContextVar
from datetime import datetime, timedelta

import asyncpg

_GLOBAL_WINDOW = timedelta(seconds=60)
_USER_WINDOW = timedelta(minutes=15)
_GLOBAL_LIMIT = 20
_USER_LIMIT = 5
# A single transaction lock serializes admission across application processes.
_COUNTER_LOCK = 42042
_connection: ContextVar[asyncpg.Connection] = ContextVar("login_connection")
_hash_slots = asyncio.Semaphore(2)
_pending = 0


class LoginLimited(Exception):
    def __init__(self, retry_after: int) -> None:
        self.retry_after = retry_after
        super().__init__("login limited")


@contextmanager
def using(conn: asyncpg.Connection) -> Iterator[None]:
    token = _connection.set(conn)
    try:
        yield
    finally:
        _connection.reset(token)


def _key(username: str) -> str:
    return hashlib.sha256(username.encode("utf-8")).hexdigest()


def _retry(oldest: datetime, window: timedelta, current: datetime) -> int:
    return max(1, math.ceil((oldest + window - current).total_seconds()))


@asynccontextmanager
async def admit(username: str | None, now: Callable[[], datetime]) -> AsyncIterator[None]:
    """Charge the shared rate limits before entering the bounded hash queue."""
    global _pending
    # Reserve before the first await: overflow must not wait for a database lock.
    # Eight not-yet-granted requests includes those entering PostgreSQL.
    if _pending >= 8:
        raise LoginLimited(1)
    _pending += 1
    try:
        conn = _connection.get()
        current = now()
        key = _key(username) if username is not None else None
        user_retry = None
        async with conn.transaction():
            await conn.execute("SELECT pg_advisory_xact_lock($1)", _COUNTER_LOCK)
            await conn.execute("DELETE FROM login_global_attempts WHERE attempted_at <= $1", current - _GLOBAL_WINDOW)
            await conn.execute("DELETE FROM login_user_failures WHERE attempted_at <= $1", current - _USER_WINDOW)
            oldest_global = await conn.fetchval(
                "SELECT min(attempted_at) FROM login_global_attempts"
                " HAVING count(*) >= $1", _GLOBAL_LIMIT,
            )
            if oldest_global is not None:
                raise LoginLimited(_retry(oldest_global, _GLOBAL_WINDOW, current))
            await conn.execute("INSERT INTO login_global_attempts (attempted_at) VALUES ($1)", current)
            if key is not None:
                oldest_user = await conn.fetchval(
                    "SELECT min(attempted_at) FROM login_user_failures"
                    " WHERE username_digest = $1 HAVING count(*) >= $2", key, _USER_LIMIT,
                )
                if oldest_user is not None:
                    user_retry = _retry(oldest_user, _USER_WINDOW, current)
        if user_retry is not None:
            raise LoginLimited(user_retry)
        await _hash_slots.acquire()
        try:
            yield
        finally:
            _hash_slots.release()
    finally:
        _pending -= 1


async def record_failure(conn: asyncpg.Connection, username: str, now: datetime) -> None:
    await conn.execute(
        "INSERT INTO login_user_failures (username_digest, attempted_at) VALUES ($1, $2)",
        _key(username), now,
    )


async def reset_failures(conn: asyncpg.Connection, username: str) -> None:
    await conn.execute("DELETE FROM login_user_failures WHERE username_digest = $1", _key(username))
