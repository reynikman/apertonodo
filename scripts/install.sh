#!/usr/bin/env bash
# Apertonodo installer (FT-901): makes .env with random secrets, starts the server,
# waits for it and creates the first administrator.
#
# Usage: ./scripts/install.sh [--dry-run]
# Needs scripts/extension.sh next to it (it adds folder, archive and lyrics).
#   --dry-run  do everything except `docker compose up` and the waiting (used by the test).
# An existing .env is never changed: a second run reuses it, so an install cut short
# (server slow to start, Ctrl-C) finishes by running the script again.
set -euo pipefail

DRY=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY=1 ;;
  *) echo "usage: install.sh [--dry-run]" >&2; exit 2 ;;
esac

cd "$(dirname "$0")/.."

# With --dry-run a failed check is a warning: the test runs on any machine.
need() {
  echo "install: $1" >&2
  [ "$DRY" = 1 ] || exit 1
}

[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || need "Linux x86_64 is required (found $(uname -s) $(uname -m))"
docker compose version >/dev/null 2>&1 || need "Docker Compose is missing: install Docker with the compose plugin (docker compose version)"
command -v curl >/dev/null 2>&1 || need "curl is missing"

secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  else
    head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

if [ -e .env ]; then
  echo ".env already exists: left as it is, its secrets are used. To reinstall, move it away first."
else
  umask 077
  tmp="$(mktemp .env.XXXXXX)"
  trap 'rm -f "$tmp"' EXIT
  sed -e "s|^MUSIC_API_KEY=.*|MUSIC_API_KEY=$(secret)|" \
      -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$(secret)|" \
      -e "s|^APERTONO_ADMIN_PASSWORD=.*|APERTONO_ADMIN_PASSWORD=$(secret)|" \
      -e "s|^MUSICBRAINZ_ENABLED=.*|MUSICBRAINZ_ENABLED=1|" \
      .env.example > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" .env
  trap - EXIT
  echo "Created .env with random secrets (readable only by you)."
fi

value() { sed -n "s/^$1=//p" .env | tail -1; }
API_KEY="$(value MUSIC_API_KEY)"
ADMIN_PASSWORD="$(value APERTONO_ADMIN_PASSWORD)"

mkdir -p music
PORT="$(value APERTONO_PORT)"
PORT="${PORT:-8088}"
ADMIN_USER="$(value APERTONO_ADMIN_USER)"
ADMIN_USER="${ADMIN_USER:-admin}"
URL="http://localhost:$PORT"

# The default extensions: your folder, Internet Archive, lyrics. Same command as for any other extension;
# --no-up because the one `up` below starts everything. Where extensions/ is missing it is fetched
# (APERTONO_EXTENSIONS_REPO / _REF, or APERTONO_EXTENSIONS_SRC=<dir> without network).
EXT_FLAGS="--no-up"
[ "$DRY" = 1 ] && EXT_FLAGS="--dry-run"
for ext in folder archive lyrics; do
  bash scripts/extension.sh "$EXT_FLAGS" add "$ext"
done

if [ "$DRY" = 0 ]; then
  docker compose up -d --build
  echo "Waiting for the server (up to 120 s)..."
  for _ in $(seq 1 60); do
    curl -fsS "$URL/v1/health" >/dev/null 2>&1 && break
    sleep 2
  done
  curl -fsS "$URL/v1/health" >/dev/null 2>&1 || {
    echo "install: the server did not answer in 120 s. See: docker compose logs api" >&2
    exit 1
  }
  code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$URL/v1/admin/users" \
    -H "x-apertonodo-key: $API_KEY" -H 'content-type: application/json' \
    -d "{\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASSWORD\",\"is_admin\":true}")"
  case "$code" in
    201) ;;
    409) echo "The administrator $ADMIN_USER already exists (an earlier run created it)." ;;
    *) echo "install: could not create the administrator (HTTP $code). Run the script again; see: docker compose logs api" >&2
       exit 1 ;;
  esac
else
  echo "(dry run: docker compose up, waiting and the administrator are skipped)"
fi

echo
echo "Apertonodo is running at $URL (from other devices: http://<this machine's address>:$PORT)"
echo "First login in the app:"
echo "  address:  http://<this machine's address>:$PORT"
echo "  name:     $ADMIN_USER"
echo "  password: $ADMIN_PASSWORD"
echo "The password is also stored in .env. Put your music into ./music (or set MUSIC_PATH in .env)."
