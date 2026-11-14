-- V4 mapping store (FT-020): which catalog song a torrent release provides.
-- One row per feed topic. A rebuild (app.v4_link) writes into a staging table
-- release_mapping_load and swaps it in in one transaction, so a rebuild
-- replaces rows instead of adding to them; the staging table only exists
-- during the rebuild, like song_load. Read-only clients get only the public
-- columns (see app.v4_link.get_mapping); topic_id, info_hash and file_index
-- are source IDs and stay internal.

CREATE TABLE IF NOT EXISTS release_mapping (
    fingerprint text PRIMARY KEY,
    topic_id bigint,
    edition_id uuid NOT NULL,
    version_id uuid NOT NULL,
    song_id bigint NOT NULL,
    confidence double precision NOT NULL,
    reason text NOT NULL,
    state text NOT NULL CHECK (state IN ('linked', 'candidate')),
    artist_mbid uuid,
    album text,
    track_count integer,
    position integer,
    year integer,
    duration_ms integer,
    info_hash text,
    file_index integer
);
