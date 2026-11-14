-- FT-856: one-time invite codes. The admin adds a person by name; the person makes up the password
-- in the app with this code. Only the digest is kept; one live code per person.
CREATE TABLE IF NOT EXISTS user_invites (
    user_id uuid PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
    code_hash text NOT NULL,
    expires_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
