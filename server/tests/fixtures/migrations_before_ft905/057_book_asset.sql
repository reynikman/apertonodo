-- FT-720 (R-A88): core does not know where book comes from. Release number and source address
-- become opaque key `asset_key` and hint `asset_hint` parsed by
-- extension. Book addresses were not connected on production — no rows.
-- `RENAME COLUMN` does not support `IF EXISTS`, and migration must survive
-- rerun (see 014_images.sql) — therefore each rename is guarded by check.

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_name = 'books' AND column_name = 'info_hash') THEN
        ALTER TABLE books RENAME COLUMN info_hash TO asset_key;
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_name = 'books' AND column_name = 'source_locator') THEN
        ALTER TABLE books RENAME COLUMN source_locator TO asset_hint;
    END IF;
END $$;

ALTER INDEX IF EXISTS books_info_hash_key RENAME TO books_asset_key_key;
