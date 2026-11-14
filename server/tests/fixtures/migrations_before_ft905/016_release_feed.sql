-- Fresh releases from feed. Re-importing the dump replaces `releases` entirely,
-- and without a flag rows not yet present in the dump would vanish. false -- row
-- from the dump: the feed does not overwrite it, the dump has a tracklist.
ALTER TABLE releases ADD COLUMN IF NOT EXISTS from_feed boolean NOT NULL DEFAULT false;
