#!/bin/sh
set -eu
umask 077

fail() { printf '%s\n' "$*" >&2; exit 1; }

resolve_tool() {
  name=$1
  for bin_dir in "${FT011_PG_BIN:-}" "${APERTONODO_PG_BIN:-}" "${FLOWTUNE_PG_BIN:-}" /opt/homebrew/opt/postgresql@16/bin /usr/local/opt/postgresql@16/bin; do
    if [ -n "$bin_dir" ] && [ -x "$bin_dir/$name" ]; then
      printf '%s\n' "$bin_dir/$name"
      return 0
    fi
  done
  for bin_dir in /usr/lib/postgresql/*/bin; do
    if [ -x "$bin_dir/$name" ]; then
      printf '%s\n' "$bin_dir/$name"
      return 0
    fi
  done
  return 1
}

# Personal data: everything a restore must bring back. Tables not introduced yet are skipped.
PERSONAL='users user_tokens user_invites tracks favorites playlists playlist_items listens playback_sessions song_identity edition_preference song_alias source_usage user_pins imports play_failures downloads news_follows news_channels news_curated_pref problem_reports ratings history_pause scrobble_accounts play_reports play_deliveries lastfm_pending podcast_subscriptions podcast_progress books book_parts book_shelf book_position'

psql_value() { "$PSQL" -X -qAt -v ON_ERROR_STOP=1 -d "$database_url" -c "$1"; }

read_counts() {
  result=
  for table in $PERSONAL; do
    if ! exists=$(psql_value "SELECT to_regclass('public.$table') IS NOT NULL"); then
      fail "Failed to verify table $table"
    fi
    case "$exists" in
      t)
        if ! rows=$(psql_value "SELECT count(*) FROM public.$table"); then
          fail "Failed to read table $table"
        fi
        case "$rows" in ''|*[!0-9]*) fail "Invalid row count in $table" ;; esac
        if [ -n "$result" ]; then result="$result,"; fi
        result="$result\"$table\":$rows"
        ;;
      f) ;;
      *) fail "Failed to determine presence of table $table" ;;
    esac
  done
  printf '%s\n' "$result"
}

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

usage() { fail 'Usage: sh scripts/backup.sh --database-url URL --directory DIR'; }
database_url=
directory=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --database-url) [ "$#" -ge 2 ] || usage; database_url=$2; shift 2 ;;
    --directory) [ "$#" -ge 2 ] || usage; directory=$2; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$database_url" ] && [ -n "$directory" ] || usage
[ -d "$directory" ] && [ -w "$directory" ] || fail 'Archive directory must exist and be writable'
while [ "$directory" != / ] && [ "${directory%/}" != "$directory" ]; do directory=${directory%/}; done
case "$directory" in /*) absolute_directory=$directory ;; *) absolute_directory=$(pwd)/$directory ;; esac

PG_DUMP=$(resolve_tool pg_dump) || fail 'pg_dump not found'
PSQL=$(resolve_tool psql) || fail 'psql not found'
if ! source_db_json=$(psql_value 'SELECT to_json(current_database())'); then fail 'Failed to read database name'; fi
counts=$(read_counts)
temporary=
cleanup() { if [ -n "$temporary" ]; then rm -f "$temporary"; fi; }
trap cleanup 0
trap 'exit 1' HUP INT TERM

while :; do
  temporary=$(mktemp "$directory/.flowtune-backup.XXXXXX") || fail 'Failed to create temporary file in archive directory'
  suffix=${temporary##*.flowtune-backup.}
  archive="$absolute_directory/flowtune-backup-$suffix.dump"
  if [ ! -e "$archive" ] && [ ! -L "$archive" ]; then break; fi
  rm -f "$temporary"
  temporary=
done

# The whole database minus every other table and view: the personal tables come with
# their trigger functions (--table alone would leave the triggers pointing at nothing, and
# the restore would fail), and the bulk MusicBrainz copy and all other rows stay out.
# Foreign schemas go out the same way as foreign tables: during the weekly catalog
# replacement catalog_gen_* holds tens of gigabytes. Not --schema=public: that dump also
# carries "CREATE SCHEMA public", and pg_restore --exit-on-error dies on any fresh
# database where the schema already exists (restore_check.sh, a manual restore), so the
# archive would not restore with plain tools.
quoted=$(printf "'%s'," $PERSONAL)
if ! others=$(psql_value "SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm', 'f') AND c.relname NOT IN (${quoted%,}) ORDER BY 1"); then
  fail 'Failed to list database tables'
fi
if ! foreign=$(psql_value "SELECT nspname FROM pg_namespace WHERE nspname NOT IN ('public', 'information_schema') AND nspname NOT LIKE 'pg\\_%' ORDER BY 1"); then
  fail 'Failed to list database schemas'
fi
set --
for table in $others; do set -- "$@" "--exclude-table=public.$table"; done
for schema in $foreign; do set -- "$@" "--exclude-schema=$schema"; done

if ! "$PG_DUMP" \
  --format=custom \
  --no-owner \
  --no-privileges \
  --no-blobs \
  --file="$temporary" \
  "$@" \
  "$database_url"; then
  fail 'pg_dump failed with error'
fi
chmod 600 "$temporary"
archive_json=$(json_escape "$archive")
mv -n "$temporary" "$archive"
[ ! -e "$temporary" ] || fail 'Failed to publish archive without overwriting existing file'
temporary=
printf '{"status":"completed","archive":"%s","source_db":%s,"counts":{%s}}\n' "$archive_json" "$source_db_json" "$counts"
