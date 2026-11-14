-- Song ratings (FT-629, R-A94): stars from one to five and "dislike" mark.
--
-- Song is identified by `canonical_key`, not by id. A single song in catalog has
-- dozens of recordings (album version, single, remaster), and its id from search and
-- album page are different. By id a single song could get different
-- ratings, and rating set on one recording would not be visible on another.
-- Primary key `(user_id, canonical_key)` guarantees exactly one rating per song
-- for each user.
--
-- `track_id` — the recording on which user placed the rating.
-- Title, artist and duration are stored as a copy so the song remains
-- in rated lists even if server no longer serves it from catalog.

CREATE TABLE IF NOT EXISTS ratings (
    user_id uuid NOT NULL,
    canonical_key text NOT NULL,
    track_id uuid NOT NULL,
    title text NOT NULL,
    artist text NOT NULL,
    duration_ms integer NOT NULL,
    stars smallint NOT NULL DEFAULT 0,
    disliked boolean NOT NULL DEFAULT false,
    rated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, canonical_key),
    CONSTRAINT ratings_stars_range CHECK (stars >= 0 AND stars <= 5),
    CONSTRAINT ratings_not_empty CHECK (stars > 0 OR disliked),
    CONSTRAINT ratings_exclusive CHECK (NOT (stars > 0 AND disliked))
);

CREATE INDEX IF NOT EXISTS ratings_user_order_idx
    ON ratings (user_id, disliked, stars DESC, rated_at DESC);
