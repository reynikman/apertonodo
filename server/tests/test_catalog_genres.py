"""Own genre tree and country (catalog v2, V2). Does not access network."""

from __future__ import annotations

from pathlib import Path
from uuid import UUID, uuid4

import asyncpg
import pytest

from app.catalog_genres import (
    OUR_SLUGS,
    ROOT_MAP,
    build,
    countries_with_counts,
    country_slice,
    map_genre,
    resolve_country,
)
from app.catalog_browse import get_genres
from app.genres import CATALOG_TO_OUR, GENRE_NAMES
from app.migrate import apply
from app.names import norm

METAL = UUID("11111111-1111-4111-8111-111111111111")
DEATH = UUID("22222222-2222-4222-8222-222222222222")
ROCK = UUID("33333333-3333-4333-8333-333333333333")
ORPHAN = UUID("44444444-4444-4444-8444-444444444444")
SOVIETWAVE = UUID("55555555-5555-4555-8555-555555555555")
JAZZ = UUID("77777777-7777-4777-8777-777777777777")
POP = UUID("88888888-8888-4888-8888-888888888888")
BRAZIL = UUID("99999999-9999-4999-8999-999999999999")
CHANSON = UUID("12121212-1212-4121-8121-121212121212")

ARTIST_DEATH = UUID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1")
ARTIST_MB_WINS = UUID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2")
ARTIST_LASTFM = UUID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3")
ARTIST_RT = UUID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa4")
ARTIST_RU = UUID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa5")
ARTIST_SU = UUID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa6")
ARTIST_FOREIGN_RU_TAG = UUID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa7")
ARTIST_KINO = UUID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa8")
ARTIST_OST = UUID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa9")
ARTIST_WAVE = UUID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa10")
ARTIST_ORPHAN = UUID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa11")
ARTIST_RU_POP = UUID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa12")
ARTIST_US_POP = UUID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa13")
ARTIST_CITY = UUID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa14")
ARTIST_CHANSON = UUID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa15")

AREA_RU = UUID("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1")
AREA_US = UUID("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2")
AREA_LEN = UUID("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb3")
AREA_SU = UUID("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb4")


async def _clear(url: str) -> None:
    conn = await asyncpg.connect(url)
    try:
        for table in (
            "artist_genre",
            "artist_country",
            "our_genre_map",
            "mb_artist_tag",
            "mb_tag",
            "mb_genre_edge",
            "mb_genre",
            "mb_release_group",
            "mb_artist_alias",
            "mb_artist",
            "mb_area_part",
            "mb_area",
            "catalog_artists",
            "lastfm_artists",
        ):
            await conn.execute(f"TRUNCATE {table} CASCADE")
    finally:
        await conn.close()


@pytest.fixture
async def db(postgres_url: str) -> str:
    await apply(postgres_url)
    await _clear(postgres_url)
    return postgres_url


async def _seed_tree(url: str) -> None:
    conn = await asyncpg.connect(url)
    try:
        await conn.executemany(
            "INSERT INTO mb_genre (mbid, name) VALUES ($1, $2)",
            [
                (METAL, "metal"),
                (DEATH, "death metal"),
                (ROCK, "rock"),
                (ORPHAN, "unmapped-fixture-genre"),
                (SOVIETWAVE, "sovietwave"),
                (JAZZ, "jazz"),
                (POP, "pop"),
                (BRAZIL, "brazilian"),
                (CHANSON, "russian chanson"),
            ],
        )
        await conn.execute(
            "INSERT INTO mb_genre_edge (child_mbid, parent_mbid, kind) VALUES ($1, $2, 'subgenre')",
            DEATH,
            METAL,
        )
        await conn.executemany(
            "INSERT INTO mb_area (mbid, name, type, iso3166) VALUES ($1, $2, $3, $4)",
            [
                (AREA_RU, "Russia", "Country", "RU"),
                (AREA_US, "United States", "Country", "US"),
                (AREA_LEN, "Leningrad", "City", None),
                (AREA_SU, "Soviet Union", "Country", "SU"),
            ],
        )
        await conn.execute(
            "INSERT INTO mb_area_part (child_mbid, parent_mbid) VALUES ($1, $2)",
            AREA_LEN,
            AREA_RU,
        )
        artists = [
            (ARTIST_DEATH, "Death Band", AREA_US, None),
            (ARTIST_MB_WINS, "Both Sources", AREA_US, None),
            (ARTIST_LASTFM, "Lastfm Only", AREA_US, None),
            (ARTIST_RT, "Ledger Only", AREA_US, None),
            (ARTIST_RU, "Ru Rock", AREA_RU, None),
            (ARTIST_SU, "Su Metal", AREA_SU, None),
            (ARTIST_FOREIGN_RU_TAG, "Foreign Tagged", AREA_US, None),
            (ARTIST_KINO, "Kino", AREA_SU, AREA_LEN),
            (ARTIST_OST, "Film Composer", AREA_US, None),
            (ARTIST_WAVE, "Wave Act", AREA_RU, None),
            (ARTIST_ORPHAN, "Orphan Act", AREA_US, None),
            (ARTIST_RU_POP, "Ru Pop", AREA_RU, None),
            (ARTIST_US_POP, "Us Pop", AREA_US, None),
            (ARTIST_CITY, "City Band", AREA_LEN, None),
            (ARTIST_CHANSON, "Krug", AREA_RU, None),
        ]
        await conn.executemany(
            "INSERT INTO mb_artist (mbid, name, sort_name, ended, area_mbid, begin_area_mbid) "
            "VALUES ($1, $2, $2, false, $3, $4)",
            artists,
        )
        await conn.execute(
            "INSERT INTO mb_artist_alias (artist_mbid, name, locale, primary_for_locale) "
            "VALUES ($1, 'Кино', 'ru', true)",
            ARTIST_KINO,
        )
        await conn.executemany(
            "INSERT INTO mb_tag (id, name) VALUES ($1, $2)",
            [
                (1, "death metal"),
                (2, "jazz"),
                (3, "metal"),
                (4, "rock"),
                (5, "unmapped-fixture-genre"),
                (6, "sovietwave"),
                (7, "pop"),
                (8, "russian chanson"),
            ],
        )
        await conn.executemany(
            "INSERT INTO mb_artist_tag (artist_mbid, tag_id, count) VALUES ($1, $2, $3)",
            [
                (ARTIST_DEATH, 1, 10),
                (ARTIST_MB_WINS, 2, 5),
                (ARTIST_RU, 4, 8),
                (ARTIST_SU, 3, 9),
                (ARTIST_FOREIGN_RU_TAG, 3, 4),
                (ARTIST_KINO, 4, 7),
                (ARTIST_WAVE, 6, 3),
                (ARTIST_ORPHAN, 5, 2),
                (ARTIST_RU_POP, 7, 6),
                (ARTIST_US_POP, 7, 6),
                (ARTIST_CITY, 4, 3),
                (ARTIST_CHANSON, 8, 11),
            ],
        )
        await conn.execute(
            "INSERT INTO lastfm_artists (artist_key, found, tags) VALUES ($1, true, $2)",
            norm("Both Sources"),
            ["metal"],
        )
        await conn.execute(
            "INSERT INTO lastfm_artists (artist_key, found, tags) VALUES ($1, true, $2)",
            norm("Lastfm Only"),
            ["metal"],
        )
        await conn.execute(
            "INSERT INTO lastfm_artists (artist_key, found, tags) VALUES ($1, true, $2)",
            norm("Foreign Tagged"),
            ["russian rock"],
        )
        await conn.execute(
            "INSERT INTO catalog_artists (genre, artist_key, name, letter, popularity) "
            "VALUES ('heavy-metal', $1, 'Ledger Only', 'T', 100)",
            norm("Ledger Only"),
        )
        await conn.executemany(
            "INSERT INTO mb_release_group (mbid, artist_mbid, title, primary_type, secondary_types) "
            "VALUES ($1, $2, $3, 'Album', $4)",
            [
                (uuid4(), ARTIST_OST, "Score One", ["Soundtrack"]),
                (uuid4(), ARTIST_OST, "Score Two", ["Soundtrack"]),
                (uuid4(), ARTIST_OST, "Songs", []),
            ],
        )
    finally:
        await conn.close()


async def _primary(url: str, artist: UUID) -> tuple[str, str] | None:
    conn = await asyncpg.connect(url)
    try:
        row = await conn.fetchrow(
            "SELECT slug, source FROM artist_genre WHERE artist_mbid = $1 AND is_primary",
            artist,
        )
        return (str(row["slug"]), str(row["source"])) if row else None
    finally:
        await conn.close()


async def _local(url: str, artist: UUID) -> UUID | None:
    conn = await asyncpg.connect(url)
    try:
        value = await conn.fetchval(
            "SELECT mb_genre_mbid FROM artist_genre WHERE artist_mbid = $1 AND is_primary",
            artist,
        )
        return _uuid_or_none(value)
    finally:
        await conn.close()


def _uuid_or_none(value: object) -> UUID | None:
    if value is None:
        return None
    return value if isinstance(value, UUID) else UUID(str(value))


async def _country(url: str, artist: UUID) -> tuple[str, str] | None:
    conn = await asyncpg.connect(url)
    try:
        row = await conn.fetchrow(
            "SELECT iso, source FROM artist_country WHERE artist_mbid = $1",
            artist,
        )
        return (str(row["iso"]), str(row["source"])) if row else None
    finally:
        await conn.close()


async def _primaries(url: str) -> list[int]:
    conn = await asyncpg.connect(url)
    try:
        rows = await conn.fetch(
            "SELECT count(*) AS n FROM artist_genre WHERE is_primary GROUP BY artist_mbid"
        )
        return [int(row["n"]) for row in rows]
    finally:
        await conn.close()


def test_every_catalog_slug_has_our_top() -> None:
    missing = set(GENRE_NAMES) - set(CATALOG_TO_OUR)
    assert missing == set()
    unknown = set(CATALOG_TO_OUR.values()) - OUR_SLUGS
    assert unknown == set()


def test_climb_picks_nearest_mapped_ancestor() -> None:
    roots = {METAL: "metal", ROCK: "rock"}
    parents = {DEATH: [METAL], METAL: [ROCK]}
    assert map_genre(DEATH, roots=roots, parents=parents) == "metal"
    assert map_genre(ORPHAN, roots=roots, parents=parents) is None


def test_regional_itunes_is_not_a_top() -> None:
    assert "brazilian" not in OUR_SLUGS
    assert "russian-rock" not in OUR_SLUGS
    assert "chanson" not in OUR_SLUGS
    assert "estrada" not in OUR_SLUGS
    assert ROOT_MAP["brazilian"] == "latin"
    assert ROOT_MAP["anime"] == "soundtrack"
    assert set(ROOT_MAP.values()) <= OUR_SLUGS


def test_country_prefers_city_over_dissolved() -> None:
    areas = {
        AREA_RU: ("RU", "Russia"),
        AREA_LEN: (None, "Leningrad"),
        AREA_SU: ("SU", "Soviet Union"),
    }
    parts = {AREA_LEN: [AREA_RU]}
    assert resolve_country(AREA_SU, AREA_LEN, areas=areas, parts=parts) == ("RU", "begin_area")
    assert resolve_country(AREA_SU, None, areas=areas, parts=parts) == ("SU", "dissolved")
    assert resolve_country(AREA_LEN, None, areas=areas, parts=parts) == ("RU", "area")
    assert resolve_country(AREA_US, None, areas={AREA_US: ("US", "United States")}, parts={}) == (
        "US",
        "area",
    )


async def test_build_climb_source_order_country_and_local(db: str) -> None:
    await _seed_tree(db)
    summary = await build(db)
    assert await _primary(db, ARTIST_DEATH) == ("metal", "mb")
    assert await _primary(db, ARTIST_MB_WINS) == ("jazz", "mb")
    assert await _primary(db, ARTIST_LASTFM) == ("metal", "lastfm")
    assert await _primary(db, ARTIST_RT) == ("metal", "forum")
    assert await _primary(db, ARTIST_RU) == ("rock", "mb")
    assert await _primary(db, ARTIST_SU) == ("metal", "mb")
    assert await _primary(db, ARTIST_FOREIGN_RU_TAG) == ("metal", "mb")
    assert await _primary(db, ARTIST_KINO) == ("rock", "mb")
    assert await _primary(db, ARTIST_OST) == ("soundtrack", "soundtrack")
    assert await _primary(db, ARTIST_WAVE) == ("electronic", "mb")
    assert await _primary(db, ARTIST_RU_POP) == ("pop", "mb")
    assert await _primary(db, ARTIST_US_POP) == ("pop", "mb")
    assert await _primary(db, ARTIST_CHANSON) == ("worldwide", "mb")
    assert await _local(db, ARTIST_CHANSON) == CHANSON
    assert await _local(db, ARTIST_DEATH) == DEATH
    assert await _country(db, ARTIST_KINO) == ("RU", "begin_area")
    assert await _country(db, ARTIST_SU) == ("SU", "dissolved")
    assert await _country(db, ARTIST_CITY) == ("RU", "area")
    assert await _country(db, ARTIST_RU) == ("RU", "area")
    assert set(await _primaries(db)) == {1}
    assert summary["unmapped"] >= 1
    conn = await asyncpg.connect(db)
    try:
        overview = await countries_with_counts(conn)
        ru = await country_slice(conn, "RU")
    finally:
        await conn.close()
    iso_counts = {row["iso"]: int(row["artists"]) for row in overview}
    assert iso_counts["RU"] >= 1
    assert iso_counts["SU"] == 1
    slugs = {row["slug"]: int(row["artists"]) for row in ru["genres"]}
    assert slugs["rock"] >= 1
    assert slugs["pop"] >= 1
    assert any(row["mb_genre_mbid"] == CHANSON for row in ru["local"])


async def test_reload_does_not_duplicate(db: str) -> None:
    await _seed_tree(db)
    await build(db)
    conn = await asyncpg.connect(db)
    try:
        first = int(await conn.fetchval("SELECT count(*) FROM artist_genre") or 0)
        first_c = int(await conn.fetchval("SELECT count(*) FROM artist_country") or 0)
    finally:
        await conn.close()
    await build(db)
    conn = await asyncpg.connect(db)
    try:
        second = int(await conn.fetchval("SELECT count(*) FROM artist_genre") or 0)
        second_c = int(await conn.fetchval("SELECT count(*) FROM artist_country") or 0)
        leftover = await conn.fetch(
            "SELECT tablename FROM pg_tables WHERE schemaname = current_schema() "
            "AND tablename LIKE '%_load'"
        )
    finally:
        await conn.close()
    assert second == first
    assert second_c == first_c
    assert leftover == []
    assert set(await _primaries(db)) == {1}


async def test_crash_during_swap_keeps_previous(db: str) -> None:
    await _seed_tree(db)
    await build(db)
    before = await _primary(db, ARTIST_DEATH)
    conn = await asyncpg.connect(db)
    try:
        maps = int(await conn.fetchval("SELECT count(*) FROM our_genre_map") or 0)
    finally:
        await conn.close()
    import app.catalog_genres as genres

    async def boom() -> None:
        raise RuntimeError("injected")

    genres._swap_hook = boom
    try:
        with pytest.raises(RuntimeError, match="injected"):
            await build(db)
    finally:
        genres._swap_hook = None
    assert await _primary(db, ARTIST_DEATH) == before
    conn = await asyncpg.connect(db)
    try:
        leftover = await conn.fetch(
            "SELECT tablename FROM pg_tables WHERE schemaname = current_schema() "
            "AND tablename LIKE '%_load'"
        )
        maps_after = int(await conn.fetchval("SELECT count(*) FROM our_genre_map") or 0)
    finally:
        await conn.close()
    assert leftover == []
    assert maps_after == maps


async def test_one_primary_index_rejects_a_second(db: str) -> None:
    await _seed_tree(db)
    await build(db)
    conn = await asyncpg.connect(db)
    try:
        name = await conn.fetchval(
            "SELECT indexname FROM pg_indexes "
            "WHERE schemaname = current_schema() AND indexname = 'artist_genre_one_primary'"
        )
        assert name == "artist_genre_one_primary"
        with pytest.raises(asyncpg.UniqueViolationError):
            await conn.execute(
                "INSERT INTO artist_genre (artist_mbid, slug, source, score, is_primary) "
                "VALUES ($1, 'pop', 'lastfm', 1, true)",
                ARTIST_DEATH,
            )
    finally:
        await conn.execute(
            "DELETE FROM artist_genre WHERE artist_mbid = $1 AND slug = 'pop'",
            ARTIST_DEATH,
        )
        await conn.close()


MIGRATION_027 = (Path(__file__).resolve().parents[1] / "migrations" / "027_genre_edge_direction.sql").read_text()


async def test_migration_flips_edges_loaded_upside_down(postgres_url: str) -> None:
    """027: the edges loaded before 30.09 had the subgenre as parent; flipped once."""
    await apply(postgres_url)
    conn = await asyncpg.connect(postgres_url)
    try:
        async with conn.transaction():
            await conn.execute("DELETE FROM mb_genre_edge")
            await conn.execute(
                "INSERT INTO mb_genre_edge (child_mbid, parent_mbid, kind) VALUES ($1, $2, 'subgenre')", METAL, DEATH
            )
            await conn.execute(MIGRATION_027)
            edge = await conn.fetchrow("SELECT child_mbid, parent_mbid FROM mb_genre_edge")
            assert (edge["child_mbid"], edge["parent_mbid"]) == (DEATH, METAL)
            raise _Rollback
    except _Rollback:
        pass
    finally:
        await conn.close()


class _Rollback(Exception):
    pass


def test_big_genres_without_a_path_reach_a_top() -> None:
    # 30.09 (Р-A39): no subgenre path to a root, so their artists fell into
    # "World" — ambient alone was 5 177. Placement follows Apple Music's tree.
    want = {
        "ambient": "electronic",
        "experimental": "electronic",
        "industrial": "electronic",
        "pop rock": "pop",
        "metalcore": "metal",
        "psychedelic": "rock",
        "blues rock": "rock",
        "funk": "rnb",
        "regional mexicano": "latin",
        "noise": "alternative",
    }
    for name, slug in want.items():
        assert ROOT_MAP.get(name) == slug, name


def test_christian_is_not_a_top_genre() -> None:
    # 01.10 (Р-A44): no "Christian" top; its MusicBrainz genres go to the
    # music they sound like.
    assert "christian" not in OUR_SLUGS
    assert "christian" not in set(ROOT_MAP.values())
    want = {
        "christian rock": "rock",
        "christian metal": "metal",
        "christian hardcore": "metal",
        "christian hip hop": "hip-hop",
        "gospel": "rnb",
        "contemporary christian": "pop",
        "praise & worship": "pop",
        "inspirational": "pop",
    }
    for name, slug in want.items():
        assert ROOT_MAP.get(name) == slug, name


async def test_build_drops_a_top_genre_that_left_the_code(db: str) -> None:
    # our_genre is upserted: a slug removed from OUR_GENRES would stay in
    # /v1/genres with 0 artists (production has "christian" from 30.09).
    await _seed_tree(db)
    await build(db)
    conn = await asyncpg.connect(db)
    try:
        await conn.execute(
            "INSERT INTO our_genre (slug, name_en, name_ru, sort) "
            "VALUES ('christian', 'Christian', 'Христианская', 23) ON CONFLICT (slug) DO NOTHING"
        )
    finally:
        await conn.close()
    await build(db)
    conn = await asyncpg.connect(db)
    try:
        slugs = {row["slug"] for row in await conn.fetch("SELECT slug FROM our_genre")}
        listed = [row["id"] for row in await get_genres(conn)]
    finally:
        await conn.close()
    assert slugs == set(OUR_SLUGS)
    assert "christian" not in listed
    assert len(listed) == len(OUR_SLUGS)
