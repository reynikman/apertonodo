-- FT-667 (R-A99, contract D5): audiobooks, their parts and personal shelves.
-- Book is an asset as found by the extension. The opaque key `asset_key` and the hint
-- `asset_hint` live only here, the client knows a book by `id`.

CREATE TABLE IF NOT EXISTS books (
    id uuid PRIMARY KEY,
    asset_key text NOT NULL UNIQUE,
    asset_hint text NOT NULL,
    title text NOT NULL,
    author text NOT NULL DEFAULT '',
    narrator text NOT NULL DEFAULT '',
    year integer,
    total_bytes bigint NOT NULL,
    part_count integer NOT NULL,
    added_at timestamptz NOT NULL
);

CREATE TABLE IF NOT EXISTS book_parts (
    book_id uuid NOT NULL REFERENCES books (id) ON DELETE CASCADE,
    number integer NOT NULL,
    file_index integer NOT NULL,
    size bigint NOT NULL,
    kind text NOT NULL,
    PRIMARY KEY (book_id, number)
);

CREATE TABLE IF NOT EXISTS book_shelf (
    user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    book_id uuid NOT NULL REFERENCES books (id) ON DELETE CASCADE,
    added_at timestamptz NOT NULL,
    PRIMARY KEY (user_id, book_id)
);

CREATE INDEX IF NOT EXISTS book_shelf_book_idx ON book_shelf (book_id);
