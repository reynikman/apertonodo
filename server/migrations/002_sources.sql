-- FT-905: playback sessions only. The old candidate table of the retired source path
-- is no longer created on a fresh install.
CREATE TABLE IF NOT EXISTS playback_sessions (
    token_hash text PRIMARY KEY,
    track_id uuid NOT NULL,
    candidate_id uuid,
    state text NOT NULL,
    buffered_ms integer NOT NULL DEFAULT 0,
    started_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL
);
