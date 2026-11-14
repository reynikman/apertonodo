-- FT-787: swarm at file readiness time — numbers and acquisition method, from extension response.
ALTER TABLE play_timing
    ADD COLUMN IF NOT EXISTS peers integer,
    ADD COLUMN IF NOT EXISTS speed_bps integer,
    ADD COLUMN IF NOT EXISTS have_pct smallint,
    ADD COLUMN IF NOT EXISTS via text CHECK (via IN ('link', 'file', 'cache'));
