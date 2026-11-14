-- FT-637 (R-A96, R-A97): permanent server installation ID.
-- Table may contain only one row, ID is generated once and
-- survives server restarts.

CREATE TABLE IF NOT EXISTS server_identity (
    is_singleton boolean PRIMARY KEY DEFAULT true CHECK (is_singleton),
    server_id uuid NOT NULL DEFAULT gen_random_uuid(),
    created_at timestamptz NOT NULL DEFAULT now()
);
