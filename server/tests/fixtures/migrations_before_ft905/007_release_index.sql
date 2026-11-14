-- Own list of releases: music sections of the RuTracker dump (Phase C).
-- Stores only what is needed to find and obtain the release: hash, title,
-- tracklist lines. There are no private source keys in the dump, locator is assembled
-- from the hash (app/release_index.py). We do not store the full release description.
-- Populated by `python -m app.release_index load`.
CREATE TABLE IF NOT EXISTS releases (
    topic_id bigint PRIMARY KEY,
    info_hash text NOT NULL,
    forum_id integer NOT NULL,
    size_bytes bigint,
    registered_at timestamptz,
    title text NOT NULL,
    title_norm text NOT NULL,
    tracks_norm text NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS releases_title_fts
    ON releases USING gin (to_tsvector('simple', title_norm));

CREATE INDEX IF NOT EXISTS releases_tracks_fts
    ON releases USING gin (to_tsvector('simple', tracks_norm));

-- Seeders are in a separate narrow table, replaced entirely by a background job
-- once a day (`python -m app.release_index seeders`). As a column in `releases` this
-- would be an UPDATE of a million rows: each new row version was written into all
-- indexes again, including tracklists -- on a full dump longer than seven minutes, and
-- the table doubled in size every day.
CREATE TABLE IF NOT EXISTS release_seeders (
    topic_id bigint PRIMARY KEY,
    seeders integer NOT NULL,
    checked_at timestamptz NOT NULL DEFAULT now()
);
