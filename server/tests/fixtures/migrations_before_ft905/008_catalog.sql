-- Catalog for browsing genres and artists (Phase F).
-- Built from its own release list: `python -m app.catalog build`, and
-- rebuilds itself when the crawler updates seeders. Only artists with
-- an active release get in here -- everything visible in a genre plays.
-- No release-specific words here: seeder count is stored as popularity.
CREATE TABLE IF NOT EXISTS catalog_artists (
    genre text NOT NULL,
    artist_key text NOT NULL,
    name text NOT NULL,
    letter text NOT NULL,
    popularity integer NOT NULL,
    PRIMARY KEY (genre, artist_key)
);

CREATE INDEX IF NOT EXISTS catalog_artists_popular
    ON catalog_artists (genre, popularity DESC);

CREATE INDEX IF NOT EXISTS catalog_artists_letter
    ON catalog_artists (letter, artist_key);

CREATE TABLE IF NOT EXISTS catalog_built (
    id integer PRIMARY KEY,
    built_at timestamptz NOT NULL
);

-- Album cover -- cover.jpg or folder.jpg file from the release itself.
-- image is empty -- searched and not found: retry no earlier than in a week.
CREATE TABLE IF NOT EXISTS album_covers (
    album_id uuid PRIMARY KEY,
    image bytea,
    content_type text,
    tried_at timestamptz NOT NULL DEFAULT now()
);
