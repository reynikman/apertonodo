-- Listen artwork: path seen by the phone at the moment of recording.
-- Old rows remain empty: artwork was not saved back then.
ALTER TABLE listens ADD COLUMN IF NOT EXISTS artwork_url text NOT NULL DEFAULT '';
