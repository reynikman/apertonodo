-- FT-520 (R-A55): Play failures during beta — who, when, which song, at which step.
-- Titles are here, not in logs: logs do not carry them (tests/test_privacy.py).

CREATE TABLE IF NOT EXISTS play_failures (
    id bigserial PRIMARY KEY,
    at timestamptz NOT NULL DEFAULT now(),
    user_id uuid,
    kind text NOT NULL,
    track_id text,
    artist text NOT NULL DEFAULT '',
    title text NOT NULL DEFAULT '',
    ref text NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS play_failures_at_idx ON play_failures (at DESC);
