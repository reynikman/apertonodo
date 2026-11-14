-- Fresh hash from the daily source API export. As a column in `releases` this
-- would be an UPDATE of a million rows: each new version is written into all
-- indexes again, including tracklists -- longer than seven minutes per night, and
-- the table doubles in size every day. NULL -- section could not be read, no fresh hash.
ALTER TABLE release_seeders ADD COLUMN IF NOT EXISTS info_hash text;
