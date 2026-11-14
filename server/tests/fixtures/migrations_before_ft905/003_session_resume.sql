-- Everything needed to resume a session after container restart.
-- Without these fields the token survived database write, but there was nothing
-- to play from it: a restart aborted every active session.
ALTER TABLE playback_sessions ADD COLUMN IF NOT EXISTS rqbit_id text;
ALTER TABLE playback_sessions ADD COLUMN IF NOT EXISTS file_index integer;
ALTER TABLE playback_sessions ADD COLUMN IF NOT EXISTS media_path text;
ALTER TABLE playback_sessions ADD COLUMN IF NOT EXISTS track jsonb;
