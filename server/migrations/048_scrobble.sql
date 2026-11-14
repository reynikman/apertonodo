-- FT-631 (R-A94): scrobbles go to ListenBrainz upon user request.
-- Row represents user connection: service and its token. Token is stored
-- in plain text, like the rest of database content, and is never exposed
-- externally. bad — ListenBrainz rejected token: no more outgoing requests until
-- user provides a new one.

CREATE TABLE IF NOT EXISTS scrobble_accounts (
    user_id uuid NOT NULL,
    service text NOT NULL,
    token text NOT NULL,
    bad boolean NOT NULL DEFAULT false,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, service)
);