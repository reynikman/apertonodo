-- FT-582 (R-A83): curated feed toggle is per-user.
-- Feed is id from curated list (feed URL), row exists only for
-- modified toggle, default state is enabled.

CREATE TABLE IF NOT EXISTS news_curated_pref (
    user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    channel_id text NOT NULL,
    enabled boolean NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, channel_id)
);
