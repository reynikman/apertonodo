CREATE TABLE IF NOT EXISTS downloads (
    id bigint GENERATED ALWAYS AS IDENTITY UNIQUE,
    user_id uuid NOT NULL,
    track_id uuid NOT NULL,
    state text NOT NULL DEFAULT 'queued'
        CHECK (state IN ('queued', 'preparing', 'ready', 'failed')),
    source_locator text,
    file_index integer CHECK (file_index >= 0),
    media_path text,
    format text CHECK (format IN ('mp3', 'opus', 'flac', 'm4a')),
    bytes bigint CHECK (bytes >= 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, track_id)
);

CREATE INDEX IF NOT EXISTS downloads_pending_idx ON downloads (id)
    WHERE state IN ('queued', 'preparing');
