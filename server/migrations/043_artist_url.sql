-- FT-578 (R-A83): official artist links from own copy of MusicBrainz.
--
-- mb_artist_url is populated by app/mbcopy.py loader on each dump load
-- (twin mb_artist_url_new replaces this table in its transaction),
-- so here it is empty, like all mb_* in 019_mb.sql. kind — 'official',
-- 'youtube' and 'social', by link_type.gid from dump. Other relation types
-- (Discogs and others) are not loaded.
CREATE TABLE IF NOT EXISTS mb_artist_url (
    artist_mbid uuid NOT NULL,
    kind text NOT NULL,
    url text NOT NULL,
    PRIMARY KEY (artist_mbid, kind, url)
);

-- Artist subscription feeds: artist_mbid — artist whose official links
-- created the feed (FT-578), for custom user feeds it is empty.
ALTER TABLE news_channels ADD COLUMN IF NOT EXISTS artist_mbid uuid;
