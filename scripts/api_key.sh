#!/usr/bin/env bash
# shellcheck shell=bash
# Public contour key: the only place that knows where to get it.
# Source it, do not execute it.
#
# Order is identical everywhere:
#   1. Environment variable MUSIC_API_KEY — provided by GitLab (masked).
#   2. File .env in project root — kept on Mac. File is in .gitignore.
#
# There is no key in the repository and cannot be: commit with key would expose contour
# to anyone viewing history. To generate a new one:
#   python3 -c 'import secrets; print(secrets.token_urlsafe(32))'
#
# Scripts call require_api_key and do not start without key. Silent
# run without key would look like "audio did not play", and cause would be sought
# in phone, while it is in a single unset variable.

if [[ -z "${MUSIC_API_KEY:-}" ]]; then
  _flowtune_env="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env"
  if [[ -f "$_flowtune_env" ]]; then
    MUSIC_API_KEY="$(sed -n 's/^MUSIC_API_KEY=//p' "$_flowtune_env" | tail -n 1 |
      sed 's/^"//; s/"$//')"
    export MUSIC_API_KEY
  fi
  unset _flowtune_env
fi

# Same lower bound as on server (server/app/guard.py): shorter is
# a dummy like "test", not a lock.
require_api_key() {
  local key="${MUSIC_API_KEY:-}"
  if [[ "${#key}" -lt 32 ]]; then
    echo "FAIL: no public contour key (MUSIC_API_KEY)." >&2
    echo "      Put it in .env at project root as a single line:" >&2
    echo "      MUSIC_API_KEY=<key>" >&2
    echo "      File .env is in .gitignore. Generate a new key:" >&2
    echo "      python3 -c 'import secrets; print(secrets.token_urlsafe(32))'" >&2
    return 1
  fi
  return 0
}
