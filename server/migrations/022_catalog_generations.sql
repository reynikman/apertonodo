CREATE TABLE IF NOT EXISTS catalog_generation (generation_id uuid PRIMARY KEY, schema_name text NOT NULL UNIQUE, is_current boolean NOT NULL DEFAULT false);
CREATE UNIQUE INDEX IF NOT EXISTS catalog_generation_one_current ON catalog_generation (is_current) WHERE is_current;
CREATE TABLE IF NOT EXISTS song_identity (song_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), identity_key text NOT NULL UNIQUE, v3_song_id bigint);
CREATE UNIQUE INDEX IF NOT EXISTS song_identity_current_v3 ON song_identity (v3_song_id) WHERE v3_song_id IS NOT NULL;
CREATE TABLE IF NOT EXISTS song_alias (old_track_id uuid, old_canonical_key text, song_id uuid NOT NULL REFERENCES song_identity (song_id), CHECK (old_track_id IS NOT NULL OR old_canonical_key IS NOT NULL));
CREATE UNIQUE INDEX IF NOT EXISTS song_alias_track ON song_alias (old_track_id) WHERE old_track_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS song_alias_canonical ON song_alias (old_canonical_key) WHERE old_canonical_key IS NOT NULL;
CREATE OR REPLACE FUNCTION public.catalog_song_rows()
RETURNS TABLE(song_id uuid, artist_id uuid, title text, work_id uuid, original_version_id uuid, original_year smallint) LANGUAGE SQL STABLE AS $$
SELECT i.song_id, s.artist_mbid, s.title, s.work_mbid, s.original_recording_mbid, s.original_year
FROM public.song_identity i JOIN public.song s ON s.id = i.v3_song_id WHERE i.v3_song_id IS NOT NULL
$$;
CREATE OR REPLACE VIEW public.catalog_song AS SELECT * FROM public.catalog_song_rows();
CREATE OR REPLACE FUNCTION public.catalog_song_version_rows()
RETURNS TABLE(song_id uuid, version_id uuid, kind text, year smallint, edition_id uuid, album_id uuid) LANGUAGE SQL STABLE AS $$
SELECT i.song_id, v.recording_mbid, v.kind, v.year, r.mbid, r.group_mbid
FROM public.song_identity i JOIN public.song_version v ON v.song_id = i.v3_song_id
LEFT JOIN public.mb_track t ON t.recording_mbid = v.recording_mbid
LEFT JOIN public.mb_medium m ON m.id = t.medium_id LEFT JOIN public.mb_release r ON r.mbid = m.release_mbid
WHERE i.v3_song_id IS NOT NULL
$$;
CREATE OR REPLACE VIEW public.catalog_song_version AS SELECT * FROM public.catalog_song_version_rows();
