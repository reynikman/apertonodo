CREATE TABLE IF NOT EXISTS users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    username text UNIQUE NOT NULL,
    password_hash text,
    is_admin boolean NOT NULL DEFAULT false,
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE favorites ADD COLUMN IF NOT EXISTS user_id uuid;
ALTER TABLE playlists ADD COLUMN IF NOT EXISTS user_id uuid;
ALTER TABLE listens ADD COLUMN IF NOT EXISTS user_id uuid;

DO $$
DECLARE
    v_owner_id uuid;
    has_library boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM favorites
        UNION ALL
        SELECT 1 FROM playlists
        UNION ALL
        SELECT 1 FROM listens
    ) INTO has_library;

    IF has_library AND NOT EXISTS (SELECT 1 FROM users WHERE username = 'owner') THEN
        INSERT INTO users (username, password_hash, is_admin, is_active)
        VALUES ('owner', NULL, true, true)
        RETURNING id INTO v_owner_id;
    ELSIF EXISTS (SELECT 1 FROM users WHERE username = 'owner') THEN
        SELECT id INTO v_owner_id FROM users WHERE username = 'owner';
    END IF;

    IF v_owner_id IS NOT NULL THEN
        UPDATE favorites SET user_id = v_owner_id WHERE user_id IS NULL;
        UPDATE playlists SET user_id = v_owner_id WHERE user_id IS NULL;
        UPDATE listens SET user_id = v_owner_id WHERE user_id IS NULL;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM information_schema.table_constraints tc
        JOIN information_schema.key_column_usage kcu
          ON tc.constraint_name = kcu.constraint_name
         AND tc.table_schema = kcu.table_schema
        WHERE tc.table_name = 'favorites'
          AND tc.constraint_type = 'PRIMARY KEY'
        GROUP BY tc.constraint_name
        HAVING count(*) = 1 AND max(kcu.column_name) = 'canonical_key'
    ) THEN
        ALTER TABLE favorites DROP CONSTRAINT favorites_pkey;
        ALTER TABLE favorites ALTER COLUMN user_id SET NOT NULL;
        ALTER TABLE favorites ADD PRIMARY KEY (user_id, canonical_key);
    END IF;
END $$;

CREATE OR REPLACE FUNCTION library_set_default_owner() RETURNS TRIGGER AS $$
DECLARE
    v_id uuid;
BEGIN
    IF NEW.user_id IS NULL THEN
        SELECT id INTO v_id FROM users WHERE username = 'owner';
        IF v_id IS NULL THEN
            INSERT INTO users (username, password_hash, is_admin, is_active)
            VALUES ('owner', NULL, true, true)
            ON CONFLICT (username) DO NOTHING;
            SELECT id INTO v_id FROM users WHERE username = 'owner';
        END IF;
        NEW.user_id := v_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_listens_default_owner ON listens;
CREATE TRIGGER trg_listens_default_owner
BEFORE INSERT ON listens
FOR EACH ROW EXECUTE FUNCTION library_set_default_owner();

DROP TRIGGER IF EXISTS trg_playlists_default_owner ON playlists;
CREATE TRIGGER trg_playlists_default_owner
BEFORE INSERT ON playlists
FOR EACH ROW EXECUTE FUNCTION library_set_default_owner();

DROP TRIGGER IF EXISTS trg_favorites_default_owner ON favorites;
CREATE TRIGGER trg_favorites_default_owner
BEFORE INSERT ON favorites
FOR EACH ROW EXECUTE FUNCTION library_set_default_owner();
