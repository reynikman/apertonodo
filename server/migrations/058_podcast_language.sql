-- FT-737 (Lang-1): podcast feed language from its <language>. NULL — feed was not fetched
-- or language is not specified in it. No index: language filter arrives later (Lang-2).
ALTER TABLE podcast_feeds ADD COLUMN IF NOT EXISTS language text;
