-- Only digests of normalized usernames are retained; old attempts are pruned on admission.
CREATE TABLE login_global_attempts (
    attempted_at timestamptz NOT NULL
);
CREATE INDEX login_global_attempts_at_idx ON login_global_attempts (attempted_at);

CREATE TABLE login_user_failures (
    username_digest text NOT NULL CHECK (username_digest ~ '^[0-9a-f]{64}$'),
    attempted_at timestamptz NOT NULL
);
CREATE INDEX login_user_failures_key_at_idx
    ON login_user_failures (username_digest, attempted_at);
