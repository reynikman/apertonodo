-- FT-622 (R-A87): "Report a Problem" — ingested on self-hosted server.
-- Reason and location come from closed lists, each location has its id. Extra
-- fields (locator, source address) are rejected at ingress and do not reach here.
-- Neither IP nor source addresses: report is about what user heard, not
-- where audio came from. Text and artist name do not go into logs.

CREATE TABLE IF NOT EXISTS problem_reports (
    id bigserial PRIMARY KEY,
    created_at timestamptz NOT NULL DEFAULT now(),
    user_id uuid,
    reason text NOT NULL,
    place text NOT NULL,
    track_id uuid,
    album_id uuid,
    playlist_id uuid,
    artist text,
    text text,
    app_version text NOT NULL
);
-- Limit of "at most 20 per hour per user" is computed using this index.
CREATE INDEX IF NOT EXISTS problem_reports_user_idx ON problem_reports (user_id, created_at);