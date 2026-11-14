-- FT-553: depth of Last.fm top tracks with which row was saved.
-- Old rows (saved with TOP_TRACKS = 10) have NULL and are requeried
-- once by worker up to TOP_STORED (50).
ALTER TABLE lastfm_artists ADD COLUMN IF NOT EXISTS top_stored integer;
