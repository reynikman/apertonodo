-- Images: album covers and artist photos (Phase K).
--
-- Everything here is idempotent and survives repeated execution, like 013_search.sql.
-- `app/migrate.py` joins all files and splits them by semicolon, so
-- neither DO-block nor function fits here -- only separate statements. For
-- the same reason there must be no semicolon inside a comment.

-- Images themselves are no longer stored in the database. Owner decision 20.09.2026: one
-- hundred thousand covers in `bytea` is five gigabytes that would go into every copy
-- of the database. Now the database stores only the file path on disk (`IMAGE_DIR`, on prod --
-- HDD /mnt/flowtune/images) and an "attempted" flag: `path IS NULL` with
-- `tried_at` set means "searched and not found".
--
-- Old `album_covers` is replaced entirely rather than altered: in production it
-- held four rows, two of them with an image, and downloading them anew is cheaper
-- than writing a one-off migrator. Renaming is not suitable here -- it would not survive
-- repeated execution, and a second `ALTER TABLE ... DROP COLUMN` would no longer
-- distinguish "searched and not found" from "image was present and disappeared".
DROP TABLE IF EXISTS album_covers;

CREATE TABLE IF NOT EXISTS album_images (
    album_id uuid PRIMARY KEY,
    path text,
    tried_at timestamptz NOT NULL DEFAULT now()
);

-- Artist photo from Wikimedia Commons. `author` and `license` are stored next to
-- the image, and without them it is not shown at all: the attribution "photo: author,
-- license" is a Wikimedia Commons license requirement, not a screen decoration.
--
-- Key is `artist_key` (norm(name)), the same as in `catalog_artists` and
-- `lastfm_artists`: artist has no own MBID in the catalog, it is fetched from
-- MusicBrainz by name. Next to it is `mbid` -- photo is served externally by it.
-- It is what goes into the URL path, not the name: access log records the request path
-- in full, and artist name in it would end up in the log.
CREATE TABLE IF NOT EXISTS artist_photos (
    artist_key text PRIMARY KEY,
    mbid uuid,
    path text,
    author text,
    license text,
    tried_at timestamptz NOT NULL DEFAULT now()
);

-- Index is deliberately non-unique: `exact_artist` also matches aliases, so
-- "beatles" and "the beatles" are two catalog rows with the same MBID.
CREATE INDEX IF NOT EXISTS artist_photos_mbid ON artist_photos (mbid);
