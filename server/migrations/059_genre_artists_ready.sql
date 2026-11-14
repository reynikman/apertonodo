-- FT-766: genre artists — precomputed ordering.
-- Genre screen joined artist_genre with mb_artist (1.5M rows) on every request, after server restart
-- first request took 55 s. Ordering is now prepared upon catalog publication, screen reads
-- only this table. Rule is identical to the previous query in catalog_browse.genre_artists.

CREATE TABLE IF NOT EXISTS public.catalog_genre_artists (
    slug text NOT NULL,
    pos integer NOT NULL,
    name text NOT NULL,
    PRIMARY KEY (slug, pos)
);

-- Row exists — order is prepared and screen reads it, absent — previous live query (database without catalog).
CREATE TABLE IF NOT EXISTS public.catalog_genre_artists_state (
    ready boolean PRIMARY KEY,
    built_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION public.build_catalog_genre_artists()
RETURNS void LANGUAGE plpgsql
SET work_mem = '256MB'
SET search_path = pg_catalog, public
AS $$
BEGIN
    DELETE FROM public.catalog_genre_artists;
    INSERT INTO public.catalog_genre_artists (slug, pos, name)
    SELECT slug,
           row_number() OVER (PARTITION BY slug ORDER BY CASE
               WHEN name ~ '^[A-Za-zÀ-ÖØ-öø-ɏ]' THEN 0
               WHEN name ~ '^[Ѐ-ӿ]' THEN 1 ELSE 2 END,
               name COLLATE "und-x-icu", name)::integer,
           name
    FROM (
        SELECT DISTINCT ON (g.slug, lower(a.name)) g.slug, a.name
        FROM artist_genre g JOIN mb_artist a ON a.mbid = g.artist_mbid
        LEFT JOIN catalog_open_names o ON o.name = a.name
        WHERE g.is_primary
          AND (o.listed OR NOT EXISTS (SELECT 1 FROM catalog_open_names))
          AND (o.mbid IS NULL OR o.mbid = g.artist_mbid)
        ORDER BY g.slug, lower(a.name), a.mbid
    ) one;
    DELETE FROM public.catalog_genre_artists_state;
    INSERT INTO public.catalog_genre_artists_state (ready) VALUES (true);
    ANALYZE public.catalog_genre_artists;
END
$$;

-- Catalog publication (040) + order rebuild in the same transaction.
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
    PERFORM public.build_catalog_genre_artists();
END
$$;

-- Production already has catalog: assemble order immediately upon deploy. Empty database — assemble nothing.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM public.catalog_open_names) THEN
        PERFORM public.build_catalog_genre_artists();
    END IF;
END
$$;
