CREATE TABLE IF NOT EXISTS user_pins (
    user_id uuid NOT NULL,
    asset_id text NOT NULL,
    PRIMARY KEY (user_id, asset_id)
);

ALTER TABLE playback_sessions ADD COLUMN IF NOT EXISTS user_id uuid;

DO $$
DECLARE
    v_owner_id uuid;
    v_user_type text;
    has_legacy boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM playback_sessions WHERE user_id IS NULL
        UNION ALL
        SELECT 1 FROM source_usage WHERE pinned IS TRUE
    ) INTO has_legacy;

    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'edition_preference') THEN
        IF NOT has_legacy THEN
            SELECT EXISTS (SELECT 1 FROM edition_preference WHERE user_id = 'owner') INTO has_legacy;
        END IF;
    END IF;

    IF has_legacy AND NOT EXISTS (SELECT 1 FROM users WHERE username = 'owner') THEN
        INSERT INTO users (username, password_hash, is_admin, is_active)
        VALUES ('owner', NULL, true, true)
        RETURNING id INTO v_owner_id;
    ELSIF EXISTS (SELECT 1 FROM users WHERE username = 'owner') THEN
        SELECT id INTO v_owner_id FROM users WHERE username = 'owner';
    END IF;

    IF v_owner_id IS NOT NULL THEN
        INSERT INTO user_pins (user_id, asset_id)
        SELECT v_owner_id, info_hash
        FROM source_usage
        WHERE pinned IS TRUE
        ON CONFLICT DO NOTHING;

        UPDATE playback_sessions SET user_id = v_owner_id WHERE user_id IS NULL;
    END IF;

    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'edition_preference') THEN
        SELECT data_type INTO v_user_type
        FROM information_schema.columns
        WHERE table_name = 'edition_preference' AND column_name = 'user_id';

        IF v_user_type = 'text' THEN
            ALTER TABLE edition_preference ALTER COLUMN user_id DROP DEFAULT;
            IF v_owner_id IS NOT NULL THEN
                UPDATE edition_preference SET user_id = v_owner_id::text WHERE user_id = 'owner';
            END IF;
            ALTER TABLE edition_preference ALTER COLUMN user_id TYPE uuid USING user_id::uuid;
        END IF;
    END IF;
END $$;

ALTER TABLE playback_sessions ALTER COLUMN user_id SET NOT NULL;

CREATE OR REPLACE FUNCTION playback_sessions_set_default_owner() RETURNS TRIGGER AS $$
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

DROP TRIGGER IF EXISTS trg_playback_sessions_default_owner ON playback_sessions;
CREATE TRIGGER trg_playback_sessions_default_owner
BEFORE INSERT ON playback_sessions
FOR EACH ROW EXECUTE FUNCTION playback_sessions_set_default_owner();

CREATE OR REPLACE FUNCTION source_usage_sync_pins() RETURNS TRIGGER AS $$
DECLARE
    v_owner_id uuid;
BEGIN
    IF NEW.pinned IS TRUE THEN
        SELECT id INTO v_owner_id FROM users WHERE username = 'owner';
        IF v_owner_id IS NULL THEN
            INSERT INTO users (username, password_hash, is_admin, is_active)
            VALUES ('owner', NULL, true, true)
            ON CONFLICT (username) DO NOTHING;
            SELECT id INTO v_owner_id FROM users WHERE username = 'owner';
        END IF;
        IF v_owner_id IS NOT NULL THEN
            INSERT INTO user_pins (user_id, asset_id)
            VALUES (v_owner_id, NEW.info_hash)
            ON CONFLICT DO NOTHING;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_source_usage_sync_pins ON source_usage;
CREATE TRIGGER trg_source_usage_sync_pins
AFTER INSERT OR UPDATE OF pinned ON source_usage
FOR EACH ROW EXECUTE FUNCTION source_usage_sync_pins();
