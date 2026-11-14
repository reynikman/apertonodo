-- FT-673 (R-A99, contract D5): audiobook playback position on server.
--
-- One record per book per user. Removing book from shelf does not erase position:
-- record goes away only with user or book itself. `seq` increments on
-- each accepted record — phone uses it to ask "what changed".

CREATE SEQUENCE IF NOT EXISTS book_position_seq;

CREATE TABLE IF NOT EXISTS book_position (
    user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    book_id uuid NOT NULL REFERENCES books (id) ON DELETE CASCADE,
    part integer NOT NULL CHECK (part >= 1),
    position_ms bigint NOT NULL CHECK (position_ms >= 0),
    finished boolean NOT NULL,
    updated_at timestamptz NOT NULL,
    seq bigint NOT NULL,
    PRIMARY KEY (user_id, book_id)
);

CREATE INDEX IF NOT EXISTS book_position_changes ON book_position (user_id, seq);
CREATE INDEX IF NOT EXISTS book_position_book_idx ON book_position (book_id);
