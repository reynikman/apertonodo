-- FT-639 (R-A96, contract D1): playback report with own sequence number and queue
-- of its delivery to external services.
--
-- play_reports — single song playback start on phone: number given by phone, server
-- distinguishes starts by pair "user + number" and stores the highest number of
-- played milliseconds. play_deliveries — "this playback report x this service":
-- row is created once, in the same transaction as playback report record.
-- dropped — user enabled "do not record" while row waited: it remains
-- so next report of the same playback does not requeue delivery.
-- scrobble_accounts revision — connection revision: any token write
-- (even the same one) and reconnection produce new number, and work started
-- with old key does not continue with new one.

CREATE SEQUENCE IF NOT EXISTS scrobble_account_revision;

ALTER TABLE scrobble_accounts
    ADD COLUMN IF NOT EXISTS revision bigint NOT NULL DEFAULT nextval('scrobble_account_revision');

CREATE OR REPLACE FUNCTION scrobble_account_new_revision() RETURNS trigger AS $$
BEGIN
    NEW.revision := nextval('scrobble_account_revision');
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS scrobble_account_revision_on_token ON scrobble_accounts;
CREATE TRIGGER scrobble_account_revision_on_token
    BEFORE UPDATE OF token ON scrobble_accounts
    FOR EACH ROW EXECUTE FUNCTION scrobble_account_new_revision();

CREATE TABLE IF NOT EXISTS play_reports (
    user_id uuid NOT NULL,
    listen_id uuid NOT NULL,
    track_id text NOT NULL,
    started_at timestamptz NOT NULL,
    listened_ms integer NOT NULL CHECK (listened_ms >= 0),
    duration_ms integer NOT NULL,
    received_at timestamptz NOT NULL,
    PRIMARY KEY (user_id, listen_id)
);

CREATE TABLE IF NOT EXISTS play_deliveries (
    user_id uuid NOT NULL,
    listen_id uuid NOT NULL,
    service text NOT NULL,
    account_revision bigint NOT NULL,
    state text NOT NULL DEFAULT 'waiting'
        CHECK (state IN ('waiting', 'working', 'sent', 'retry', 'refused', 'dropped')),
    attempts integer NOT NULL DEFAULT 0,
    next_try_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL,
    PRIMARY KEY (user_id, listen_id, service),
    FOREIGN KEY (user_id, listen_id) REFERENCES play_reports (user_id, listen_id) ON DELETE CASCADE
);
