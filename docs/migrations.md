# Database Migrations

Runner — `server/app/migrate.py`, executed from `server/entrypoint.sh` (`python -m app.migrate`) before the server starts. Files — `server/migrations/NNN_name.sql`.

## How Migrations Are Applied

1. The runner acquires PostgreSQL advisory lock `LOCK_ID = 1297040210` on its connection. A second container starting simultaneously waits on it.
2. Creates the `schema_migrations (version, applied_at)` table if it does not exist.
3. Each unrecorded file is executed in **its own transaction** along with recording the version (`INSERT … ON CONFLICT DO NOTHING`, version is the filename without `.sql`). If SQL fails, both the file changes and the record are rolled back; the next start will re-attempt that exact file. The runner exits with a non-zero code, writing to stderr — `migration <version> failed, not marked applied`.
4. Exception — `REPEATABLE` in `migrate.py`: currently only `006_scrub_indexer_secrets` is listed there. It was written for the previous runner, which executed all files on every start, and it purges indexer keys from `playback_sessions` — this cleanup cannot be made one-off. Such a file runs on every start, also under the lock and inside a transaction. Do not add new files to this list: repeatable work belongs in code, not migrations.
5. Closing the connection releases the lock, including after an error.

The first start of the new runner on an older database re-runs 001–020 and records their versions: the previous runner already executed them on every start, so they are all repeatable.

## Rules for New Migrations

- **Expand only**: `CREATE … IF NOT EXISTS`, `ALTER TABLE … ADD COLUMN IF NOT EXISTS` with default or nullable. Previous application code must run against the new schema.
- **Disallowed**: down migrations, `DROP COLUMN`, `DROP TABLE`, renaming columns of user tables, modifying already executed files.
- **001–020 must not change by a single byte** — guarded by `test_executed_migrations_unchanged` (sha256). Editing an executed file on a production database will not apply: the version is already recorded. The one exception, FT-905: statements of the retired source path were removed from old files so a fresh install does not create them. Production keeps those objects, the hash in the test was renewed once, and `test_old_database_then_new_files` guards that a fresh schema is a subset of an old one.
- **Number** is taken after `git fetch origin` from fresh `main`: the next one after the last file there. Parallel branches do not reserve numbers; if `main` received the same number earlier — rename your file before merge.

## Rollback

Only the application is rolled back (previous image), never the database: neither down nor restore. The previous runner re-executes 001–020 on the new schema, leaving the extra `schema_migrations` table and new columns untouched. This is proven by `test_old_schema_up_then_previous_code`: snapshot of old schema with data → new runner → previous runner; rows, ordering, and keys remain identical, a new record gets a fresh key, repeated up applies nothing.

## How to Verify

```bash
bash scripts/check.sh                       # including server/tests/test_migrations.py
python3 scripts/acceptance/cases/FT-010.py verify   # exit 0; VERIFY_OK FT-010
```

`test_migrations.py` runs against a disposable database next to the test database (`CREATE DATABASE ft010_…`, `DROP` after the test). The FT-010 oracle spins up its own PostgreSQL in a temporary directory on a unix socket.

Not covered: migrations that cannot run inside a transaction (`CREATE INDEX CONCURRENTLY`) — such a file will fail; currently none exist.
