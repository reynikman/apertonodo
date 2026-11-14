-- Phase E: played tracks stay on disk until hitting the storage limit.
-- source_usage -- release for which a token was issued, and when it was played
-- last. The one played longest ago is evicted. pinned -- pinned, never
-- evicted: this will be set by the phone download queue.
-- Releases already remembered by Phase D are treated as played long ago: exactly
-- when is unknown, and they come first in the eviction queue.
CREATE TABLE IF NOT EXISTS source_usage (
    info_hash text PRIMARY KEY,
    last_played_at timestamptz NOT NULL,
    pinned boolean NOT NULL DEFAULT false
);

INSERT INTO source_usage (info_hash, last_played_at)
SELECT DISTINCT lower(info_hash), to_timestamp(0) FROM track_sources
ON CONFLICT (info_hash) DO NOTHING
;
