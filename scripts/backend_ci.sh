#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export LC_ALL="${LC_ALL:-C}"
export LANG="${LANG:-C}"

# On an agents host checks run from multiple worktrees at once, while Postgres on
# 55432 is shared: runs queue up. flock exists on Linux; on Mac it is absent,
# everything remains as it was.
if command -v flock >/dev/null 2>&1; then
  exec 9>"${TMPDIR:-/tmp}/flowtune-backend-ci.lock"
  flock 9
fi

# Shared Postgres on :55432 is the test-environment lease (flock above).
# FLOWTUNE_TEST_HOST/PORT/DB override that lease for one card. The same three
# values are used for pg_isready, createdb and DATABASE_URL. A remote URL is
# rejected here, before migrations, so a production database is never migrated.
is_loopback() {
  case "$1" in
    127.0.0.1|localhost|::1) return 0 ;;
    *) return 1 ;;
  esac
}

incoming_host=""
incoming_port=""
incoming_db=""
if [[ -n "${DATABASE_URL:-}" ]]; then
  # Do not print the URL: it may carry a password.
  parsed="$(DATABASE_URL="$DATABASE_URL" python3 -c 'import os; from urllib.parse import urlparse; u=urlparse(os.environ["DATABASE_URL"]); print(u.hostname or ""); print("" if u.port is None else u.port); print(u.path.lstrip("/").split("?", 1)[0])')"
  incoming_host="${parsed%%$'\n'*}"
  rest="${parsed#*$'\n'}"
  incoming_port="${rest%%$'\n'*}"
  incoming_db="${rest#*$'\n'}"
  if ! is_loopback "$incoming_host"; then
    echo "FAIL: remote database URL rejected before migrations" >&2
    exit 1
  fi
fi

TEST_HOST="${FLOWTUNE_TEST_HOST:-${incoming_host:-127.0.0.1}}"
if [[ -n "${FLOWTUNE_TEST_PORT:-}" ]]; then
  TEST_PORT="$FLOWTUNE_TEST_PORT"
elif [[ -n "$incoming_port" ]]; then
  TEST_PORT="$incoming_port"
elif [[ -n "${DATABASE_URL:-}" ]]; then
  TEST_PORT=5432
else
  TEST_PORT=55432
fi
TEST_DB="${FLOWTUNE_TEST_DB:-${incoming_db:-music}}"

if ! is_loopback "$TEST_HOST"; then
  echo "FAIL: remote database URL rejected before migrations" >&2
  exit 1
fi
if [[ ! "$TEST_PORT" =~ ^[0-9]+$ ]] || (( TEST_PORT < 1 || TEST_PORT > 65535 )); then
  echo "FAIL: test database port is not a port number" >&2
  exit 1
fi
if [[ ! "$TEST_DB" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]]; then
  echo "FAIL: test database name is not a plain identifier" >&2
  exit 1
fi
if [[ "$TEST_HOST" == "::1" ]]; then
  export DATABASE_URL="postgresql://music@[::1]:${TEST_PORT}/${TEST_DB}"
else
  export DATABASE_URL="postgresql://music@${TEST_HOST}:${TEST_PORT}/${TEST_DB}"
fi

# PostgreSQL 16: on Mac from Homebrew, on Linux — from postgresql-16 package.
if command -v brew >/dev/null 2>&1; then
  PG_BIN="$(brew --prefix postgresql@16)/bin"
else
  PG_BIN=/usr/lib/postgresql/16/bin
fi

if ! pg_isready -h "$TEST_HOST" -p "$TEST_PORT" -U music >/dev/null 2>&1; then
  if [[ "$TEST_PORT" == "55432" && ( "$TEST_HOST" == "127.0.0.1" || "$TEST_HOST" == "localhost" ) ]]; then
    DATA="$ROOT/.pgdata"
    RUN="$ROOT/.pg-run"
    mkdir -p "$RUN"
    if [[ ! -f "$DATA/PG_VERSION" ]]; then
      "$PG_BIN/initdb" -D "$DATA" --auth=trust --username=music --no-instructions --encoding=UTF8 --locale=C
    fi
    # 9>&-: Postgres outlives this run, and inherited lock descriptor
    # would hold flock forever — all subsequent runs would wait for it.
    "$PG_BIN/pg_ctl" -D "$DATA" -l "$DATA/pg.log" -o "-p $TEST_PORT -k $RUN" start 9>&-
    for _ in $(seq 1 30); do
      if pg_isready -h "$TEST_HOST" -p "$TEST_PORT" -U music >/dev/null 2>&1; then
        break
      fi
      sleep 0.3
    done
  else
    echo "FAIL: test postgres is not ready on ${TEST_HOST}:${TEST_PORT}" >&2
    exit 1
  fi
fi
# FLOWTUNE_FRESH_DB=1 (used on an agents host) — fresh database for every run:
# migration from another branch in shared DB previously broke tests (20.09.2026).
if [[ "${FLOWTUNE_FRESH_DB:-}" == 1 ]]; then
  "$PG_BIN/dropdb" -h "$TEST_HOST" -p "$TEST_PORT" -U music --if-exists --force "$TEST_DB"
fi
# Not --locale=C: in such database lower('Кукушка') remains "Кукушка", and search
# in Russian failed due to DB rather than code (30.09.2026); production DB is en_US.utf8.
"$PG_BIN/createdb" -h "$TEST_HOST" -p "$TEST_PORT" -U music -E UTF8 -T template0 --locale=C.UTF-8 "$TEST_DB" 2>/dev/null || true

cd "$ROOT/server"
if [[ ! -x .venv/bin/pytest ]]; then
  if command -v python3.12 >/dev/null 2>&1; then
    python3.12 -m venv .venv
  else
    python3 -m venv .venv
  fi
fi
.venv/bin/pip install -q -e ".[dev]"

# Migrations, pytest, and suite size check are shared with GitLab, so that
# local "green" means exactly the same as green in CI.
PYTHON="$ROOT/server/.venv/bin/python" bash "$ROOT/scripts/backend_tests.sh"
