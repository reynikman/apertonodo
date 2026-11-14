-- Phase D: the server remembers the full album and track permanently.
-- release_files -- file list of the release. It had to be fetched from
-- peers, which took 1.3 s on each tap, even if an adjacent track of the same
-- album had just played from the same release. The release file list never changes,
-- so it is requested only once.
-- track_sources -- track, release, and file index that have already played and whose
-- tags did not specify another track. Replay goes straight there rather than searching
-- anew: previously replay hit other releases and three tracks out of 90 failed to play
-- the second time. When it played is not stored here.
CREATE TABLE IF NOT EXISTS release_files (
    info_hash text PRIMARY KEY,
    files jsonb NOT NULL
);

CREATE TABLE IF NOT EXISTS track_sources (
    track_id uuid PRIMARY KEY,
    info_hash text NOT NULL,
    file_index integer NOT NULL,
    source_locator text NOT NULL
)
;
