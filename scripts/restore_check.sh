#!/bin/sh
set -eu

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

usage() { fail 'Usage: sh scripts/restore_check.sh --archive PATH --database-url URL'; }
archive=
database_url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --archive) [ "$#" -ge 2 ] || usage; archive=$2; shift 2 ;;
    --database-url) [ "$#" -ge 2 ] || usage; database_url=$2; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$archive" ] && [ -n "$database_url" ] || usage
[ -f "$archive" ] || fail 'Archive file not found'
case "$archive" in /*) absolute_archive=$archive ;; *) absolute_archive=$(pwd)/$archive ;; esac

PG_RESTORE=$(resolve_tool pg_restore) || fail 'pg_restore not found'
PSQL=$(resolve_tool psql) || fail 'psql not found'
if ! restore_db=$(psql_value 'SELECT current_database()'); then fail 'Failed to connect to target database'; fi
if ! table_count=$(psql_value "SELECT count(*) FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('r','p','m','f') AND n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_toast%'"); then
  fail 'Failed to check target database'
fi
case "$table_count" in ''|*[!0-9]*) fail 'Failed to determine table count in target database' ;; esac
if [ "$restore_db" = music ] || [ "$table_count" -gt 0 ]; then
  fail 'Restoration is allowed only to a separate empty database; music is forbidden'
fi
if ! "$PG_RESTORE" --list "$archive" >/dev/null; then fail 'File is not a readable pg_dump archive'; fi
archive_json=$(json_escape "$absolute_archive")
if ! restore_db_json=$(psql_value 'SELECT to_json(current_database())'); then fail 'Failed to read target database name'; fi
if ! "$PG_RESTORE" --single-transaction --exit-on-error --no-owner --no-privileges --dbname="$database_url" "$archive" >/dev/null; then
  fail 'pg_restore failed with error'
fi
counts=$(read_counts)
printf '{"status":"completed","archive":"%s","restore_db":%s,"counts":{%s}}\n' "$archive_json" "$restore_db_json" "$counts"
