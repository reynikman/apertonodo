-- FT-573 (R-A83): ingested news from RSS and Atom.
-- Retention 14 days, duplicate link does not create duplicate row.

CREATE TABLE IF NOT EXISTS news_items (
    id bigserial PRIMARY KEY,
    feed_url text NOT NULL,
    channel text NOT NULL,
    title text NOT NULL,
    text text NOT NULL,
    link text NOT NULL UNIQUE,
    image_url text,
    published timestamptz NOT NULL,
    is_curated boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS news_items_published_idx ON news_items (published DESC);
CREATE INDEX IF NOT EXISTS news_items_feed_url_idx ON news_items (feed_url);
