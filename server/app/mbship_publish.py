"""FT-745: catalog generation shipped from Mac gets deployed to prod.

On Mac, the loader builds a generation and assigns song numbers (FT-679) — the generation
schema and `ship` schema are delivered to prod (`pg_dump`/`pg_restore`). Here is what the loader
would do during publish, except song numbers are not reassigned, but adopted from the shipped
data (`mbship.adopt`, FT-680). Everything runs in a single transaction: refusal leaves everything untouched.

    python -m app.mbship_publish --ship ship --generation catalog_gen_<hex> \\
        --archive <schema for old numbers> --meta meta.json

`meta.json` is what the loader returned on Mac (`dump_date`, `replication_sequence`,
`row_counts`, `duration_ms`).
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import sys
from datetime import date
from typing import Any
from uuid import UUID

import asyncpg

from app import mbcopy
from app.mbship import Adopted, ShipRefused, adopt

GENERATION = re.compile(r"^catalog_gen_([0-9a-f]{32})$")


async def publish_shipped(
    conn: asyncpg.Connection,
    *,
    ship: str,
    generation: str,
    archive: str,
    meta: dict[str, Any],
) -> Adopted:
    match = GENERATION.match(generation)
    if match is None:
        raise ShipRefused(f"not a generation schema: {generation!r}")
    # The loader robot (mbcopy) holds the same lock: two generations do not deploy at once.
    if not await conn.fetchval(
        "SELECT pg_try_advisory_lock($1)", mbcopy.LOADER_LOCK_ID
    ):
        raise ShipRefused("идёт загрузка каталога — перенос подождёт")
    adopted: list[Adopted] = []

    async def settle(c: asyncpg.Connection) -> None:
        adopted.append(
            await adopt(c, ship=ship, generation=generation, archive=archive)
        )

    try:
        replication = meta.get("replication_sequence")
        # Where generation tables reside after pg_restore: on prod, tablespace
        # `mb` on the large disk if restored there; the record does not invent things.
        space = await conn.fetchval(
            "SELECT COALESCE(min(t.spcname), 'pg_default')"
            " FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace"
            " LEFT JOIN pg_tablespace t ON t.oid = c.reltablespace"
            " WHERE n.nspname = $1 AND c.relkind = 'r'",
            generation,
        )
        await mbcopy._publish_generation(
            conn,
            generation_id=UUID(hex=match.group(1)),
            schema=generation,
            dump_date=date.fromisoformat(str(meta["dump_date"])),
            replication=int(replication) if replication is not None else None,
            counts=dict(meta.get("row_counts") or {}),
            duration_ms=int(meta["duration_ms"]),
            tablespace=space,
            settle=settle,
        )
    finally:
        await conn.execute("SELECT pg_advisory_unlock($1)", mbcopy.LOADER_LOCK_ID)
    return adopted[0]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Deploy a shipped catalog generation.")
    parser.add_argument("--ship", required=True)
    parser.add_argument("--generation", required=True)
    parser.add_argument("--archive", required=True)
    parser.add_argument(
        "--meta", required=True, help="JSON returned by the loader on Mac"
    )
    args = parser.parse_args(argv)
    with open(args.meta, encoding="utf-8") as fh:
        meta = json.load(fh)

    async def run() -> Adopted:
        conn = await asyncpg.connect(os.environ["DATABASE_URL"], command_timeout=None)
        try:
            return await publish_shipped(
                conn,
                ship=args.ship,
                generation=args.generation,
                archive=args.archive,
                meta=meta,
            )
        finally:
            await conn.close()

    try:
        result = asyncio.run(run())
    except ShipRefused as exc:
        print(f"refused: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(result.__dict__, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
