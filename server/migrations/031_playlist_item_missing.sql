-- Missing track remains a playlist row with its random track_id.
-- Old rows reference real tracks.
ALTER TABLE playlist_items ADD COLUMN IF NOT EXISTS missing boolean NOT NULL DEFAULT false;
