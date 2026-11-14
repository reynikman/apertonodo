-- Own genre tree and artist country (catalog v2, phase V2).
--
-- Genre and country are different axes. Top is broad genres, without "Russian Rock".
-- Rebuild: `python -m app.catalog_genres build`. No foreign key to mb_*:
-- mbcopy loader does DROP CASCADE on live mb_* and would wipe these tables.
-- Last.fm tags from artist.getinfo are in lastfm_artists.tags column, without URLs.

ALTER TABLE mb_artist ADD COLUMN IF NOT EXISTS begin_area_mbid uuid;

CREATE INDEX IF NOT EXISTS mb_artist_begin_area ON mb_artist (begin_area_mbid);

CREATE TABLE IF NOT EXISTS our_genre (
    slug text PRIMARY KEY,
    name_en text NOT NULL,
    name_ru text NOT NULL,
    sort integer NOT NULL
);

CREATE TABLE IF NOT EXISTS our_genre_map (
    mb_genre_mbid uuid NOT NULL,
    slug text NOT NULL,
    PRIMARY KEY (mb_genre_mbid)
);

CREATE TABLE IF NOT EXISTS artist_genre (
    artist_mbid uuid NOT NULL,
    slug text NOT NULL,
    source text NOT NULL,
    score integer NOT NULL,
    is_primary boolean NOT NULL DEFAULT false,
    mb_genre_mbid uuid,
    PRIMARY KEY (artist_mbid, slug, source)
);

ALTER TABLE artist_genre ADD COLUMN IF NOT EXISTS mb_genre_mbid uuid;

CREATE UNIQUE INDEX IF NOT EXISTS artist_genre_one_primary
    ON artist_genre (artist_mbid) WHERE is_primary;

CREATE INDEX IF NOT EXISTS artist_genre_slug ON artist_genre (slug);

CREATE INDEX IF NOT EXISTS artist_genre_artist ON artist_genre (artist_mbid);

CREATE TABLE IF NOT EXISTS artist_country (
    artist_mbid uuid PRIMARY KEY,
    iso text NOT NULL,
    source text NOT NULL
);

CREATE INDEX IF NOT EXISTS artist_country_iso ON artist_country (iso);

ALTER TABLE lastfm_artists ADD COLUMN IF NOT EXISTS tags text[] NOT NULL DEFAULT '{}';

DROP VIEW IF EXISTS artist_country_local_counts;
DROP VIEW IF EXISTS artist_country_genre_counts;
DROP VIEW IF EXISTS artist_country_counts;
