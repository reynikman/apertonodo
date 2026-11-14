"""FT-679: permanent song numbers survive merges and splits between MusicBrainz dumps.

Everything is set-based: temp tables, plain joins, no loop over songs. The work
runs in the caller's transaction and commits nothing.
"""

from __future__ import annotations

import asyncpg

from app.canonical import canonical_key_sql
from app.catalog_songs import title_key_sql

TEMP_TABLES = (
    "sn_keys",
    "sn_cand",
    "sn_won",
    "sn_assign",
    "sn_final",
    "sn_move",
    "sn_num",
    "sn_pref",
)


class IdentityConflict(ValueError):
    pass


async def assign(
    conn: asyncpg.Connection, only_song_id: int | None = None
) -> dict[str, int]:
    for table in TEMP_TABLES:
        await conn.execute(f"DROP TABLE IF EXISTS pg_temp.{table}")

    # Keys of the songs in scope.
    key = (
        "CASE WHEN s.work_mbid IS NOT NULL "
        "THEN 'w:' || s.artist_mbid::text || ':' || s.work_mbid::text "
        f"ELSE 't:' || s.artist_mbid::text || ':' || ({title_key_sql('s.title')}) END"
    )
    await conn.execute(
        f"CREATE TEMP TABLE sn_keys ON COMMIT DROP AS "
        f"SELECT s.id AS song_id, {key} AS identity_key FROM song s "
        f"WHERE ($1::bigint IS NULL OR s.id = $1)",
        only_song_id,
    )
    await conn.execute("CREATE UNIQUE INDEX ON sn_keys (song_id)")
    await conn.execute("CREATE INDEX ON sn_keys (identity_key)")
    await conn.execute("ANALYZE sn_keys")

    if await conn.fetchval(
        "SELECT EXISTS (SELECT 1 FROM sn_keys GROUP BY identity_key HAVING count(*) > 1)"
    ):
        raise IdentityConflict("two songs share one identity key")
    if only_song_id is not None and await conn.fetchval(
        "SELECT EXISTS (SELECT 1 FROM sn_keys k JOIN public.song_identity i "
        "ON i.identity_key = k.identity_key "
        "WHERE i.v3_song_id IS NOT NULL AND i.v3_song_id <> $1)",
        only_song_id,
    ):
        raise IdentityConflict("the key is held by another live song")

    # Candidates: numbers carried by the song's recordings (votes) and the number owning its key.
    # In one-song mode a number held by another live song is not a candidate.
    await conn.execute(
        """CREATE TEMP TABLE sn_cand ON COMMIT DROP AS
        SELECT c.song_id, c.num, sum(c.votes)::integer AS votes, bool_or(c.is_key) AS is_key
        FROM (
            SELECT v.song_id, a.song_id AS num, 1 AS votes, false AS is_key
            FROM song_version v
            JOIN sn_keys k ON k.song_id = v.song_id
            JOIN public.song_alias a ON a.old_track_id = v.recording_mbid
            UNION ALL
            SELECT k.song_id, i.song_id, 0, true
            FROM sn_keys k JOIN public.song_identity i ON i.identity_key = k.identity_key
        ) c
        JOIN public.song_identity n ON n.song_id = c.num
        WHERE ($1::bigint IS NULL OR n.v3_song_id IS NULL OR n.v3_song_id = $1)
        GROUP BY c.song_id, c.num""",
        only_song_id,
    )
    await conn.execute("CREATE INDEX ON sn_cand (num)")
    await conn.execute("CREATE INDEX ON sn_cand (song_id)")
    await conn.execute("ANALYZE sn_cand")

    # Rule 1: one winning song per number.
    await conn.execute(
        """CREATE TEMP TABLE sn_won ON COMMIT DROP AS
        SELECT DISTINCT ON (num) num, song_id, votes, is_key
        FROM sn_cand ORDER BY num, votes DESC, is_key DESC, song_id"""
    )
    await conn.execute("CREATE INDEX ON sn_won (song_id)")
    await conn.execute("ANALYZE sn_won")

    # Rule 2: a song keeps one of the numbers it won.
    await conn.execute(
        """CREATE TEMP TABLE sn_assign ON COMMIT DROP AS
        SELECT DISTINCT ON (w.song_id) w.song_id, w.num
        FROM sn_won w ORDER BY w.song_id, w.votes DESC, w.is_key DESC, w.num"""
    )
    await conn.execute("CREATE UNIQUE INDEX ON sn_assign (num)")
    await conn.execute("CREATE UNIQUE INDEX ON sn_assign (song_id)")
    await conn.execute("ANALYZE sn_assign")

    # Rule 3: final number of every song; outcome kept / split / new.
    await conn.execute(
        """CREATE TEMP TABLE sn_final ON COMMIT DROP AS
        SELECT k.song_id, COALESCE(a.num, gen_random_uuid()) AS num, k.identity_key,
               CASE WHEN a.num IS NOT NULL THEN 'kept'
                    WHEN EXISTS (SELECT 1 FROM sn_cand c WHERE c.song_id = k.song_id) THEN 'split'
                    ELSE 'new' END AS outcome
        FROM sn_keys k LEFT JOIN sn_assign a ON a.song_id = k.song_id"""
    )
    await conn.execute("CREATE UNIQUE INDEX ON sn_final (song_id)")
    await conn.execute("CREATE UNIQUE INDEX ON sn_final (num)")
    await conn.execute("ANALYZE sn_final")

    # Rule 4: retired numbers and where their aliases / edition choices go.
    await conn.execute(
        """CREATE TEMP TABLE sn_move ON COMMIT DROP AS
        SELECT w.num AS old_num, f.num AS new_num
        FROM sn_won w JOIN sn_final f ON f.song_id = w.song_id
        WHERE NOT EXISTS (SELECT 1 FROM sn_assign a WHERE a.num = w.num)"""
    )
    await conn.execute("CREATE UNIQUE INDEX ON sn_move (old_num)")
    await conn.execute("ANALYZE sn_move")

    # Rule 6: numbers whose key or live song row changes.
    await conn.execute(
        """CREATE TEMP TABLE sn_num ON COMMIT DROP AS
        SELECT i.song_id, f.identity_key AS target_key, f.song_id AS target_v3,
               i.identity_key IS DISTINCT FROM f.identity_key AS key_changes
        FROM sn_final f JOIN public.song_identity i ON i.song_id = f.num
        WHERE f.outcome = 'kept'
        UNION ALL
        SELECT i.song_id, 'retired:' || i.song_id::text, NULL, true
        FROM sn_move m JOIN public.song_identity i ON i.song_id = m.old_num
        WHERE EXISTS (SELECT 1 FROM sn_keys k WHERE k.identity_key = i.identity_key)"""
    )
    await conn.execute("CREATE UNIQUE INDEX ON sn_num (song_id)")
    await conn.execute("ANALYZE sn_num")

    counts = await conn.fetchrow(
        """SELECT (SELECT count(*) FROM sn_final) AS songs,
                  (SELECT count(*) FROM sn_final WHERE outcome = 'kept') AS kept,
                  (SELECT count(*) FROM sn_final WHERE outcome = 'new') AS new,
                  (SELECT count(*) FROM sn_final WHERE outcome = 'split') AS split,
                  (SELECT count(*) FROM sn_move) AS merged"""
    )
    assert counts is not None

    # Free song rows and keys first (unique indexes are checked row by row), then take them.
    await conn.execute(
        "UPDATE public.song_identity i SET v3_song_id = NULL "
        "WHERE i.v3_song_id IS NOT NULL AND ($1::bigint IS NULL OR i.v3_song_id = $1) "
        "AND NOT EXISTS (SELECT 1 FROM sn_num n WHERE n.song_id = i.song_id "
        "AND n.target_v3 = i.v3_song_id)",
        only_song_id,
    )
    await conn.execute(
        "UPDATE public.song_identity i "
        "SET identity_key = 'retired:' || i.song_id::text "
        "FROM sn_num n WHERE n.song_id = i.song_id AND n.key_changes"
    )
    await conn.execute(
        "UPDATE public.song_identity i "
        "SET identity_key = n.target_key, v3_song_id = n.target_v3 "
        "FROM sn_num n WHERE n.song_id = i.song_id "
        "AND (i.identity_key IS DISTINCT FROM n.target_key "
        "OR i.v3_song_id IS DISTINCT FROM n.target_v3)"
    )
    await conn.execute(
        "INSERT INTO public.song_identity (song_id, identity_key, v3_song_id) "
        "SELECT num, identity_key, song_id FROM sn_final WHERE outcome <> 'kept'"
    )

    if counts["merged"]:
        await _move_edition_choices(conn)
        await conn.execute(
            "UPDATE public.song_alias a SET song_id = m.new_num "
            "FROM sn_move m WHERE a.song_id = m.old_num"
        )

    # Rule 8: aliases as in the old step, from the final numbers.
    await conn.execute(
        "INSERT INTO public.song_alias (old_track_id, song_id) "
        "SELECT v.recording_mbid, f.num FROM song_version v "
        "JOIN sn_final f ON f.song_id = v.song_id "
        "ON CONFLICT (old_track_id) WHERE old_track_id IS NOT NULL "
        "DO UPDATE SET song_id = EXCLUDED.song_id "
        "WHERE public.song_alias.song_id IS DISTINCT FROM EXCLUDED.song_id"
    )
    key_sql = canonical_key_sql("artist.name", "recording.title")
    await conn.execute(
        "WITH aliases AS ("
        f"SELECT {key_sql} AS old_canonical_key, f.num AS song_id "
        "FROM song_version v JOIN sn_final f ON f.song_id = v.song_id "
        "JOIN mb_recording recording ON recording.mbid = v.recording_mbid "
        "JOIN mb_artist artist ON artist.mbid = recording.artist_mbid"
        "), unique_aliases AS ("
        "SELECT old_canonical_key, min(song_id::text)::uuid AS song_id "
        "FROM aliases GROUP BY old_canonical_key "
        "HAVING count(DISTINCT song_id) = 1"
        ") INSERT INTO public.song_alias (old_canonical_key, song_id) "
        "SELECT old_canonical_key, song_id FROM unique_aliases "
        "ON CONFLICT (old_canonical_key) WHERE old_canonical_key IS NOT NULL DO NOTHING"
    )
    return {
        name: int(counts[name]) for name in ("songs", "kept", "new", "split", "merged")
    }


async def _move_edition_choices(conn: asyncpg.Connection) -> None:
    """Rule 5: per (user, album) the winner's own row stays, else the lowest retired number's."""
    zero = "'00000000-0000-0000-0000-000000000000'::uuid"
    await conn.execute(
        f"""CREATE TEMP TABLE sn_pref ON COMMIT DROP AS
        SELECT e.user_id, e.song_id AS old_num, e.album_id,
               (own.song_id IS NOT NULL) AS has_own,
               row_number() OVER (
                   PARTITION BY e.user_id, m.new_num, COALESCE(e.album_id, {zero})
                   ORDER BY e.song_id
               ) AS rank
        FROM public.edition_preference e
        JOIN sn_move m ON m.old_num = e.song_id
        LEFT JOIN public.edition_preference own
          ON own.song_id = m.new_num AND own.user_id = e.user_id
         AND COALESCE(own.album_id, {zero}) = COALESCE(e.album_id, {zero})"""
    )
    await conn.execute("ANALYZE sn_pref")
    await conn.execute(
        f"DELETE FROM public.edition_preference e USING sn_pref p "
        f"WHERE e.user_id = p.user_id AND e.song_id = p.old_num "
        f"AND COALESCE(e.album_id, {zero}) = COALESCE(p.album_id, {zero}) "
        f"AND (p.has_own OR p.rank > 1)"
    )
    await conn.execute(
        "UPDATE public.edition_preference e SET song_id = m.new_num "
        "FROM sn_move m WHERE e.song_id = m.old_num"
    )
