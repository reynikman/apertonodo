"""Song = studio recording, versions (catalog v2, V3). Does not access network."""

from __future__ import annotations

from uuid import UUID, uuid4

import asyncpg
import pytest

from app.catalog_songs import build
from app.migrate import apply

METALLICA = UUID("65f4f0c5-ef9e-490c-aee3-909e7ae6b2ab")
COVER = UUID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1")
TAYLOR = UUID("20244d07-534f-4eff-b4d4-930878889970")
GLUE = UUID("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1")
LIVEONLY = UUID("cccccccc-cccc-4ccc-8ccc-ccccccccccc1")

WORK_SAND = UUID("77777777-7777-4777-8777-777777777777")
WORK_LOVE = UUID("88888888-8888-4888-8888-888888888888")

REC_STUDIO = UUID("11111111-1111-4111-8111-111111111111")
REC_LIVE = UUID("11111111-1111-4111-8111-111111111112")
REC_REMASTER = UUID("11111111-1111-4111-8111-111111111113")
REC_COVER = UUID("11111111-1111-4111-8111-111111111114")
REC_UNPLUGGED = UUID("11111111-1111-4111-8111-111111111115")
REC_GLUE = UUID("22222222-2222-4222-8222-222222222221")
REC_GLUE_LIVE = UUID("22222222-2222-4222-8222-222222222222")
REC_LOVE = UUID("33333333-3333-4333-8333-333333333331")
REC_TV = UUID("33333333-3333-4333-8333-333333333332")
REC_ONLYLIVE = UUID("44444444-4444-4444-8444-444444444441")
REC_SAND_NOWORK = UUID("11111111-1111-4111-8111-111111111116")
OASIS = UUID("39ab1aed-75e0-4140-bd47-540276886b60")
TAIL = UUID("dddddddd-dddd-4ddd-8ddd-ddddddddddd1")
REC_LIVE_FOREVER = UUID("55555555-5555-4555-8555-555555555551")
REC_FOREVER = UUID("55555555-5555-4555-8555-555555555552")
REC_WEMBLEY = UUID("55555555-5555-4555-8555-555555555553")
REC_DASH_REMASTER = UUID("55555555-5555-4555-8555-555555555554")
REC_NAMED_DEMO = UUID("55555555-5555-4555-8555-555555555555")


async def _clear(url: str) -> None:
    conn = await asyncpg.connect(url)
    try:
        for table in (
            "song_version",
            "song",
            "mb_isrc",
            "mb_recording_work",
            "mb_track",
            "mb_medium",
            "mb_release",
            "mb_release_group",
            "mb_recording",
            "mb_work",
            "mb_artist",
        ):
            await conn.execute(f"TRUNCATE {table} CASCADE")
    finally:
        await conn.close()


@pytest.fixture
async def db(postgres_url: str) -> str:
    await apply(postgres_url)
    await _clear(postgres_url)
    return postgres_url


async def _artist(conn: asyncpg.Connection, mbid: UUID, name: str) -> None:
    await conn.execute(
        "INSERT INTO mb_artist (mbid, name, sort_name, ended) VALUES ($1, $2, $2, false)",
        mbid,
        name,
    )


async def _work(conn: asyncpg.Connection, mbid: UUID, title: str) -> None:
    await conn.execute("INSERT INTO mb_work (mbid, title) VALUES ($1, $2)", mbid, title)


async def _recording(
    conn: asyncpg.Connection,
    mbid: UUID,
    artist: UUID,
    title: str,
    *,
    comment: str = "",
    work: UUID | None = None,
    attrs: list[str] | None = None,
) -> None:
    await conn.execute(
        "INSERT INTO mb_recording (mbid, artist_mbid, title, length_ms, comment) "
        "VALUES ($1, $2, $3, 240000, $4)",
        mbid,
        artist,
        title,
        comment,
    )
    if work is not None:
        await conn.execute(
            "INSERT INTO mb_recording_work (recording_mbid, work_mbid, attributes) "
            "VALUES ($1, $2, $3)",
            mbid,
            work,
            attrs or [],
        )


_MEDIUM = [1000]


async def _on_release(
    conn: asyncpg.Connection,
    recording: UUID,
    *,
    artist: UUID,
    title: str,
    year: int,
    primary: str,
    secondary: list[str] | None = None,
    status: str = "Official",
) -> None:
    rg = uuid4()
    rel = uuid4()
    track = uuid4()
    medium = _MEDIUM[0]
    _MEDIUM[0] += 1
    await conn.execute(
        "INSERT INTO mb_release_group "
        "(mbid, artist_mbid, title, primary_type, secondary_types, first_date) "
        "VALUES ($1, $2, $3, $4, $5, $6)",
        rg,
        artist,
        title,
        primary,
        secondary or [],
        f"{year}-01-01",
    )
    await conn.execute(
        "INSERT INTO mb_release (mbid, group_mbid, title, status, date) "
        "VALUES ($1, $2, $3, $4, $5)",
        rel,
        rg,
        title,
        status,
        f"{year}-01-01",
    )
    await conn.execute(
        "INSERT INTO mb_medium (id, release_mbid, position, format) VALUES ($1, $2, 1, 'CD')",
        medium,
        rel,
    )
    await conn.execute(
        "INSERT INTO mb_track (mbid, medium_id, recording_mbid, position, title, length_ms) "
        "VALUES ($1, $2, $3, 1, $4, 240000)",
        track,
        medium,
        recording,
        title,
    )


async def _seed(url: str) -> None:
    conn = await asyncpg.connect(url)
    try:
        await _artist(conn, METALLICA, "Metallica")
        await _artist(conn, COVER, "Cover Band")
        await _artist(conn, TAYLOR, "Taylor Swift")
        await _artist(conn, GLUE, "Glue Act")
        await _artist(conn, LIVEONLY, "Live Only")
        await _work(conn, WORK_SAND, "Enter Sandman")
        await _work(conn, WORK_LOVE, "Love Story")

        await _recording(conn, REC_STUDIO, METALLICA, "Enter Sandman", work=WORK_SAND)
        await _recording(
            conn, REC_LIVE, METALLICA, "Enter Sandman", work=WORK_SAND, attrs=["live"]
        )
        await _recording(
            conn,
            REC_REMASTER,
            METALLICA,
            "Enter Sandman (Remastered 2021)",
            work=WORK_SAND,
        )
        await _recording(
            conn,
            REC_UNPLUGGED,
            METALLICA,
            "Enter Sandman (Unplugged 1999)",
            work=WORK_SAND,
        )
        await _recording(
            conn, REC_COVER, COVER, "Enter Sandman", work=WORK_SAND, attrs=["cover"]
        )
        await _recording(conn, REC_GLUE, GLUE, "Song")
        await _recording(conn, REC_GLUE_LIVE, GLUE, "Song (Live)")
        await _recording(conn, REC_LOVE, TAYLOR, "Love Story", work=WORK_LOVE)
        await _recording(
            conn,
            REC_TV,
            TAYLOR,
            "Love Story (Taylor's Version)",
            comment="Taylor's Version",
            work=WORK_LOVE,
        )
        await _recording(conn, REC_ONLYLIVE, LIVEONLY, "Only Live", comment="live")
        await _recording(conn, REC_SAND_NOWORK, METALLICA, "Enter Sandman (Live)")

        await _on_release(
            conn, REC_STUDIO, artist=METALLICA, title="Metallica", year=1991, primary="Album"
        )
        await _on_release(
            conn,
            REC_STUDIO,
            artist=METALLICA,
            title="Enter Sandman",
            year=1991,
            primary="Single",
        )
        await _on_release(
            conn,
            REC_LIVE,
            artist=METALLICA,
            title="Live",
            year=1999,
            primary="Album",
            secondary=["Live"],
        )
        await _on_release(
            conn,
            REC_REMASTER,
            artist=METALLICA,
            title="Metallica (Remastered 2021)",
            year=2021,
            primary="Album",
        )
        await _on_release(
            conn,
            REC_UNPLUGGED,
            artist=METALLICA,
            title="Unplugged",
            year=1999,
            primary="Album",
            secondary=["Live"],
        )
        await _on_release(
            conn, REC_COVER, artist=COVER, title="Covers", year=2005, primary="Album"
        )
        await _on_release(
            conn, REC_GLUE, artist=GLUE, title="Debut", year=1990, primary="Album"
        )
        await _on_release(
            conn,
            REC_GLUE_LIVE,
            artist=GLUE,
            title="Live",
            year=1995,
            primary="Album",
            secondary=["Live"],
        )
        await _on_release(
            conn, REC_LOVE, artist=TAYLOR, title="Fearless", year=2008, primary="Album"
        )
        await _on_release(
            conn,
            REC_TV,
            artist=TAYLOR,
            title="Fearless (Taylor's Version)",
            year=2021,
            primary="Album",
        )
        await _on_release(
            conn,
            REC_ONLYLIVE,
            artist=LIVEONLY,
            title="Concert",
            year=2000,
            primary="Album",
            secondary=["Live"],
        )
        await _on_release(
            conn,
            REC_SAND_NOWORK,
            artist=METALLICA,
            title="Live",
            year=1999,
            primary="Album",
            secondary=["Live"],
        )
        await conn.execute(
            "INSERT INTO mb_isrc (recording_mbid, isrc) VALUES ($1, 'USPR39105201')",
            REC_STUDIO,
        )
    finally:
        await conn.close()


async def _songs(url: str, artist: UUID, title: str) -> list[asyncpg.Record]:
    conn = await asyncpg.connect(url)
    try:
        return await conn.fetch(
            "SELECT * FROM song WHERE artist_mbid = $1 AND title = $2 ORDER BY id",
            artist,
            title,
        )
    finally:
        await conn.close()


async def _versions(url: str, song_id: int) -> list[asyncpg.Record]:
    conn = await asyncpg.connect(url)
    try:
        return await conn.fetch(
            "SELECT * FROM song_version WHERE song_id = $1 ORDER BY kind, recording_mbid",
            song_id,
        )
    finally:
        await conn.close()


async def test_enter_sandman_one_song_studio_live_remaster(db: str) -> None:
    await _seed(db)
    await build(db)
    songs = await _songs(db, METALLICA, "Enter Sandman")
    assert len(songs) == 1
    song = songs[0]
    assert song["original_recording_mbid"] == REC_STUDIO
    assert song["original_year"] == 1991
    assert song["work_mbid"] == WORK_SAND
    versions = await _versions(db, song["id"])
    by_rec = {row["recording_mbid"]: row for row in versions}
    assert by_rec[REC_STUDIO]["kind"] == "original"
    assert by_rec[REC_LIVE]["kind"] == "live"
    assert by_rec[REC_REMASTER]["kind"] == "remaster"
    assert by_rec[REC_UNPLUGGED]["kind"] == "live"
    kinds = [row["kind"] for row in versions if row["recording_mbid"] == REC_STUDIO]
    assert kinds == ["original"]


async def test_same_recording_album_and_single_one_version(db: str) -> None:
    await _seed(db)
    await build(db)
    conn = await asyncpg.connect(db)
    try:
        n = int(
            await conn.fetchval(
                "SELECT count(*) FROM song_version WHERE recording_mbid = $1", REC_STUDIO
            )
            or 0
        )
    finally:
        await conn.close()
    assert n == 1


async def test_glue_without_work_by_normalized_title(db: str) -> None:
    await _seed(db)
    await build(db)
    conn = await asyncpg.connect(db)
    try:
        rows = await conn.fetch("SELECT * FROM song WHERE artist_mbid = $1", GLUE)
        assert len(rows) == 1
        versions = await conn.fetch(
            "SELECT recording_mbid, kind FROM song_version WHERE song_id = $1",
            rows[0]["id"],
        )
    finally:
        await conn.close()
    by_rec = {row["recording_mbid"]: row["kind"] for row in versions}
    assert by_rec[REC_GLUE] == "original"
    assert by_rec[REC_GLUE_LIVE] == "live"
    assert rows[0]["original_recording_mbid"] == REC_GLUE
    assert rows[0]["work_mbid"] is None


async def test_cover_is_separate_song_same_work(db: str) -> None:
    await _seed(db)
    await build(db)
    own = await _songs(db, METALLICA, "Enter Sandman")
    cover = await _songs(db, COVER, "Enter Sandman")
    assert len(own) == 1
    assert len(cover) == 1
    assert own[0]["id"] != cover[0]["id"]
    assert own[0]["work_mbid"] == cover[0]["work_mbid"] == WORK_SAND
    versions = await _versions(db, cover[0]["id"])
    assert len(versions) == 1
    assert versions[0]["kind"] == "cover"
    assert versions[0]["recording_mbid"] == REC_COVER


async def test_taylors_version_is_rerecording_not_original(db: str) -> None:
    await _seed(db)
    await build(db)
    songs = await _songs(db, TAYLOR, "Love Story")
    assert len(songs) == 1
    assert songs[0]["original_recording_mbid"] == REC_LOVE
    assert songs[0]["original_year"] == 2008
    versions = await _versions(db, songs[0]["id"])
    by_rec = {row["recording_mbid"]: row["kind"] for row in versions}
    assert by_rec[REC_LOVE] == "original"
    assert by_rec[REC_TV] == "rerecording"


async def test_live_only_song_has_no_original(db: str) -> None:
    await _seed(db)
    await build(db)
    conn = await asyncpg.connect(db)
    try:
        rows = await conn.fetch("SELECT * FROM song WHERE artist_mbid = $1", LIVEONLY)
        assert len(rows) == 1
        assert rows[0]["original_recording_mbid"] is None
        versions = await conn.fetch(
            "SELECT kind FROM song_version WHERE song_id = $1", rows[0]["id"]
        )
    finally:
        await conn.close()
    assert [row["kind"] for row in versions] == ["live"]


async def test_reload_does_not_duplicate(db: str) -> None:
    await _seed(db)
    await build(db)
    conn = await asyncpg.connect(db)
    try:
        first_s = int(await conn.fetchval("SELECT count(*) FROM song") or 0)
        first_v = int(await conn.fetchval("SELECT count(*) FROM song_version") or 0)
    finally:
        await conn.close()
    await build(db)
    conn = await asyncpg.connect(db)
    try:
        second_s = int(await conn.fetchval("SELECT count(*) FROM song") or 0)
        second_v = int(await conn.fetchval("SELECT count(*) FROM song_version") or 0)
        leftover = await conn.fetch(
            "SELECT tablename FROM pg_tables WHERE schemaname = current_schema() "
            "AND (tablename LIKE '%_load' OR tablename LIKE 'song_rec' "
            "OR tablename LIKE 'song_first' OR tablename LIKE 'song_studio')"
        )
    finally:
        await conn.close()
    assert second_s == first_s
    assert second_v == first_v
    assert leftover == []


async def test_crash_during_swap_keeps_previous(db: str) -> None:
    await _seed(db)
    await build(db)
    before = await _songs(db, METALLICA, "Enter Sandman")
    import app.catalog_songs as songs

    async def boom() -> None:
        raise RuntimeError("injected")

    songs._swap_hook = boom
    try:
        with pytest.raises(RuntimeError, match="injected"):
            await build(db)
    finally:
        songs._swap_hook = None
    after = await _songs(db, METALLICA, "Enter Sandman")
    assert after[0]["original_recording_mbid"] == before[0]["original_recording_mbid"]
    conn = await asyncpg.connect(db)
    try:
        leftover = await conn.fetch(
            "SELECT tablename FROM pg_tables WHERE schemaname = current_schema() "
            "AND tablename LIKE '%_load'"
        )
    finally:
        await conn.close()
    assert leftover == []


async def _seed_tails(url: str) -> None:
    conn = await asyncpg.connect(url)
    try:
        await _artist(conn, OASIS, "Oasis")
        await _artist(conn, TAIL, "Tail Act")
        await _recording(conn, REC_LIVE_FOREVER, OASIS, "Live Forever")
        await _recording(conn, REC_FOREVER, OASIS, "Forever")
        await _recording(conn, REC_WEMBLEY, TAIL, "Song (Live at Wembley)")
        await _recording(conn, REC_DASH_REMASTER, TAIL, "Song - 2011 Remaster")
        await _recording(conn, REC_NAMED_DEMO, TAIL, "Demo")
        await _on_release(
            conn, REC_LIVE_FOREVER, artist=OASIS, title="Definitely Maybe", year=1994, primary="Album"
        )
        await _on_release(
            conn, REC_FOREVER, artist=OASIS, title="B-sides", year=1995, primary="Album"
        )
        await _on_release(
            conn, REC_WEMBLEY, artist=TAIL, title="Concert", year=1996, primary="Album"
        )
        await _on_release(
            conn, REC_DASH_REMASTER, artist=TAIL, title="Hits", year=2011, primary="Album"
        )
        await _on_release(
            conn, REC_NAMED_DEMO, artist=TAIL, title="Early", year=1990, primary="Album"
        )
    finally:
        await conn.close()


async def test_live_without_work_joins_studio_work_group(db: str) -> None:
    await _seed(db)
    await build(db)
    songs = await _songs(db, METALLICA, "Enter Sandman")
    assert len(songs) == 1
    versions = await _versions(db, songs[0]["id"])
    by_rec = {row["recording_mbid"]: row["kind"] for row in versions}
    assert by_rec[REC_STUDIO] == "original"
    assert by_rec[REC_SAND_NOWORK] == "live"


async def test_live_forever_is_studio_original(db: str) -> None:
    await _seed_tails(db)
    await build(db)
    songs = await _songs(db, OASIS, "Live Forever")
    assert len(songs) == 1
    assert songs[0]["original_recording_mbid"] == REC_LIVE_FOREVER
    assert songs[0]["original_year"] == 1994
    versions = await _versions(db, songs[0]["id"])
    assert len(versions) == 1
    assert versions[0]["kind"] == "original"


async def test_paren_live_at_wembley_is_live(db: str) -> None:
    await _seed_tails(db)
    await build(db)
    conn = await asyncpg.connect(db)
    try:
        kind = await conn.fetchval(
            "SELECT kind FROM song_version WHERE recording_mbid = $1", REC_WEMBLEY
        )
    finally:
        await conn.close()
    assert kind == "live"


async def test_dash_remaster_is_remaster(db: str) -> None:
    await _seed_tails(db)
    await build(db)
    conn = await asyncpg.connect(db)
    try:
        kind = await conn.fetchval(
            "SELECT kind FROM song_version WHERE recording_mbid = $1", REC_DASH_REMASTER
        )
    finally:
        await conn.close()
    assert kind == "remaster"


async def test_live_forever_and_forever_are_two_songs(db: str) -> None:
    await _seed_tails(db)
    await build(db)
    forever = await _songs(db, OASIS, "Forever")
    live_forever = await _songs(db, OASIS, "Live Forever")
    assert len(forever) == 1
    assert len(live_forever) == 1
    assert forever[0]["id"] != live_forever[0]["id"]


async def test_song_named_demo_is_kept(db: str) -> None:
    await _seed_tails(db)
    await build(db)
    conn = await asyncpg.connect(db)
    try:
        rows = await conn.fetch(
            "SELECT s.id, v.kind FROM song s JOIN song_version v ON v.song_id = s.id "
            "WHERE v.recording_mbid = $1",
            REC_NAMED_DEMO,
        )
    finally:
        await conn.close()
    assert len(rows) == 1
    assert rows[0]["kind"] == "original"


LANA = UUID("b7539c32-53e7-4908-bda3-81449c367da6")
PMJ = UUID("eeeeeeee-eeee-4eee-8eee-eeeeeeeee541")
WORK_YOUNG = UUID("8be9c305-200c-482d-a36a-e89c1c9253ac")
REC_YOUNG = UUID("aa9cdaf8-b8f4-42ad-92a3-d0c3d66bfcb1")
REC_YOUNG_PMJ = UUID("66666666-6666-4666-8666-666666666541")


async def test_soundtrack_original_stays_home_over_later_cover(db: str) -> None:
    # FT-541. "Young and Beautiful" by Lana Del Rey was released only on the soundtrack
    # of "The Great Gatsby" (Album + Soundtrack) and on compilations — no clean album
    # exists. The "owner" rule looked only at clean albums, so the owner became
    # Postmodern Jukebox with a 2020 cover, and all Lana's recordings became "covers".
    # Lana's song was left without an original, and pressing play redirected to search.
    conn = await asyncpg.connect(db)
    try:
        await _artist(conn, LANA, "Lana Del Rey")
        await _artist(conn, PMJ, "Postmodern Jukebox")
        await _work(conn, WORK_YOUNG, "Young and Beautiful")
        await _recording(conn, REC_YOUNG, LANA, "Young and Beautiful", work=WORK_YOUNG)
        await _on_release(
            conn, REC_YOUNG, artist=LANA, title="The Great Gatsby", year=2013,
            primary="Album", secondary=["Soundtrack"],
        )
        await _on_release(
            conn, REC_YOUNG, artist=LANA, title="Hits 2014", year=2014,
            primary="Album", secondary=["Compilation"],
        )
        # Cover without cover attribute in MusicBrainz — like PMJ in production.
        await _recording(conn, REC_YOUNG_PMJ, PMJ, "Young and Beautiful", work=WORK_YOUNG)
        await _on_release(
            conn, REC_YOUNG_PMJ, artist=PMJ, title="Vintage Covers", year=2020, primary="Album",
        )
    finally:
        await conn.close()
    await build(db)

    lana = await _songs(db, LANA, "Young and Beautiful")
    assert len(lana) == 1, "Lana has no song 'Young and Beautiful'"
    assert lana[0]["original_recording_mbid"] == REC_YOUNG, (
        "soundtrack recording did not become original — cover was chosen as song owner"
    )
    kinds = {row["recording_mbid"]: row["kind"] for row in await _versions(db, lana[0]["id"])}
    assert kinds.get(REC_YOUNG) == "original"

    pmj = await _songs(db, PMJ, "Young and Beautiful")
    assert len(pmj) == 1
    pmj_kinds = {row["recording_mbid"]: row["kind"] for row in await _versions(db, pmj[0]["id"])}
    assert pmj_kinds.get(REC_YOUNG_PMJ) == "cover", "Postmodern Jukebox recording is a cover, not an original"
