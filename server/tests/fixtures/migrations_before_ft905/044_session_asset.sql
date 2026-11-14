-- FT-589 (R-A88): session played by extension remembers "<name>:<file index>".
-- Empty — legacy path session (rqbit or file). Single nullable column, does
-- not rewrite table.
ALTER TABLE playback_sessions ADD COLUMN IF NOT EXISTS asset text;
