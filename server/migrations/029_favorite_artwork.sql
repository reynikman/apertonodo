-- Favorite artwork: path seen by phone at addition time.
-- Old rows remain empty: artwork was not saved back then.
ALTER TABLE favorites ADD COLUMN IF NOT EXISTS artwork_url text NOT NULL DEFAULT '';
