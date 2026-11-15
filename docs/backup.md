# Backup of Personal Data

The archive preserves user accounts and password hashes, library, history, playlists, token hashes, song aliases, preferences, and pins. PostgreSQL creates a consistent snapshot; the archive can be inspected with the `pg_restore -l` command. The file is created with owner-only permissions (`600`). Tables that do not exist yet are skipped; the script does not conceal read errors on existing tables.

Music files and the large MusicBrainz replica are not in the archive. The MusicBrainz catalog is rebuilt separately after restoration. Song aliases are included in the archive and are needed so that existing links to songs remain intact.

To create a backup, specify the source database URL and an existing private directory:

    sh scripts/backup.sh --database-url "$DATABASE_URL" --directory "$BACKUP_DIR"

The script will print the path to the new archive and row counts. Store the archive only in a private directory with restricted permissions. Do not put it into the repository, working tree, or CI artifacts. Old archives are not removed automatically.

Verify restoration only into a separate empty database, never into the production database:

    sh scripts/restore_check.sh --archive "$BACKUP_FILE" --database-url "$EMPTY_DATABASE_URL"

The check restores tables into the specified database. It will refuse to run against the `music` database or any database that already contains user tables.

Music files and the MusicBrainz catalog are not protected by this archive.

## Scheduled dumps

Back up on a schedule, not by hand. The only data that cannot be reconstructed is what people created: accounts, playlists, saved songs and song links. The MusicBrainz catalog is rebuilt from its own source, so it does not need to be in the archive.

Run `scripts/backup.sh` (the same script described above) on a timer, for example from cron or a systemd timer. If the database runs in a container, run the script inside the database container, with `--database-url` pointing at that database, and copy the archive out afterwards. Keep the archives in a private directory with restricted permissions and prune old ones yourself; the script never removes them.

The dump includes only the `public` schema. Foreign schemas created while the catalog is rebuilt can be very large and are not needed to restore your data. The tables `song_identity` and `song_alias` are included: they keep earlier song links valid across catalog rebuilds, and they can be large.

Verify restoration with `scripts/restore_check.sh` against a separate empty database, never into the production database.
