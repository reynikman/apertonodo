-- Keep only the report, not the uploaded file. Saves are keyed by list + target.
CREATE TABLE IF NOT EXISTS imports (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    report jsonb NOT NULL,
    saved jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS imports_created_at_idx ON imports (created_at);
