import argparse
import asyncio
import logging
import os
from typing import Any
from datetime import timedelta, timezone

logger = logging.getLogger("apertonodo")

async def record(conn: Any, *, kind: str, user_id: Any, track_id: str | None = None, artist: str = "", title: str = "", ref: str = "") -> None:
    try:
        await conn.execute(
            """INSERT INTO play_failures (user_id, kind, track_id, artist, title, ref)
               VALUES ($1, $2, $3, $4, $5, $6)""",
            user_id, kind, track_id, artist, title, ref
        )
    except Exception as exc:
        logger.warning("failure note failed: %s", type(exc).__name__)

async def note(database_url: str | None, **fields: Any) -> None:
    if not database_url:
        return
    import asyncpg
    try:
        conn = await asyncpg.connect(database_url)
        try:
            await record(conn, **fields)
        finally:
            await conn.close()
    except Exception as exc:
        logger.warning("failure note failed: %s", type(exc).__name__)

async def _main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--days", type=int, default=7)
    args = parser.parse_args()
    database_url = os.environ.get("DATABASE_URL")
    if not database_url:
        return
    import asyncpg
    conn = await asyncpg.connect(database_url)
    try:
        rows = await conn.fetch(
            """SELECT f.at, u.username, f.user_id, f.kind, f.artist, f.title, f.ref
               FROM play_failures f
               LEFT JOIN users u ON u.id = f.user_id
               WHERE f.at >= now() - $1::interval
               ORDER BY f.at ASC""",
            timedelta(days=args.days)
        )
        msk = timezone(timedelta(hours=3))
        for r in rows:
            dt = r["at"].astimezone(msk)
            ts = dt.strftime("%d.%m %H:%M MSK")
            if r["username"]:
                who = r["username"]
            elif r["user_id"]:
                who = str(r["user_id"])[:8]
            else:
                who = "-"
            print(f"{ts}  {who}  {r['kind']}  {r['artist']} — {r['title']}  {r['ref']}")
    finally:
        await conn.close()

if __name__ == "__main__":
    asyncio.run(_main())
