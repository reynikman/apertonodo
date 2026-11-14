-- Last.fm for the artist page (Phase F2): top tracks, similar artists, biography.
-- Populated only by the nightly crawler (`app/lastfm.py`), across all popular
-- catalog artists sequentially. Opening a page reads from here and does not
-- query Last.fm. Only needed fields are stored: names, titles, and short text,
-- without images, links, or play counts. Their terms -- no more than 100 MB.
-- Empty fields when found = false: Last.fm does not know this artist.
CREATE TABLE IF NOT EXISTS lastfm_artists (
    artist_key text PRIMARY KEY,
    found boolean NOT NULL,
    bio text,
    top_tracks text[] NOT NULL DEFAULT '{}',
    similar_artists text[] NOT NULL DEFAULT '{}',
    fetched_at timestamptz NOT NULL DEFAULT now()
);
