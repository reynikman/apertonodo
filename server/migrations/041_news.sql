-- News subscriptions (R-A83, FT-571): artists and custom feeds live under
-- user account on self-hosted server and migrate between phones
-- automatically. Uniqueness per pair "user — artist/feed url": repeated
-- subscription does not duplicate rows. Ingested news tables are in FT-573.

CREATE TABLE IF NOT EXISTS news_follows (
    user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    artist_mbid uuid NOT NULL,
    added_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, artist_mbid)
);

CREATE TABLE IF NOT EXISTS news_channels (
    user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    kind text NOT NULL,
    feed_url text NOT NULL,
    name text NOT NULL,
    added_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, feed_url)
);
