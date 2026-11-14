-- Own copy of the required part of MusicBrainz (catalog v2, phase V1).
--
-- Tablespace `mb` is not included here. `CREATE TABLESPACE` cannot be executed
-- inside a transaction, and the directory `/var/lib/postgresql/mb` does not exist
-- in tests or in brew-Postgres: this migration is run by all `apply()` calls, and tablespace
-- failure would fail other tests. The directory is prepared by
-- the postgres entrypoint in compose, tablespace itself is created by the loader
-- `app/mbcopy.py` if the directory exists. The tables below are empty, on the main
-- volume. The first load replaces them with twin tables already in `mb`.
--
-- Everything is idempotent and survives repeated execution. `app/migrate.py`
-- joins files and splits them by semicolon, so neither DO-block
-- nor function fits here, and this character is absent from comments.

CREATE TABLE IF NOT EXISTS mb_artist (
    mbid uuid PRIMARY KEY,
    name text NOT NULL,
    sort_name text NOT NULL,
    type text,
    area_mbid uuid,
    begin_year smallint,
    ended boolean NOT NULL DEFAULT false
);

CREATE INDEX IF NOT EXISTS mb_artist_name_trgm
    ON mb_artist USING gin (name gin_trgm_ops);

CREATE INDEX IF NOT EXISTS mb_artist_area ON mb_artist (area_mbid);

CREATE TABLE IF NOT EXISTS mb_artist_alias (
    artist_mbid uuid NOT NULL,
    name text NOT NULL,
    locale text,
    primary_for_locale boolean NOT NULL DEFAULT false
);

CREATE INDEX IF NOT EXISTS mb_artist_alias_artist ON mb_artist_alias (artist_mbid);

CREATE INDEX IF NOT EXISTS mb_artist_alias_name_trgm
    ON mb_artist_alias USING gin (name gin_trgm_ops);

CREATE TABLE IF NOT EXISTS mb_area (
    mbid uuid PRIMARY KEY,
    name text NOT NULL,
    type text,
    iso3166 text
);

CREATE INDEX IF NOT EXISTS mb_area_iso ON mb_area (iso3166);

CREATE TABLE IF NOT EXISTS mb_area_part (
    child_mbid uuid NOT NULL,
    parent_mbid uuid NOT NULL,
    PRIMARY KEY (child_mbid, parent_mbid)
);

CREATE TABLE IF NOT EXISTS mb_artist_credit (
    mbid uuid PRIMARY KEY,
    name text NOT NULL
);

CREATE TABLE IF NOT EXISTS mb_artist_credit_name (
    credit_mbid uuid NOT NULL,
    position smallint NOT NULL,
    artist_mbid uuid NOT NULL,
    name text NOT NULL,
    PRIMARY KEY (credit_mbid, position)
);

CREATE INDEX IF NOT EXISTS mb_artist_credit_name_artist
    ON mb_artist_credit_name (artist_mbid);

CREATE TABLE IF NOT EXISTS mb_release_group (
    mbid uuid PRIMARY KEY,
    artist_mbid uuid,
    title text NOT NULL,
    primary_type text,
    secondary_types text[] NOT NULL DEFAULT '{}',
    first_date text
);

CREATE INDEX IF NOT EXISTS mb_release_group_artist
    ON mb_release_group (artist_mbid, first_date);

CREATE INDEX IF NOT EXISTS mb_release_group_title_trgm
    ON mb_release_group USING gin (title gin_trgm_ops);

CREATE TABLE IF NOT EXISTS mb_release (
    mbid uuid PRIMARY KEY,
    group_mbid uuid NOT NULL,
    title text NOT NULL,
    status text,
    country text,
    date text
);

CREATE INDEX IF NOT EXISTS mb_release_group_mbid ON mb_release (group_mbid);

CREATE TABLE IF NOT EXISTS mb_medium (
    id bigint PRIMARY KEY,
    release_mbid uuid NOT NULL,
    position integer NOT NULL,
    format text
);

CREATE INDEX IF NOT EXISTS mb_medium_release ON mb_medium (release_mbid);

CREATE TABLE IF NOT EXISTS mb_track (
    mbid uuid PRIMARY KEY,
    medium_id bigint NOT NULL,
    recording_mbid uuid NOT NULL,
    position integer NOT NULL,
    title text NOT NULL,
    length_ms integer
);

CREATE INDEX IF NOT EXISTS mb_track_recording ON mb_track (recording_mbid);

CREATE INDEX IF NOT EXISTS mb_track_medium ON mb_track (medium_id);

CREATE TABLE IF NOT EXISTS mb_recording (
    mbid uuid PRIMARY KEY,
    artist_mbid uuid,
    title text NOT NULL,
    length_ms integer
);

CREATE INDEX IF NOT EXISTS mb_recording_artist ON mb_recording (artist_mbid);

CREATE TABLE IF NOT EXISTS mb_isrc (
    recording_mbid uuid NOT NULL,
    isrc text NOT NULL,
    PRIMARY KEY (recording_mbid, isrc)
);

CREATE TABLE IF NOT EXISTS mb_work (
    mbid uuid PRIMARY KEY,
    title text NOT NULL
);

CREATE TABLE IF NOT EXISTS mb_recording_work (
    recording_mbid uuid NOT NULL,
    work_mbid uuid NOT NULL,
    PRIMARY KEY (recording_mbid, work_mbid)
);

CREATE TABLE IF NOT EXISTS mb_genre (
    mbid uuid PRIMARY KEY,
    name text NOT NULL
);

CREATE TABLE IF NOT EXISTS mb_genre_edge (
    child_mbid uuid NOT NULL,
    parent_mbid uuid NOT NULL,
    kind text NOT NULL,
    PRIMARY KEY (child_mbid, parent_mbid, kind)
);

CREATE TABLE IF NOT EXISTS mb_artist_artist (
    member_mbid uuid NOT NULL,
    group_mbid uuid NOT NULL,
    PRIMARY KEY (member_mbid, group_mbid)
);

CREATE TABLE IF NOT EXISTS mb_tag (
    id bigint PRIMARY KEY,
    name text NOT NULL
);

CREATE TABLE IF NOT EXISTS mb_artist_tag (
    artist_mbid uuid NOT NULL,
    tag_id bigint NOT NULL,
    count integer NOT NULL,
    PRIMARY KEY (artist_mbid, tag_id)
);

CREATE TABLE IF NOT EXISTS mb_release_group_tag (
    group_mbid uuid NOT NULL,
    tag_id bigint NOT NULL,
    count integer NOT NULL,
    PRIMARY KEY (group_mbid, tag_id)
);

CREATE TABLE IF NOT EXISTS mb_recording_tag (
    recording_mbid uuid NOT NULL,
    tag_id bigint NOT NULL,
    count integer NOT NULL,
    PRIMARY KEY (recording_mbid, tag_id)
);

CREATE TABLE IF NOT EXISTS mb_loads (
    id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    dump_date date NOT NULL,
    replication_sequence bigint,
    row_counts jsonb NOT NULL,
    duration_ms bigint NOT NULL,
    tablespace text,
    size_bytes bigint,
    loaded_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE mb_loads ADD COLUMN IF NOT EXISTS tablespace text;

ALTER TABLE mb_loads ADD COLUMN IF NOT EXISTS size_bytes bigint;
