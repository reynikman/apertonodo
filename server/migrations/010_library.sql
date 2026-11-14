-- "My Music" (Phase H): favorites, personal playlists, history.
-- There is only one user, so there is no users table.
--
-- A track is identified by `canonical_key`, not by id. A single song in
-- MusicBrainz has dozens of recordings (Duality -- 30, Nothing Else Matters -- over
-- a hundred), and search id and album page id differ for it. By id a single
-- song would be stored in favorites twice, and the heart on its second recording would
-- be empty. `track_id` is the recording the user added: /v1/playback plays using it.
-- Title and artist are stored as a copy: the track does not disappear from
-- the list even if the server no longer knows it.

CREATE TABLE IF NOT EXISTS favorites (
    canonical_key text PRIMARY KEY,
    track_id uuid NOT NULL,
    title text NOT NULL,
    artist text NOT NULL,
    duration_ms integer NOT NULL,
    added_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS playlists (
    id uuid PRIMARY KEY,
    name text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS playlist_items (
    playlist_id uuid NOT NULL REFERENCES playlists (id) ON DELETE CASCADE,
    canonical_key text NOT NULL,
    position integer NOT NULL,
    track_id uuid NOT NULL,
    title text NOT NULL,
    artist text NOT NULL,
    duration_ms integer NOT NULL,
    PRIMARY KEY (playlist_id, canonical_key)
);

-- History is strictly local and never sent outside: no exports, no outgoing queries with it.
CREATE TABLE IF NOT EXISTS listens (
    id bigserial PRIMARY KEY,
    canonical_key text NOT NULL,
    track_id uuid NOT NULL,
    title text NOT NULL,
    artist text NOT NULL,
    duration_ms integer NOT NULL,
    played_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS listens_played_at_idx ON listens (played_at DESC, id DESC);
