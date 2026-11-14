-- FT-786: one Play — one row with numbers. Without user, titles or addresses.
CREATE TABLE IF NOT EXISTS play_timing (
    id bigserial PRIMARY KEY,
    at timestamptz NOT NULL DEFAULT now(),
    track_id text NOT NULL,
    source text,
    prepared boolean NOT NULL,
    find_ms integer,
    prepare_ms integer,
    token_ms integer,
    first_byte_ms integer,
    first_256k_ms integer,
    outcome text NOT NULL CHECK (outcome IN
        ('waiting', 'played', 'no_source', 'low_confidence', 'not_ready', 'stalled', 'error'))
);
CREATE INDEX IF NOT EXISTS play_timing_at_idx ON play_timing (at);
