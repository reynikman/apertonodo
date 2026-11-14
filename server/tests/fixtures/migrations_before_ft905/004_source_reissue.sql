-- To keep the token alive across restarts of not just the server, but rqbit itself.
-- Migration 003 saved rqbit_id, which was enough while rqbit outlived
-- the server. After rqbit restarts the old identifier means nothing: it is
-- either empty or, worse, occupied by another release. Re-fetching a release
-- is only possible via locator, and the hash allows checking first
-- among already added ones without fetching the release payload from the network.
-- There can be no semicolons in comments here: migrate.py splits
-- migrations on them, and half of the comment would become a separate statement.
ALTER TABLE playback_sessions ADD COLUMN IF NOT EXISTS source_locator text;
ALTER TABLE playback_sessions ADD COLUMN IF NOT EXISTS info_hash text;
