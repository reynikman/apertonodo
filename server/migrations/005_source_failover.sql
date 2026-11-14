-- What to resume a track with if the playing source goes silent in the middle of it.
-- Before this migration candidate selection only worked until token issuance, and
-- a session remembered exactly one source. If the swarm died in the middle -- audio
-- dropped, and the listener was left to press Retry.
-- There can be no semicolons in comments here: migrate.py splits
-- migrations on them, and half of the comment would become a separate statement.
ALTER TABLE playback_sessions ADD COLUMN IF NOT EXISTS alternates jsonb;
