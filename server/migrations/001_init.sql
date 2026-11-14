CREATE TABLE IF NOT EXISTS tracks (
    id uuid PRIMARY KEY,
    title text NOT NULL,
    artist text NOT NULL,
    duration_ms integer NOT NULL,
    artwork_url text,
    canonical_key text NOT NULL
);

CREATE INDEX IF NOT EXISTS tracks_canonical_key_idx ON tracks (canonical_key);

CREATE TABLE IF NOT EXISTS metadata_cache (
    cache_key text PRIMARY KEY,
    payload jsonb NOT NULL,
    fetched_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL
);
