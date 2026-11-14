-- FT-022: preferred edition per song. song_id is the permanent identity
-- (song_identity.song_id), never the V3 row id: the catalog rebuild and the MB
-- load drop song and song_version with CASCADE, and no foreign key points at
-- mb_* for the same reason. One owner for now; the future users migration
-- reassigns rows. UNIQUE NULLS NOT DISTINCT: unique per user/song/album even with a NULL album_id.
CREATE TABLE IF NOT EXISTS edition_preference (
    user_id text NOT NULL DEFAULT 'owner',
    song_id uuid NOT NULL REFERENCES song_identity (song_id),
    album_id uuid,
    edition_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE NULLS NOT DISTINCT (user_id, song_id, album_id)
);
