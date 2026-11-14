-- Podcasts (R-A93, FT-658): episode playback position on server.
--
-- Record is personal and stores feed URL and episode number, not references to feed
-- rows: playback position survives unsubscription and episode dropped from feed.
-- `seq` increments on each accepted record — phone uses it to ask
-- "what changed since last time".

CREATE SEQUENCE IF NOT EXISTS podcast_progress_seq;

CREATE TABLE IF NOT EXISTS podcast_progress (
    user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    feed_url text NOT NULL,
    guid text NOT NULL,
    position_ms integer NOT NULL CHECK (position_ms >= 0),
    done boolean NOT NULL,
    updated_at timestamptz NOT NULL,
    seq bigint NOT NULL,
    PRIMARY KEY (user_id, feed_url, guid)
);

CREATE INDEX IF NOT EXISTS podcast_progress_changes ON podcast_progress (user_id, seq);
