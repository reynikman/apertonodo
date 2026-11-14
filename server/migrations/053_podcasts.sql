-- Podcasts (R-A93, FT-657): feeds, episodes and subscriptions.
--
-- Subscription stores feed URL rather than reference to feed row: personal copy
-- (subscriptions) is restored even without shared tables, feed will fetch itself.
-- Feed and episodes are shared across all server subscribers.

CREATE TABLE IF NOT EXISTS podcast_feeds (
    feed_url text PRIMARY KEY,
    title text NOT NULL,
    author text NOT NULL DEFAULT '',
    description text NOT NULL DEFAULT '',
    image text,
    link text,
    fetched_at timestamptz,
    failures integer NOT NULL DEFAULT 0,
    next_fetch_at timestamptz NOT NULL
);

CREATE TABLE IF NOT EXISTS podcast_episodes (
    feed_url text NOT NULL REFERENCES podcast_feeds (feed_url) ON DELETE CASCADE,
    guid text NOT NULL,
    title text NOT NULL,
    description text NOT NULL DEFAULT '',
    audio_url text NOT NULL,
    audio_type text,
    audio_bytes bigint,
    duration_ms integer,
    published timestamptz,
    image text,
    season integer,
    number integer,
    explicit boolean NOT NULL DEFAULT false,
    place integer NOT NULL,
    first_seen_at timestamptz NOT NULL,
    PRIMARY KEY (feed_url, guid)
);

CREATE INDEX IF NOT EXISTS podcast_episodes_order
    ON podcast_episodes (feed_url, published DESC NULLS LAST, place);

CREATE TABLE IF NOT EXISTS podcast_subscriptions (
    user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    feed_url text NOT NULL,
    added_at timestamptz NOT NULL,
    PRIMARY KEY (user_id, feed_url)
);

CREATE INDEX IF NOT EXISTS podcast_subscriptions_feed ON podcast_subscriptions (feed_url);
