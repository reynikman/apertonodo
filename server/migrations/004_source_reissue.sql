-- To keep the token alive across restarts of the server and of the source engine.
-- Re-fetching an asset is only possible via locator.
-- FT-905: the release key column of the retired source path is not created any more.
-- There can be no semicolons in comments here: migrate.py splits
-- migrations on them, and half of the comment would become a separate statement.
ALTER TABLE playback_sessions ADD COLUMN IF NOT EXISTS source_locator text;
