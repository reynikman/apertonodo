CREATE TABLE IF NOT EXISTS source_candidates (
    id uuid PRIMARY KEY,
    track_id uuid NOT NULL,
    adapter text NOT NULL,
    info_hash text NOT NULL,
    file_index integer NOT NULL,
    file_path text NOT NULL,
    size bigint,
    codec_hint text,
    duration_hint integer,
    availability text,
    confidence real NOT NULL,
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (adapter, info_hash, file_index)
);

CREATE TABLE IF NOT EXISTS playback_sessions (
    token_hash text PRIMARY KEY,
    track_id uuid NOT NULL,
    candidate_id uuid,
    state text NOT NULL,
    buffered_ms integer NOT NULL DEFAULT 0,
    started_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL
);
