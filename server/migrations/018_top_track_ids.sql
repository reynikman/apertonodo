-- Last.fm top track id -- MusicBrainz recording found by the crawler in advance.
-- Artist page only reads this field and does not query MusicBrainz.
-- Key is normalized title, value is id and duration.
-- NULL -- crawler has not searched yet: it queues such rows immediately, rather
-- than in 90 days (REFRESH). After crawl there is always an object, even if empty.
ALTER TABLE lastfm_artists ADD COLUMN IF NOT EXISTS top_track_ids jsonb;
