"""FT-680: song number tables computed on another machine take the place of the live ones.

The heavy step (handing out permanent song numbers for a new MusicBrainz dump) runs on a
copy elsewhere. Here the copy arrives as a schema with its own `song_identity` and
`song_alias`; numbers and aliases the live server wrote meanwhile are merged into it,
and the tables swap schemas, so no rows are rewritten. Everything runs in one nested
transaction: a refusal or a database error changes nothing.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

import asyncpg

_NAME = re.compile(r"[a-z_][a-z0-9_]{0,62}")
_ACTIONS = {
    "a": "NO ACTION",
    "r": "RESTRICT",
    "c": "CASCADE",
    "n": "SET NULL",
    "d": "SET DEFAULT",
}
_TEMP_TABLES = ("mbship_late", "mbship_late_alias")


class ShipRefused(ValueError):
    pass


@dataclass(frozen=True)
class Adopted:
    carried: int
    renumbered: int
    retired: int
    aliases: int
    moved: int


async def adopt(
    conn: asyncpg.Connection, *, ship: str, generation: str, archive: str
) -> Adopted:
    names = (ship, generation, archive)
    for name in names:
        if not isinstance(name, str) or not _NAME.fullmatch(name):
            raise ShipRefused("schema name is not allowed")
    if len(set(names)) != 3 or "public" in names:
        raise ShipRefused(
            "schema names must be three different ones, none of them public"
        )
    async with conn.transaction():
        return await _adopt(conn, f'"{ship}"', f'"{generation}"', f'"{archive}"')


async def _exists(conn: asyncpg.Connection, name: str) -> bool:
    return await conn.fetchval("SELECT to_regclass($1) IS NOT NULL", name)


async def _adopt(conn: asyncpg.Connection, s: str, g: str, a: str) -> Adopted:
    for table in (f"{s}.song_identity", f"{s}.song_alias", f"{g}.song"):
        if not await _exists(conn, table):
            raise ShipRefused(f"{table} is missing")
    for table in (f"{a}.song_identity", f"{a}.song_alias"):
        if await _exists(conn, table):
            raise ShipRefused(f"{table} already exists")

    await conn.execute(
        "LOCK TABLE public.song_identity, public.song_alias IN SHARE ROW EXCLUSIVE MODE"
    )

    views = await conn.fetchval(
        """SELECT count(*) FROM pg_depend d
           JOIN pg_rewrite r ON r.oid = d.objid AND d.classid = 'pg_rewrite'::regclass
           WHERE d.refobjid IN ('public.song_identity'::regclass, 'public.song_alias'::regclass)
             AND r.ev_class <> d.refobjid"""
    )
    if views:
        raise ShipRefused(f"{views} view(s) are bound to the live number tables")

    await _check_shipped(conn, s, g)

    for table in _TEMP_TABLES:
        await conn.execute(f"DROP TABLE IF EXISTS pg_temp.{table}")

    # Late numbers: live rows the shipped table does not have, by the kind of their key.
    await conn.execute(
        f"""CREATE TEMP TABLE mbship_late ON COMMIT DROP AS
        SELECT i.song_id, i.identity_key, x.song_id AS winner, x.v3_song_id AS winner_v3,
               CASE WHEN x.song_id IS NULL THEN 'carried'
                    WHEN l.song_id IS NULL THEN 'renumbered'
                    ELSE 'retired' END AS kind
        FROM public.song_identity i
        LEFT JOIN {s}.song_identity x ON x.identity_key = i.identity_key
        LEFT JOIN public.song_identity l ON l.song_id = x.song_id
        WHERE NOT EXISTS (SELECT 1 FROM {s}.song_identity y WHERE y.song_id = i.song_id)"""
    )
    await conn.execute("CREATE INDEX ON mbship_late (song_id)")
    kinds = {
        r["kind"]: r["n"]
        for r in await conn.fetch(
            "SELECT kind, count(*) AS n FROM mbship_late GROUP BY kind"
        )
    }

    # Late aliases: live rows the shipped table does not know, by recording, else by name.
    await conn.execute(
        f"""CREATE TEMP TABLE mbship_late_alias ON COMMIT DROP AS
        SELECT p.old_track_id, p.old_canonical_key, p.song_id
        FROM public.song_alias p
        WHERE p.old_track_id IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM {s}.song_alias x WHERE x.old_track_id = p.old_track_id)
        UNION ALL
        SELECT p.old_track_id, p.old_canonical_key, p.song_id
        FROM public.song_alias p
        WHERE p.old_track_id IS NULL
          AND NOT EXISTS (
              SELECT 1 FROM {s}.song_alias x WHERE x.old_canonical_key = p.old_canonical_key)"""
    )

    # A late number takes the place of the number the copy minted for its key.
    await conn.execute(
        f"""UPDATE {s}.song_identity x
        SET identity_key = 'renumbered:' || x.song_id::text, v3_song_id = NULL
        FROM mbship_late l WHERE l.kind = 'renumbered' AND x.song_id = l.winner"""
    )
    await conn.execute(
        f"""INSERT INTO {s}.song_identity (song_id, identity_key, v3_song_id)
        SELECT song_id, identity_key, winner_v3 FROM mbship_late WHERE kind = 'renumbered'"""
    )
    await conn.execute(
        f"""UPDATE {s}.song_alias p SET song_id = l.song_id
        FROM mbship_late l WHERE l.kind = 'renumbered' AND p.song_id = l.winner"""
    )
    await conn.execute(
        f"""DELETE FROM {s}.song_identity x USING mbship_late l
        WHERE l.kind = 'renumbered' AND x.song_id = l.winner"""
    )
    # Carried numbers keep their key; retired ones step aside under a key of their own.
    await conn.execute(
        f"""INSERT INTO {s}.song_identity (song_id, identity_key, v3_song_id)
        SELECT song_id,
               CASE WHEN kind = 'retired' THEN 'retired:' || song_id::text ELSE identity_key END,
               NULL
        FROM mbship_late WHERE kind IN ('carried', 'retired')"""
    )

    aliases = await conn.fetchval(
        f"""WITH added AS (
            INSERT INTO {s}.song_alias (old_track_id, old_canonical_key, song_id)
            SELECT p.old_track_id,
                   CASE WHEN p.old_track_id IS NOT NULL AND EXISTS (
                            SELECT 1 FROM {s}.song_alias x
                            WHERE x.old_canonical_key = p.old_canonical_key)
                        THEN NULL ELSE p.old_canonical_key END,
                   COALESCE(w.winner, p.song_id)
            FROM mbship_late_alias p
            LEFT JOIN mbship_late w ON w.song_id = p.song_id AND w.kind = 'retired'
            RETURNING 1)
        SELECT count(*) FROM added"""
    )

    # Other tables pointing at the numbers: found in pg_constraint, not listed by hand.
    keys = await conn.fetch(
        """SELECT quote_ident(c.conname) AS name,
                  format('%I.%I', n.nspname, r.relname) AS tbl,
                  quote_ident(att.attname) AS col, pa.attname AS parent_col,
                  c.condeferrable, c.condeferred,
                  c.confupdtype::text AS confupdtype, c.confdeltype::text AS confdeltype,
                  c.confmatchtype::text AS confmatchtype
           FROM pg_constraint c
           JOIN pg_class r ON r.oid = c.conrelid
           JOIN pg_namespace n ON n.oid = r.relnamespace
           JOIN pg_attribute att ON att.attrelid = c.conrelid AND att.attnum = c.conkey[1]
           JOIN pg_attribute pa ON pa.attrelid = c.confrelid AND pa.attnum = c.confkey[1]
           WHERE c.contype = 'f' AND c.confrelid = 'public.song_identity'::regclass
             AND c.conrelid NOT IN ('public.song_alias'::regclass, 'public.song_identity'::regclass)
           ORDER BY c.oid"""
    )
    if any(k["parent_col"] != "song_id" for k in keys):
        raise ShipRefused("a foreign key points at a column other than song_id")
    moved = 0
    if kinds.get("retired"):
        for k in keys:
            moved += await _move_rows(conn, k["tbl"], k["col"])

    # The swap: keys off, tables change schemas, keys back under the same names.
    await conn.execute(f"CREATE SCHEMA IF NOT EXISTS {a}")
    for k in keys:
        await conn.execute(f"ALTER TABLE {k['tbl']} DROP CONSTRAINT {k['name']}")
    for table in ("song_identity", "song_alias"):
        await conn.execute(f"ALTER TABLE public.{table} SET SCHEMA {a}")
        await conn.execute(f"ALTER TABLE {s}.{table} SET SCHEMA public")
    for k in keys:
        match = "FULL" if k["confmatchtype"] == "f" else "SIMPLE"
        deferrable = "DEFERRABLE" if k["condeferrable"] else "NOT DEFERRABLE"
        initially = "INITIALLY DEFERRED" if k["condeferred"] else "INITIALLY IMMEDIATE"
        await conn.execute(
            f"ALTER TABLE {k['tbl']} ADD CONSTRAINT {k['name']} "
            f"FOREIGN KEY ({k['col']}) REFERENCES public.song_identity (song_id) "
            f"MATCH {match} ON UPDATE {_ACTIONS[k['confupdtype']]} "
            f"ON DELETE {_ACTIONS[k['confdeltype']]} {deferrable} {initially}"
        )

    return Adopted(
        carried=kinds.get("carried", 0),
        renumbered=kinds.get("renumbered", 0),
        retired=kinds.get("retired", 0),
        aliases=aliases,
        moved=moved,
    )


_INDEXES = """SELECT i.indisunique, i.indisprimary,
       (SELECT array_agg(CASE WHEN k = 0 THEN '(expr)' ELSE
                (SELECT attname::text FROM pg_attribute
                 WHERE attrelid = i.indrelid AND attnum = k) END ORDER BY o)
        FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS u(k, o)) AS cols,
       pg_get_expr(i.indexprs, i.indrelid) AS exprs,
       pg_get_expr(i.indpred, i.indrelid) AS pred
FROM pg_index i WHERE i.indrelid = $1::regclass AND i.indisunique"""


async def _index_set(conn: asyncpg.Connection, table: str) -> set:
    return {
        (r["indisprimary"], tuple(r["cols"]), r["exprs"], r["pred"])
        for r in await conn.fetch(_INDEXES, table)
    }


async def _check_built_alike(conn: asyncpg.Connection, s: str) -> list[str]:
    problems = []
    for table in ("song_identity", "song_alias"):
        live = await _index_set(conn, f"public.{table}")
        shipped = await _index_set(conn, f"{s}.{table}")
        if live - shipped:
            problems.append(
                f"{s}.{table} lacks {len(live - shipped)} unique index(es) of the live table"
            )
    has_key = await conn.fetchval(
        """SELECT count(*) FROM pg_constraint
        WHERE contype = 'f' AND conrelid = $1::regclass AND confrelid = $2::regclass""",
        f"{s}.song_alias",
        f"{s}.song_identity",
    )
    if not has_key:
        problems.append(f"{s}.song_alias has no foreign key to {s}.song_identity")
    triggers = await conn.fetchval(
        """SELECT count(*) FROM pg_trigger
        WHERE tgrelid IN ('public.song_identity'::regclass, 'public.song_alias'::regclass)
          AND NOT tgisinternal"""
    )
    if triggers:
        problems.append(f"{triggers} trigger(s) on the live number tables")
    return problems


async def _check_shipped(conn: asyncpg.Connection, s: str, g: str) -> None:
    problems = await _check_built_alike(conn, s)
    without_number = await conn.fetchval(
        f"""SELECT count(*) FROM {g}.song x
        WHERE NOT EXISTS (SELECT 1 FROM {s}.song_identity i WHERE i.v3_song_id = x.id)"""
    )
    if without_number:
        problems.append(f"{without_number} song(s) have no shipped number")
    without_song = await conn.fetchval(
        f"""SELECT count(*) FROM {s}.song_identity i
        WHERE i.v3_song_id IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM {g}.song x WHERE x.id = i.v3_song_id)"""
    )
    if without_song:
        problems.append(f"{without_song} shipped number(s) point at a missing song")
    orphans = await conn.fetchval(
        f"""SELECT count(*) FROM {s}.song_alias p
        WHERE NOT EXISTS (SELECT 1 FROM {s}.song_identity i WHERE i.song_id = p.song_id)"""
    )
    if orphans:
        problems.append(f"{orphans} shipped alias(es) point at an unknown number")
    if problems:
        raise ShipRefused("; ".join(problems))


async def _move_rows(conn: asyncpg.Connection, tbl: str, col: str) -> int:
    """Rows of retired numbers go to the winner; where the winner has its own row, it stays."""
    try:
        async with conn.transaction():
            status = await conn.execute(
                f"""UPDATE {tbl} AS t SET {col} = r.winner
                FROM mbship_late r WHERE r.kind = 'retired' AND t.{col} = r.song_id"""
            )
        return int(status.split()[-1])
    except asyncpg.UniqueViolationError:
        pass
    rows = await conn.fetch(
        f"""SELECT t.ctid, r.winner FROM {tbl} AS t
        JOIN mbship_late r ON r.kind = 'retired' AND t.{col} = r.song_id"""
    )
    moved = 0
    for row in rows:
        try:
            async with conn.transaction():
                await conn.execute(
                    f"UPDATE {tbl} SET {col} = $1 WHERE ctid = $2::tid",
                    row["winner"],
                    row["ctid"],
                )
            moved += 1
        except asyncpg.UniqueViolationError:
            await conn.execute(f"DELETE FROM {tbl} WHERE ctid = $1::tid", row["ctid"])
    return moved
