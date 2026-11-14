-- Search from own list of releases (Phase J).
--
-- Everything here is idempotent and survives repeated execution. `app/migrate.py`
-- joins all files and splits them by semicolon, so neither DO-block
-- nor function fits here -- only separate statements. For the same
-- reason there must be no semicolon inside a comment: it cuts
-- the file in the middle of an explanation, and the fragment goes to the database as a statement.

-- Typos are handled by pg_trgm, not a dedicated search engine (owner decision
-- 20.09.2026: do not install Meilisearch). Version 1.6 exists in the database, was not
-- installed. In compose user `music` is the cluster owner, permissions are sufficient.
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- "metalica" -> Metallica. GIN by trigrams: 406,856 rows, and without an index
-- similarity() would have to be calculated across the entire table on each keystroke.
CREATE INDEX IF NOT EXISTS catalog_artists_trgm
    ON catalog_artists USING gin (artist_key gin_trgm_ops);

-- Typeahead suggestions match the beginning of the name ("lin" -> Linkin Park). Standard
-- btree compares by locale by default and is not suitable for LIKE 'lin%',
-- text_pattern_ops compares byte-by-byte, and such a prefix is searched using it.
CREATE INDEX IF NOT EXISTS catalog_artists_prefix
    ON catalog_artists (artist_key text_pattern_ops);

-- Last.fm listeners -- second half of search ranking weight (first is popularity).
-- They are provided by the same artist.getinfo that the crawler already calls, so no extra
-- outgoing request is made. NULL -- crawler has not reached the artist yet.
ALTER TABLE lastfm_artists ADD COLUMN IF NOT EXISTS listeners bigint;

-- Own tracks for search results. Properly cased titles in own database have
-- exactly one origin -- Last.fm top tracks (release tracklist is stored
-- normalized, there is no raw string in the database). Only a track that
-- has an active release gets here: verified by `catalog.playable`, using the same
-- rule that Play later searches by. Built together with the catalog,
-- `python -m app.catalog build`.
CREATE TABLE IF NOT EXISTS catalog_tracks (
    artist_key text NOT NULL,
    title_key text NOT NULL,
    artist text NOT NULL,
    title text NOT NULL,
    weight bigint NOT NULL,
    PRIMARY KEY (artist_key, title_key)
);

-- Track without artist ("numb"): searched by title prefix, ordered by weight.
CREATE INDEX IF NOT EXISTS catalog_tracks_title
    ON catalog_tracks (title_key text_pattern_ops);

CREATE INDEX IF NOT EXISTS catalog_tracks_weight
    ON catalog_tracks (weight DESC);

-- "linkin park numb" -- query words are split across artist and
-- title, so it is searched across both together rather than in a single field.
CREATE INDEX IF NOT EXISTS catalog_tracks_fts
    ON catalog_tracks USING gin (to_tsvector('simple', artist_key || ' ' || title_key));
