-- FT-558: lists show only artists known to Last.fm (found = true).
-- If Last.fm has no found artists, all names stay listed.
ALTER TABLE public.catalog_open_names ADD COLUMN IF NOT EXISTS listed boolean NOT NULL DEFAULT true;

CREATE OR REPLACE FUNCTION public.prepare_catalog_open_names()
RETURNS void LANGUAGE plpgsql
SET work_mem = '256MB'
-- Materialized CTEs carry no statistics: the planner takes ~750k names for 200
-- and probes indexes per name. Production 01.10: over 5 min with nested loops,
-- 29 s without.
SET enable_nestloop = off
AS $$
BEGIN
    -- Deliberately follow the caller's search_path: mbcopy prepares a staged
    -- generation here, BEFORE taking public-table publication locks.
    -- catalog_artists remains shared in public. Pending tables are session-local.
    PERFORM pg_advisory_xact_lock(17017);
    CREATE TEMP TABLE IF NOT EXISTS catalog_open_names_pending (name text PRIMARY KEY, mbid uuid, listed boolean NOT NULL DEFAULT true);
    ALTER TABLE pg_temp.catalog_open_names_pending ADD COLUMN IF NOT EXISTS listed boolean NOT NULL DEFAULT true;
    CREATE TEMP TABLE IF NOT EXISTS catalog_open_genres_pending (LIKE public.catalog_open_genres INCLUDING INDEXES);
    CREATE TEMP TABLE IF NOT EXISTS catalog_open_names_pending_state (ready boolean PRIMARY KEY);
    TRUNCATE pg_temp.catalog_open_names_pending, pg_temp.catalog_open_genres_pending,
             pg_temp.catalog_open_names_pending_state;
    INSERT INTO pg_temp.catalog_open_names_pending (name, mbid, listed)
    WITH names AS MATERIALIZED (
        SELECT DISTINCT name FROM public.catalog_artists
    ), spellings AS MATERIALIZED (
        -- Python str.strip() whitespace, as used by get_artist, not norm().
        SELECT name, lower(btrim(name,
            U&' \0009\000a\000b\000c\000d\001c\001d\001e\001f\0085\00a0\1680\2000\2001\2002\2003\2004\2005\2006\2007\2008\2009\200a\2028\2029\202f\205f\3000')) AS wanted
        FROM names
    ), wanted AS MATERIALIZED (
        SELECT DISTINCT wanted,
            replace(replace(replace(wanted, E'\\', E'\\\\'), '%', E'\\%'), '_', E'\\_') AS exact
        FROM spellings WHERE wanted <> ''
    ), exact_matches AS MATERIALIZED (
        -- Equality joins first. ILIKE is evaluated only on the matched rows,
        -- never as a trigram lookup repeated for every catalog spelling.
        SELECT w.wanted, w.exact, a.mbid, a.name FROM wanted w
        JOIN mb_artist a ON lower(a.name) = w.wanted
    ), exact AS MATERIALIZED (
        SELECT wanted, mbid FROM exact_matches WHERE name ILIKE exact
    ), sorted AS MATERIALIZED (
        SELECT w.wanted, a.mbid FROM wanted w
        JOIN mb_artist a ON lower(a.sort_name) = w.wanted
        WHERE NOT EXISTS (SELECT 1 FROM exact e WHERE e.wanted = w.wanted)
    ), alias_matches AS MATERIALIZED (
        SELECT w.wanted, w.exact, a.mbid, al.name FROM wanted w
        JOIN mb_artist_alias al ON lower(al.name) = w.wanted
        JOIN mb_artist a ON a.mbid = al.artist_mbid
        WHERE NOT EXISTS (SELECT 1 FROM exact e WHERE e.wanted = w.wanted)
          AND NOT EXISTS (SELECT 1 FROM sorted s WHERE s.wanted = w.wanted)
    ), candidates AS MATERIALIZED (
        SELECT * FROM exact UNION SELECT * FROM sorted
        UNION SELECT wanted, mbid FROM alias_matches WHERE name ILIKE exact
    ), ambiguous AS MATERIALIZED (
        SELECT wanted FROM candidates GROUP BY wanted HAVING count(*) > 1
    ), ambiguous_ids AS MATERIALIZED (
        SELECT DISTINCT c.mbid FROM candidates c JOIN ambiguous a USING (wanted)
    ), release_counts AS MATERIALIZED (
        -- Only namesakes need ranking; count all their groups, including singles.
        SELECT g.artist_mbid, count(*) AS releases FROM mb_release_group g
        JOIN ambiguous_ids c ON c.mbid = g.artist_mbid GROUP BY g.artist_mbid
    ), resolved AS MATERIALIZED (
        SELECT DISTINCT ON (c.wanted) c.wanted, c.mbid
        FROM candidates c LEFT JOIN release_counts n ON n.artist_mbid = c.mbid
        ORDER BY c.wanted, coalesce(n.releases, 0) DESC, c.mbid
    ), winner_groups AS MATERIALIZED (
        -- Check discography only for resolved winners, never the whole copy.
        SELECT g.mbid, g.artist_mbid FROM mb_release_group g
        JOIN (SELECT DISTINCT mbid FROM resolved) c ON c.mbid = g.artist_mbid
        WHERE (g.primary_type IN ('Album', 'EP') OR g.primary_type IS NULL)
          AND (g.secondary_types = '{}' OR g.secondary_types IS NULL)
    ), albums AS MATERIALIZED (
        SELECT DISTINCT g.artist_mbid FROM winner_groups g
        JOIN mb_release r ON r.group_mbid = g.mbid WHERE r.status = 'Official'
          -- FT-538: an album with no track list opens empty; it doesn't count.
          AND EXISTS (SELECT 1 FROM mb_medium m JOIN mb_track t ON t.medium_id = m.id
                      WHERE m.release_mbid = r.mbid)
    ), has_lastfm AS MATERIALIZED (
        SELECT EXISTS (SELECT 1 FROM public.lastfm_artists l WHERE l.found = true) AS active
    ), lastfm_known AS MATERIALIZED (
        SELECT DISTINCT c.name
        FROM public.catalog_artists c
        JOIN public.lastfm_artists l ON l.artist_key = c.artist_key
        WHERE l.found = true
    )
    SELECT s.name, r.mbid,
           (NOT h.active OR k.name IS NOT NULL) AS listed
    FROM spellings s
    JOIN resolved r ON r.wanted = s.wanted
    JOIN albums a ON a.artist_mbid = r.mbid
    CROSS JOIN has_lastfm h
    LEFT JOIN lastfm_known k ON k.name = s.name;
    ANALYZE pg_temp.catalog_open_names_pending;
    -- Cache counts too: /v1/genres must not join three million artist rows.
    INSERT INTO pg_temp.catalog_open_genres_pending (country, slug, artists)
    SELECT CASE WHEN grouping(c.iso) = 1 THEN '' ELSE coalesce(c.iso, 'unknown') END,
           g.slug, count(DISTINCT lower(a.name))::integer
    FROM artist_genre g JOIN mb_artist a ON a.mbid = g.artist_mbid
    JOIN pg_temp.catalog_open_names_pending o ON o.name = a.name AND o.mbid = g.artist_mbid
    LEFT JOIN artist_country c ON c.artist_mbid = g.artist_mbid
    WHERE g.is_primary AND o.listed
    GROUP BY GROUPING SETS ((g.slug), (g.slug, c.iso));
    INSERT INTO pg_temp.catalog_open_names_pending_state VALUES (true);
END
$$;

CREATE OR REPLACE FUNCTION public.publish_catalog_open_names()
RETURNS void LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    -- Only copying precomputed rows happens under mbcopy's publication locks.
    PERFORM pg_advisory_xact_lock(17017);
    DELETE FROM public.catalog_open_names;
    INSERT INTO public.catalog_open_names (name, mbid, listed)
        SELECT name, mbid, listed FROM pg_temp.catalog_open_names_pending;
    DELETE FROM public.catalog_open_genres;
    INSERT INTO public.catalog_open_genres SELECT * FROM pg_temp.catalog_open_genres_pending;
    ANALYZE public.catalog_open_names;
    TRUNCATE pg_temp.catalog_open_names_pending, pg_temp.catalog_open_genres_pending,
             pg_temp.catalog_open_names_pending_state;
END
$$;
