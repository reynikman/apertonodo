-- FT-645 (R-A96, R-A97, contract D1, item 11, feature B6, step S6b-2):
-- One-time token for connecting Last.fm (auth.getToken / auth.getSession).
-- Lives 60 minutes from created_at, one per user (user_id PRIMARY KEY).
-- Removed after confirmation and replaced with session key in scrobble_accounts.

CREATE TABLE IF NOT EXISTS lastfm_pending (
    user_id uuid PRIMARY KEY,
    token text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
