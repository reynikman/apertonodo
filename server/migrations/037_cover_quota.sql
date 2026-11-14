-- FT-544 (R-A65): covers — cache with storage quota. Quota is calculated by sum of
-- size_bytes, least recently opened evicted by COALESCE(opened_at, tried_at).
-- Old rows remain NULL, without backfill on startup: unnecessary to stat thousands of
-- files on disk, they will be counted toward quota upon resave.
ALTER TABLE public.album_images ADD COLUMN IF NOT EXISTS opened_at timestamptz;
ALTER TABLE public.album_images ADD COLUMN IF NOT EXISTS size_bytes bigint;
