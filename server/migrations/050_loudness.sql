-- FT-635 (R-A94): loudness measurement of finished file for loudness normalization.
-- path — file path on server disk,
-- size, mtime_ns — file size and modification time at measurement time,
-- lufs — integrated loudness (NULL if measurement failed),
-- measured_at — time measurement was performed.

CREATE TABLE IF NOT EXISTS file_loudness (
    path text PRIMARY KEY,
    size bigint NOT NULL,
    mtime_ns bigint NOT NULL,
    lufs real,
    measured_at timestamptz NOT NULL DEFAULT now()
);
