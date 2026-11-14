-- FT-592 (R-A90): offline download can be held by extension — then instead of release hash here is
-- "<name>:<file index>". Empty — legacy path. Single nullable column, does not rewrite table.
ALTER TABLE downloads ADD COLUMN IF NOT EXISTS asset text;
