"""FT-680: song number tables computed on another machine take the place of the live ones."""

from __future__ import annotations

import uuid

import asyncpg
import pytest

from app.mbship import Adopted, ShipRefused, adopt


def _u(kind: str, n: int) -> uuid.UUID:
    return uuid.UUID(f"{kind * 8}-{kind * 4}-4{kind * 3}-8{kind * 3}-{n:012d}")


def num(n: int) -> uuid.UUID:
    return _u("e", n)


def rec(n: int) -> uuid.UUID:
    return _u("c", n)


OWNER = _u("f", 1)
ANN = _u("f", 2)


def album(n: int) -> uuid.UUID:
    return _u("a", n)


@pytest.fixture
async def conn(postgres_url: str):
    from app.migrate import apply

    await apply(postgres_url)
    connection = await asyncpg.connect(postgres_url)
    outer = connection.transaction()
    await outer.start()
    try:
        await connection.execute("TRUNCATE public.song_identity CASCADE")
        await connection.execute("CREATE SCHEMA ship")
        await connection.execute("CREATE SCHEMA gen")
        await connection.execute(
            "CREATE TABLE ship.song_identity (LIKE public.song_identity INCLUDING ALL)"
        )
        await connection.execute(
            "CREATE TABLE ship.song_alias (LIKE public.song_alias INCLUDING ALL)"
        )
        await connection.execute(
            "ALTER TABLE ship.song_alias ADD CONSTRAINT ship_alias_fk"
            " FOREIGN KEY (song_id) REFERENCES ship.song_identity (song_id)"
        )
        await connection.execute("CREATE TABLE gen.song (id bigint PRIMARY KEY)")
        yield connection
    finally:
        await outer.rollback()
        await connection.close()


async def live(conn, n: int, key: str, v3: int | None = None) -> None:
    await conn.execute(
        "INSERT INTO public.song_identity (song_id, identity_key, v3_song_id) VALUES ($1, $2, $3)",
        num(n),
        key,
        v3,
    )


async def shipped(conn, n: int, key: str, v3: int | None = None) -> None:
    await conn.execute(
        "INSERT INTO ship.song_identity (song_id, identity_key, v3_song_id) VALUES ($1, $2, $3)",
        num(n),
        key,
        v3,
    )
    if v3 is not None:
        await conn.execute(
            "INSERT INTO gen.song (id) VALUES ($1) ON CONFLICT DO NOTHING", v3
        )


async def both(conn, n: int, key: str, v3: int | None = None) -> None:
    """A number the copy already had: live as it was, shipped with the new song row."""
    await live(conn, n, key, None if v3 is None else v3 + 1000)
    await shipped(conn, n, key, v3)


async def alias(
    conn, where: str, n: int, track: int | None = None, canon: str | None = None
) -> None:
    await conn.execute(
        f"INSERT INTO {where}.song_alias (old_track_id, old_canonical_key, song_id) VALUES ($1, $2, $3)",
        None if track is None else rec(track),
        canon,
        num(n),
    )


async def pref(
    conn, n: int, user: uuid.UUID = OWNER, album_n: int | None = 1, edition: int = 1
) -> None:
    await conn.execute(
        "INSERT INTO public.edition_preference (user_id, song_id, album_id, edition_id)"
        " VALUES ($1, $2, $3, $4)",
        user,
        num(n),
        None if album_n is None else album(album_n),
        _u("d", edition),
    )


async def go(conn) -> Adopted:
    return await adopt(conn, ship="ship", generation="gen", archive="arch")


async def numbers(
    conn, schema: str = "public"
) -> dict[uuid.UUID, tuple[str, int | None]]:
    rows = await conn.fetch(
        f"SELECT song_id, identity_key, v3_song_id FROM {schema}.song_identity"
    )
    return {r["song_id"]: (r["identity_key"], r["v3_song_id"]) for r in rows}


async def aliases(
    conn, schema: str = "public"
) -> set[tuple[uuid.UUID | None, str | None, uuid.UUID]]:
    rows = await conn.fetch(
        f"SELECT old_track_id, old_canonical_key, song_id FROM {schema}.song_alias"
    )
    return {(r["old_track_id"], r["old_canonical_key"], r["song_id"]) for r in rows}


async def prefs(conn) -> set[tuple[uuid.UUID, uuid.UUID, uuid.UUID | None, uuid.UUID]]:
    rows = await conn.fetch(
        "SELECT user_id, song_id, album_id, edition_id FROM public.edition_preference"
    )
    return {(r["user_id"], r["song_id"], r["album_id"], r["edition_id"]) for r in rows}


async def oid(conn, name: str) -> int | None:
    return await conn.fetchval("SELECT to_regclass($1)::oid", name)


# --- the swap itself ---------------------------------------------------------------------------


async def test_shipped_numbers_become_the_live_ones(conn):
    await both(conn, 1, "w:one", 11)
    await shipped(conn, 2, "w:two", 12)
    shipped_oid = await oid(conn, "ship.song_identity")

    result = await go(conn)

    assert await numbers(conn) == {num(1): ("w:one", 11), num(2): ("w:two", 12)}
    assert await oid(conn, "public.song_identity") == shipped_oid
    assert result == Adopted(carried=0, renumbered=0, retired=0, aliases=0, moved=0)


async def test_old_tables_wait_in_the_archive_untouched(conn):
    await both(conn, 1, "w:one", 11)
    await live(conn, 3, "w:three", 1003)
    await alias(conn, "public", 1, track=1)
    live_oid = await oid(conn, "public.song_identity")
    alias_oid = await oid(conn, "public.song_alias")

    await go(conn)

    assert await oid(conn, "arch.song_identity") == live_oid
    assert await oid(conn, "arch.song_alias") == alias_oid
    assert await numbers(conn, "arch") == {
        num(1): ("w:one", 1011),
        num(3): ("w:three", 1003),
    }
    assert await aliases(conn, "arch") == {(rec(1), None, num(1))}


async def test_ship_schema_is_left_without_number_tables(conn):
    await both(conn, 1, "w:one", 11)
    await go(conn)
    assert await oid(conn, "ship.song_identity") is None
    assert await oid(conn, "ship.song_alias") is None


async def test_shipped_aliases_become_the_live_ones(conn):
    await both(conn, 1, "w:one", 11)
    await alias(conn, "ship", 1, track=1)
    await alias(conn, "ship", 1, canon="band|one")
    shipped_oid = await oid(conn, "ship.song_alias")

    await go(conn)

    assert await aliases(conn) == {(rec(1), None, num(1)), (None, "band|one", num(1))}
    assert await oid(conn, "public.song_alias") == shipped_oid


async def test_archive_schema_may_exist_already(conn):
    await conn.execute("CREATE SCHEMA arch")
    await conn.execute("CREATE TABLE arch.mb_artist (id int)")
    await both(conn, 1, "w:one", 11)
    await go(conn)
    assert await numbers(conn) == {num(1): ("w:one", 11)}


async def test_writers_are_kept_out_while_it_works(conn):
    await both(conn, 1, "w:one", 11)
    await go(conn)
    modes = await conn.fetch(
        """SELECT c.relname, l.mode FROM pg_locks l JOIN pg_class c ON c.oid = l.relation
           JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE l.pid = pg_backend_pid() AND n.nspname = 'arch' AND l.mode = 'ShareRowExclusiveLock'"""
    )
    assert {r["relname"] for r in modes} == {"song_identity", "song_alias"}


# --- foreign keys of other tables ----------------------------------------------------------------


async def test_edition_choices_follow_to_the_new_table(conn):
    await both(conn, 1, "w:one", 11)
    await pref(conn, 1)
    await go(conn)

    target = await conn.fetchval(
        """SELECT confrelid FROM pg_constraint
           WHERE conrelid = 'public.edition_preference'::regclass AND contype = 'f'"""
    )
    assert target == await oid(conn, "public.song_identity")
    assert await prefs(conn) == {(OWNER, num(1), album(1), _u("d", 1))}


async def test_edition_choice_of_an_unknown_number_is_still_refused_afterwards(conn):
    await both(conn, 1, "w:one", 11)
    await go(conn)
    with pytest.raises(asyncpg.ForeignKeyViolationError):
        async with conn.transaction():
            await pref(conn, 99)


async def test_foreign_key_keeps_its_name(conn):
    before = await conn.fetchval(
        """SELECT conname FROM pg_constraint
           WHERE conrelid = 'public.edition_preference'::regclass AND contype = 'f'"""
    )
    await both(conn, 1, "w:one", 11)
    await go(conn)
    after = await conn.fetch(
        """SELECT conname FROM pg_constraint
           WHERE conrelid = 'public.edition_preference'::regclass AND contype = 'f'"""
    )
    assert [r["conname"] for r in after] == [before]


async def test_any_other_table_pointing_at_numbers_follows_too(conn):
    await conn.execute(
        "CREATE TABLE public.zz_marks (who text, tune uuid REFERENCES public.song_identity (song_id))"
    )
    await both(conn, 1, "w:one", 11)
    await conn.execute("INSERT INTO public.zz_marks VALUES ('a', $1)", num(1))
    await go(conn)

    target = await conn.fetchval(
        "SELECT confrelid FROM pg_constraint WHERE conrelid = 'public.zz_marks'::regclass AND contype = 'f'"
    )
    assert target == await oid(conn, "public.song_identity")
    with pytest.raises(asyncpg.ForeignKeyViolationError):
        async with conn.transaction():
            await conn.execute("INSERT INTO public.zz_marks VALUES ('b', $1)", num(77))


async def test_live_aliases_table_points_at_the_live_numbers(conn):
    await both(conn, 1, "w:one", 11)
    await go(conn)
    target = await conn.fetchval(
        "SELECT confrelid FROM pg_constraint WHERE conrelid = 'public.song_alias'::regclass AND contype = 'f'"
    )
    assert target == await oid(conn, "public.song_identity")
    old = await conn.fetchval(
        "SELECT confrelid FROM pg_constraint WHERE conrelid = 'arch.song_alias'::regclass AND contype = 'f'"
    )
    assert old == await oid(conn, "arch.song_identity")


# --- numbers handed out on the live server after the copy ---------------------------------------


async def test_late_number_with_a_key_nobody_shipped_is_carried(conn):
    await both(conn, 1, "w:one", 11)
    await live(conn, 5, "w:late", 1005)

    result = await go(conn)

    assert (await numbers(conn))[num(5)] == ("w:late", None)
    assert result.carried == 1 and result.renumbered == 0 and result.retired == 0


async def test_late_number_takes_over_a_number_minted_elsewhere(conn):
    await both(conn, 1, "w:one", 11)
    await live(conn, 5, "w:late", 1005)
    await shipped(conn, 50, "w:late", 15)
    await alias(conn, "ship", 50, track=7)
    await alias(conn, "ship", 50, canon="band|late")

    result = await go(conn)

    got = await numbers(conn)
    assert got[num(5)] == ("w:late", 15)
    assert num(50) not in got
    assert await aliases(conn) == {(rec(7), None, num(5)), (None, "band|late", num(5))}
    assert result.renumbered == 1 and result.carried == 0 and result.retired == 0


async def test_late_number_yields_to_an_old_number_that_took_its_key(conn):
    await live(conn, 1, "w:before", 1001)
    await shipped(conn, 1, "w:late", 11)
    await live(conn, 5, "w:late", 1005)

    result = await go(conn)

    got = await numbers(conn)
    assert got[num(1)] == ("w:late", 11)
    assert got[num(5)] == (f"retired:{num(5)}", None)
    assert result.retired == 1 and result.carried == 0 and result.renumbered == 0


async def test_edition_choice_of_a_yielding_number_moves(conn):
    await live(conn, 1, "w:before", 1001)
    await shipped(conn, 1, "w:late", 11)
    await live(conn, 5, "w:late", 1005)
    await pref(conn, 5, album_n=2, edition=4)
    await pref(conn, 5, user=ANN, album_n=None, edition=5)

    result = await go(conn)

    assert await prefs(conn) == {
        (OWNER, num(1), album(2), _u("d", 4)),
        (ANN, num(1), None, _u("d", 5)),
    }
    assert result.moved == 2


async def test_the_winner_keeps_its_own_edition_choice(conn):
    await live(conn, 1, "w:before", 1001)
    await shipped(conn, 1, "w:late", 11)
    await live(conn, 5, "w:late", 1005)
    await pref(conn, 1, album_n=2, edition=1)
    await pref(conn, 5, album_n=2, edition=4)

    result = await go(conn)

    assert await prefs(conn) == {(OWNER, num(1), album(2), _u("d", 1))}
    assert result.moved == 0


async def test_other_tables_follow_a_yielding_number(conn):
    await conn.execute(
        "CREATE TABLE public.zz_marks (who text, tune uuid REFERENCES public.song_identity (song_id))"
    )
    await live(conn, 1, "w:before", 1001)
    await shipped(conn, 1, "w:late", 11)
    await live(conn, 5, "w:late", 1005)
    await conn.execute(
        "INSERT INTO public.zz_marks VALUES ('a', $1), ('b', $1)", num(5)
    )

    result = await go(conn)

    rows = await conn.fetch("SELECT who, tune FROM public.zz_marks ORDER BY who")
    assert [(r["who"], r["tune"]) for r in rows] == [("a", num(1)), ("b", num(1))]
    assert result.moved == 2


async def test_edition_choices_of_carried_and_taken_over_numbers_stay(conn):
    await both(conn, 1, "w:one", 11)
    await live(conn, 5, "w:late", 1005)
    await live(conn, 6, "w:later", 1006)
    await shipped(conn, 60, "w:later", 16)
    await pref(conn, 5, album_n=1, edition=1)
    await pref(conn, 6, album_n=1, edition=2)

    result = await go(conn)

    assert await prefs(conn) == {
        (OWNER, num(5), album(1), _u("d", 1)),
        (OWNER, num(6), album(1), _u("d", 2)),
    }
    assert result.moved == 0


async def test_three_late_numbers_of_three_kinds_at_once(conn):
    await live(conn, 1, "w:before", 1001)
    await shipped(conn, 1, "w:c", 11)
    await live(conn, 5, "w:a", 1005)
    await live(conn, 6, "w:b", 1006)
    await live(conn, 7, "w:c", 1007)
    await shipped(conn, 60, "w:b", 16)

    result = await go(conn)

    assert await numbers(conn) == {
        num(1): ("w:c", 11),
        num(5): ("w:a", None),
        num(6): ("w:b", 16),
        num(7): (f"retired:{num(7)}", None),
    }
    assert result == Adopted(carried=1, renumbered=1, retired=1, aliases=0, moved=0)


async def test_number_minted_elsewhere_without_a_late_twin_stays(conn):
    await both(conn, 1, "w:one", 11)
    await shipped(conn, 50, "w:fresh", 15)
    await live(conn, 5, "w:late", 1005)
    await go(conn)
    got = await numbers(conn)
    assert got[num(50)] == ("w:fresh", 15)
    assert got[num(5)] == ("w:late", None)


# --- aliases written on the live server after the copy ------------------------------------------


async def test_late_alias_by_recording_is_carried(conn):
    await both(conn, 1, "w:one", 11)
    await alias(conn, "public", 1, track=3)
    result = await go(conn)
    assert await aliases(conn) == {(rec(3), None, num(1))}
    assert result.aliases == 1


async def test_late_alias_by_name_is_carried(conn):
    await both(conn, 1, "w:one", 11)
    await alias(conn, "public", 1, canon="band|one")
    result = await go(conn)
    assert await aliases(conn) == {(None, "band|one", num(1))}
    assert result.aliases == 1


async def test_shipped_alias_wins_over_the_live_one(conn):
    await both(conn, 1, "w:one", 11)
    await both(conn, 2, "w:two", 12)
    await alias(conn, "public", 1, track=3)
    await alias(conn, "ship", 2, track=3)
    await alias(conn, "public", 1, canon="band|x")
    await alias(conn, "ship", 2, canon="band|x")

    result = await go(conn)

    assert await aliases(conn) == {(rec(3), None, num(2)), (None, "band|x", num(2))}
    assert result.aliases == 0


async def test_alias_of_a_late_number_follows_it(conn):
    await both(conn, 1, "w:one", 11)
    await live(conn, 5, "w:late", 1005)
    await alias(conn, "public", 5, track=3)
    await live(conn, 6, "w:later", 1006)
    await shipped(conn, 60, "w:later", 16)
    await alias(conn, "public", 6, track=4)

    await go(conn)

    assert await aliases(conn) == {(rec(3), None, num(5)), (rec(4), None, num(6))}


async def test_alias_of_a_yielding_number_goes_to_the_winner(conn):
    await live(conn, 1, "w:before", 1001)
    await shipped(conn, 1, "w:late", 11)
    await live(conn, 5, "w:late", 1005)
    await alias(conn, "public", 5, track=3)
    await alias(conn, "public", 5, canon="band|late")

    result = await go(conn)

    assert await aliases(conn) == {(rec(3), None, num(1)), (None, "band|late", num(1))}
    assert result.aliases == 2


async def test_alias_with_both_names_is_judged_by_its_recording(conn):
    await both(conn, 1, "w:one", 11)
    await both(conn, 2, "w:two", 12)
    await conn.execute(
        "INSERT INTO public.song_alias (old_track_id, old_canonical_key, song_id) VALUES ($1, 'band|q', $2)",
        rec(3),
        num(1),
    )
    await alias(conn, "ship", 2, track=3)

    result = await go(conn)

    assert await aliases(conn) == {(rec(3), None, num(2))}
    assert result.aliases == 0


# --- refusals: nothing changes -------------------------------------------------------------------


async def refused(conn, **names: str) -> str:
    live_oid = await oid(conn, "public.song_identity")
    ship_oid = await oid(conn, "ship.song_identity")
    live_rows = await numbers(conn)
    ship_rows = await numbers(conn, "ship") if ship_oid else None
    live_aliases = await aliases(conn)
    kept = await prefs(conn)
    args = {"ship": "ship", "generation": "gen", "archive": "arch", **names}
    with pytest.raises(ShipRefused) as caught:
        await adopt(conn, **args)
    assert await oid(conn, "public.song_identity") == live_oid
    assert await oid(conn, "ship.song_identity") == ship_oid
    assert await numbers(conn) == live_rows
    assert await aliases(conn) == live_aliases
    assert await prefs(conn) == kept
    if ship_oid:
        assert await numbers(conn, "ship") == ship_rows
    return str(caught.value)


async def test_song_without_a_number_refuses(conn):
    await both(conn, 1, "w:one", 11)
    await live(conn, 5, "w:late", 1005)
    await conn.execute("INSERT INTO gen.song (id) VALUES (12), (13)")
    assert "2" in await refused(conn)


async def test_number_of_a_song_outside_the_generation_refuses(conn):
    await both(conn, 1, "w:one", 11)
    await conn.execute(
        "INSERT INTO ship.song_identity (song_id, identity_key, v3_song_id) VALUES ($1, 'w:x', 99)",
        num(2),
    )
    assert "1" in await refused(conn)


async def test_shipped_number_without_a_song_is_fine(conn):
    await both(conn, 1, "w:one", 11)
    await shipped(conn, 2, "w:gone", None)
    await go(conn)
    assert (await numbers(conn))[num(2)] == ("w:gone", None)


async def test_shipped_alias_of_an_unknown_number_refuses(conn):
    await both(conn, 1, "w:one", 11)
    await live(conn, 5, "w:late", 1005)
    await conn.execute("ALTER TABLE ship.song_alias DROP CONSTRAINT ship_alias_fk")
    await alias(conn, "ship", 9, track=3)
    await refused(conn)


@pytest.mark.parametrize("gone", ["ship.song_identity", "ship.song_alias", "gen.song"])
async def test_missing_table_refuses(conn, gone):
    await live(conn, 1, "w:one", 1001)
    await conn.execute(f"DROP TABLE {gone} CASCADE")
    live_oid = await oid(conn, "public.song_identity")
    with pytest.raises(ShipRefused):
        await go(conn)
    assert await oid(conn, "public.song_identity") == live_oid
    assert await oid(conn, "arch.song_identity") is None
    assert await numbers(conn) == {num(1): ("w:one", 1001)}


@pytest.mark.parametrize("held", ["song_identity", "song_alias"])
async def test_archive_that_already_holds_numbers_refuses(conn, held):
    await both(conn, 1, "w:one", 11)
    await conn.execute("CREATE SCHEMA arch")
    await conn.execute(f"CREATE TABLE arch.{held} (x int)")
    live_oid = await oid(conn, "public.song_identity")
    with pytest.raises(ShipRefused):
        await go(conn)
    assert await oid(conn, "public.song_identity") == live_oid
    assert await numbers(conn) == {num(1): ("w:one", 1011)}


@pytest.mark.parametrize(
    "names",
    [
        {"ship": "public"},
        {"generation": "public"},
        {"archive": "public"},
        {"archive": "ship"},
        {"archive": "gen"},
        {"generation": "ship"},
        {"ship": 'ship"; DROP TABLE x; --'},
        {"archive": "Arch"},
        {"archive": ""},
        {"generation": "gen x"},
        {"archive": "a" * 64},
        {"archive": "1arch"},
    ],
)
async def test_bad_or_repeated_schema_names_refuse(conn, names):
    await both(conn, 1, "w:one", 11)
    await refused(conn, **names)


async def test_longest_schema_name_is_accepted(conn):
    await both(conn, 1, "w:one", 11)
    name = "a" * 63
    await adopt(conn, ship="ship", generation="gen", archive=name)
    assert await oid(conn, f"{name}.song_identity") is not None


@pytest.mark.parametrize("table", ["song_identity", "song_alias"])
async def test_view_bound_to_a_live_table_refuses(conn, table):
    await both(conn, 1, "w:one", 11)
    await live(conn, 5, "w:late", 1005)
    await conn.execute(
        f"CREATE VIEW public.zz_peek AS SELECT song_id FROM public.{table}"
    )
    await refused(conn)


async def test_catalog_views_still_read_after_the_swap(conn):
    await both(conn, 1, "w:one", 11)
    await go(conn)
    assert await conn.fetchval("SELECT count(*) FROM public.catalog_song") == 0


async def test_refusal_inside_callers_transaction_leaves_it_usable(conn):
    await both(conn, 1, "w:one", 11)
    await conn.execute("INSERT INTO gen.song (id) VALUES (12)")
    with pytest.raises(ShipRefused):
        await go(conn)
    await conn.execute("DELETE FROM gen.song WHERE id = 12")
    await go(conn)
    assert await numbers(conn) == {num(1): ("w:one", 11)}


async def test_public_cannot_be_the_ship_schema_even_when_it_would_fit(conn):
    await live(conn, 1, "w:one", 11)
    await conn.execute("INSERT INTO gen.song (id) VALUES (11)")
    await refused(conn, ship="public")


async def test_public_cannot_be_the_generation_schema_even_when_it_would_fit(conn):
    await live(conn, 1, "w:one", 1001)
    await shipped(conn, 1, "w:one", None)
    await conn.execute("TRUNCATE public.song CASCADE")
    await refused(conn, generation="public")


async def test_callers_search_path_is_respected_and_left_alone(conn):
    await both(conn, 1, "w:one", 11)
    await pref(conn, 1)
    await conn.execute("SET LOCAL search_path = gen, ship")
    await go(conn)
    assert await conn.fetchval("SHOW search_path") == "gen, ship"
    target = await conn.fetchval(
        """SELECT confrelid FROM pg_constraint
           WHERE conrelid = 'public.edition_preference'::regclass AND contype = 'f'"""
    )
    assert target == await oid(conn, "public.song_identity")


async def test_database_error_midway_leaves_callers_transaction_usable(conn):
    await both(conn, 1, "w:one", 11)
    await live(conn, 5, "w:late", 1005)
    await conn.execute(
        "ALTER TABLE ship.song_identity ADD CONSTRAINT zz_no_late CHECK (identity_key <> 'w:late')"
    )
    live_oid = await oid(conn, "public.song_identity")
    with pytest.raises(asyncpg.CheckViolationError):
        await go(conn)
    assert await oid(conn, "public.song_identity") == live_oid
    assert await numbers(conn, "ship") == {num(1): ("w:one", 11)}
    assert await oid(conn, "arch.song_identity") is None


# --- second look: the shipped tables must be built like the live ones ---------------------------


@pytest.mark.parametrize("table", ["song_identity", "song_alias"])
async def test_shipped_table_without_its_indexes_refuses(conn, table):
    await both(conn, 1, "w:one", 11)
    await conn.execute("DROP TABLE ship.song_alias")
    if table == "song_identity":
        await conn.execute("DROP TABLE ship.song_identity")
        await conn.execute(
            "CREATE TABLE ship.song_identity (LIKE public.song_identity)"
        )
        await conn.execute(
            "INSERT INTO ship.song_identity (song_id, identity_key, v3_song_id) VALUES ($1, 'w:one', 11)",
            num(1),
        )
        await conn.execute(
            "CREATE TABLE ship.song_alias (LIKE public.song_alias INCLUDING ALL)"
        )
    else:
        await conn.execute("CREATE TABLE ship.song_alias (LIKE public.song_alias)")
        await conn.execute(
            "ALTER TABLE ship.song_alias ADD CONSTRAINT ship_alias_fk"
            " FOREIGN KEY (song_id) REFERENCES ship.song_identity (song_id)"
        )
    await refused(conn)


async def test_shipped_table_missing_one_unique_index_refuses(conn):
    await both(conn, 1, "w:one", 11)
    name = await conn.fetchval(
        """SELECT indexrelid::regclass::text FROM pg_index
           WHERE indrelid = 'ship.song_identity'::regclass AND indpred IS NOT NULL"""
    )
    await conn.execute(f"DROP INDEX {name}")
    await refused(conn)


async def test_shipped_aliases_without_a_foreign_key_refuse_even_when_rows_fit(conn):
    await both(conn, 1, "w:one", 11)
    await alias(conn, "ship", 1, track=3)
    await conn.execute("ALTER TABLE ship.song_alias DROP CONSTRAINT ship_alias_fk")
    await refused(conn)


@pytest.mark.parametrize("table", ["song_identity", "song_alias"])
async def test_trigger_on_a_live_table_refuses(conn, table):
    await both(conn, 1, "w:one", 11)
    await conn.execute(
        "CREATE FUNCTION public.zz_noop() RETURNS trigger LANGUAGE plpgsql AS 'BEGIN RETURN NEW; END'"
    )
    await conn.execute(
        f"CREATE TRIGGER zz_watch BEFORE INSERT ON public.{table}"
        " FOR EACH ROW EXECUTE FUNCTION public.zz_noop()"
    )
    await refused(conn)
