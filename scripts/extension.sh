#!/usr/bin/env bash
# Apertonodo extensions (FT-906): one command to add, remove or list an extension.
#
# Usage: ./scripts/extension.sh [--dry-run] [--no-up] add <name> | remove <name> | list
#   --dry-run  change .env only; no Docker call, no waiting
#   --no-up    change .env only; the caller starts the services (install.sh does)
# No questions; one line per step. Repeating a command changes nothing. If a step fails, .env is
# put back exactly as it was before the command.
#
# Each extension is extensions/<name>/compose.yml and may have extensions/<name>/extension.env, a
# few KEY=VALUE lines (no quotes) that say what it needs:
#   REQUIRES=<names>          extensions added before it (space separated)
#   ADD_TO_EXTENSIONS=yes|no  whether the server asks it directly (name=url in EXTENSIONS); default yes
#   WAIT_URL=<url>            address the server must be able to open before POST_ADD
#   POST_ADD=<command>        run inside the api container after the start
#   NEXT_STEP=<text>          printed at the end (\n is a line break)
# The script puts compose.yml into COMPOSE_FILE in .env. Where extensions/ is missing it is fetched from
# APERTONO_EXTENSIONS_REPO at APERTONO_EXTENSIONS_REF, or copied from APERTONO_EXTENSIONS_SRC=<dir
# with extensions/> without network.
set -euo pipefail

DRY=0
UP=1
while [ "${1:-}" = --dry-run ] || [ "${1:-}" = --no-up ]; do
  case "$1" in --dry-run) DRY=1 ;; --no-up) UP=0 ;; esac
  shift
done
CMD="${1:-}"
NAME="${2:-}"

BASE="docker-compose.yml"
REPO="${APERTONO_EXTENSIONS_REPO:-https://github.com/apertono/extensions}"
REF="${APERTONO_EXTENSIONS_REF:-v0.9.0-beta}"
SRC="${APERTONO_EXTENSIONS_SRC:-}"

usage() { echo "usage: extension.sh [--dry-run] [--no-up] add|remove <name> | list" >&2; exit 2; }
fail() { echo "extension: $1" >&2; exit 1; }
say() { echo "extension: $1"; }

case "$CMD" in
  list) [ "$#" -eq 1 ] || usage ;;
  add|remove) [ "$#" -eq 2 ] || usage
    case "$NAME" in [a-z]*) ;; *) usage ;; esac
    case "$NAME" in *[!a-z0-9-]*) usage ;; esac
    [ "${#NAME}" -le 32 ] || usage ;;
  *) usage ;;
esac

cd "$(dirname "$0")/.."
[ -f "$BASE" ] || fail "no $BASE here: run from the Apertonodo folder"
[ -e .env ] || fail "no .env: run scripts/install.sh first"

BACKUP="$(mktemp)"
cp .env "$BACKUP"
restore_env() {
  local rc=$?
  [ "$rc" -eq 0 ] || cat "$BACKUP" > .env
  rm -f "$BACKUP"
}
trap restore_env EXIT

value() { sed -n "s/^$1=//p" .env | tail -1; }

# set_env KEY VALUE: change the line or append it; the file keeps its mode (600).
set_env() {
  local tmp
  tmp="$(mktemp)"
  if grep -q "^$1=" .env; then
    awk -v k="$1" -v v="$2" 'BEGIN{FS=OFS="="} $1==k{print k "=" v; next} {print}' .env > "$tmp"
  else
    { cat .env; echo "$1=$2"; } > "$tmp"
  fi
  cat "$tmp" > .env
  rm -f "$tmp"
}

compose_files() { local v; v="$(value COMPOSE_FILE)"; echo "${v:-$BASE}"; }
has_file() { case ":$(compose_files):" in *":extensions/$1/compose.yml:"*) return 0 ;; esac; return 1; }

# meta <name> <KEY>: a value from extensions/<name>/extension.env (empty when absent)
meta() { sed -n "s/^$2=//p" "extensions/$1/extension.env" 2>/dev/null | tail -1; }

fetch() {
  [ -f "extensions/$1/compose.yml" ] && return 0
  local tmp
  tmp="$(mktemp -d)"
  if [ -n "$SRC" ]; then
    say "fetch $1 from $SRC"
    [ -d "$SRC/extensions/$1" ] || fail "no $SRC/extensions/$1"
    tar -C "$SRC/extensions" --exclude=.venv --exclude=__pycache__ -cf - "$1" | tar -C "$tmp" -xf -
  else
    say "fetch $1 from $REPO ($REF)"
    command -v curl >/dev/null 2>&1 || fail "curl is missing"
    curl -fsSL "$REPO/archive/$REF.tar.gz" -o "$tmp/src.tar.gz" || fail "could not download $REPO at $REF (set APERTONO_EXTENSIONS_SRC=<dir> to use a local copy)"
    mkdir "$tmp/src"
    tar -xzf "$tmp/src.tar.gz" -C "$tmp/src" --strip-components=1 || fail "the download is not a valid archive"
    [ -d "$tmp/src/extensions/$1" ] || fail "no extensions/$1 in $REPO at $REF"
    cp -R "$tmp/src/extensions/$1" "$tmp/$1"
  fi
  mkdir -p extensions
  rm -rf "extensions/$1"
  cp -R "$tmp/$1" "extensions/$1"
  rm -rf "$tmp" "extensions/$1/.venv"
  [ -f "extensions/$1/compose.yml" ] || fail "extensions/$1 has no compose.yml"
}

add_pair() { # list, pair -> list without the pair's name, then with the pair
  local out="" item
  IFS=, read -ra items <<< "$1"
  for item in "${items[@]:-}"; do
    [ -n "$item" ] && [ "${item%%=*}" != "${2%%=*}" ] && out="$out${out:+,}$item"
  done
  echo "$out${out:+,}$2"
}
drop_pair() { # list, name
  local out="" item
  IFS=, read -ra items <<< "$1"
  for item in "${items[@]:-}"; do
    [ -n "$item" ] && [ "${item%%=*}" != "$2" ] && out="$out${out:+,}$item"
  done
  echo "$out"
}

compose() { docker compose "$@"; }

start() {
  if [ "$DRY" = 1 ] || [ "$UP" = 0 ]; then say "start skipped"; return 0; fi
  docker compose version >/dev/null 2>&1 || fail "Docker Compose is missing"
  say "start services (docker compose up -d --build)"
  compose up -d --build
}

# Names also come from a downloaded extension.env (REQUIRES): check them before any path use.
valid_name() {
  case "$1" in [a-z]*) ;; *) return 1 ;; esac
  case "$1" in *[!a-z0-9-]*) return 1 ;; esac
  [ "${#1}" -le 32 ]
}

do_add() {
  local n="$1" dep
  valid_name "$n" || fail "bad extension name: $n"
  fetch "$n"
  for dep in $(meta "$n" REQUIRES); do do_add "$dep"; done
  if has_file "$n"; then
    say "$n: already in COMPOSE_FILE"
  else
    set_env COMPOSE_FILE "$(compose_files):extensions/$n/compose.yml"
    say "$n: added to COMPOSE_FILE"
  fi
  if [ "$(meta "$n" ADD_TO_EXTENSIONS)" != no ]; then
    set_env EXTENSIONS "$(add_pair "$(value EXTENSIONS)" "$n=http://$n:8080")"
    say "$n: listed in EXTENSIONS"
  fi
}

do_remove() {
  local n="$1" f="" item other dep
  IFS=: read -ra items <<< "$(compose_files)"
  for item in "${items[@]}"; do
    other="${item#extensions/}"; other="${other%/compose.yml}"
    [ "$other" = "$item" ] || [ "$other" = "$n" ] && continue
    for dep in $(meta "$other" REQUIRES); do
      [ "$dep" != "$n" ] || fail "$other needs $n: remove $other first"
    done
  done
  for item in "${items[@]}"; do
    [ "$item" != "extensions/$n/compose.yml" ] && f="$f${f:+:}$item"
  done
  set_env COMPOSE_FILE "$f"
  set_env EXTENSIONS "$(drop_pair "$(value EXTENSIONS)" "$n")"
  say "$n: removed from COMPOSE_FILE and EXTENSIONS (its data volumes stay)"
}

after_start() {
  local n="$1" url cmd
  [ "$DRY" = 0 ] && [ "$UP" = 1 ] || return 0
  url="$(meta "$n" WAIT_URL)"
  if [ -n "$url" ]; then
    say "$n: wait for $url (up to 120 s)"
    local ok=0
    for _ in $(seq 1 60); do
      if compose exec -T api python -c "import urllib.request as u; u.urlopen('$url', timeout=3)" >/dev/null 2>&1; then ok=1; break; fi
      sleep 2
    done
    [ "$ok" = 1 ] || fail "$n did not answer in 120 s. See: docker compose logs $n"
  fi
  cmd="$(meta "$n" POST_ADD)"
  if [ -n "$cmd" ]; then
    say "$n: run in the server: $cmd"
    compose exec -T api sh -c "$cmd" >/dev/null || fail "$n: '$cmd' failed. See: docker compose logs api"
  fi
}

case "$CMD" in
  add)
    do_add "$NAME"
    start
    after_start "$NAME"
    say "$NAME: done"
    next="$(meta "$NAME" NEXT_STEP)"
    [ -z "$next" ] || printf '%b\n' "$next"
    ;;
  remove)
    do_remove "$NAME"
    if [ "$DRY" = 1 ] || [ "$UP" = 0 ]; then say "stop skipped"; else
      say "stop services (docker compose up -d --remove-orphans)"; compose up -d --remove-orphans
    fi
    say "$NAME: done"
    ;;
  list)
    seen=" "
    for n in $(compose_files | tr ':' ' '); do
      case "$n" in extensions/*/compose.yml) n="${n#extensions/}"; echo "${n%/compose.yml} on"; seen="$seen${n%/compose.yml} " ;; esac
    done
    for d in extensions/*/; do
      n="$(basename "$d")"
      [ -f "$d/compose.yml" ] || continue
      case "$seen" in *" $n "*) ;; *) echo "$n off" ;; esac
    done
    ;;
esac
