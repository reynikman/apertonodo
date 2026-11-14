#!/usr/bin/env bash
# Same lock, but on server launched here and now.
#
#   bash scripts/public_guard_local.sh
#
# Why separate from public_guard_check.sh: that one tests live address and requires
# real key — proving deployed server. This one launches its own
# server with one-time key and tests code. It needs no secret, so
# runs locally and in CI, failing exactly when lock is broken.
#
# PYTHON is interpreter with server dependencies. Locally that is
# server/.venv/bin/python, in CI — system python.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="${PYTHON:-python}"

if ! command -v "$PYTHON" >/dev/null 2>&1 && [[ ! -x "$PYTHON" ]]; then
  echo "FAIL: interpreter '$PYTHON' missing — set PYTHON" >&2
  exit 1
fi

PORT="$(python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()')"
# Key is one-time: it lives only inside this run and is stored nowhere.
KEY="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
# Not `mktemp -t name`: on mac BSD-mktemp appends random suffix automatically, while GNU
# on Linux responds "too few X's in template" — this script runs on both
# platforms, and first CI run encountered exactly this.
LOG="$(mktemp "${TMPDIR:-/tmp}/flowtune-guard-local.XXXXXX")"
PID=""
EXT_PID=""
TONES="$(mktemp -d "${TMPDIR:-/tmp}/flowtune-guard-tones.XXXXXX")"

cleanup() {
  if [[ -n "$EXT_PID" ]]; then
    kill "$EXT_PID" 2>/dev/null
    { wait "$EXT_PID"; } 2>/dev/null
  fi
  rm -rf "$TONES"
  if [[ -n "$PID" ]]; then
    kill "$PID" 2>/dev/null
    # Terminated background bash process otherwise announces with "Terminated" in
    # stderr, looking like a failure in log. Wait for it silently.
    { wait "$PID"; } 2>/dev/null
  fi
  rm -f "$LOG"
}
trap cleanup EXIT

# Watchdog tests (conftest) clear EXTENSIONS on import, so address bypasses via GUARD_EXTENSIONS.
# Core does not fetch audio itself (P8): plays only via extension. To verify lock we spin up
# fake extension from tests with one file under test tone name.
EXT_PORT="$(python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()')"
cp "$ROOT/contracts/fixtures/audio/tone-440hz-4s.mp3" "$TONES/Flowtune - Test Tone Short.mp3"
(
  cd "$ROOT/server/tests" || exit 1
  TONES="$TONES" EXT_PORT="$EXT_PORT" exec "$PYTHON" -c 'import os, uvicorn
from pathlib import Path
from fake_extension import make_fake_extension
uvicorn.run(make_fake_extension(Path(os.environ["TONES"])), host="127.0.0.1", port=int(os.environ["EXT_PORT"]), log_level="warning")' \
    >/dev/null 2>&1
) &
EXT_PID="$!"

(
  cd "$ROOT/server" || exit 1
  # Database is not needed: /v1/ready is blocked by lock before reaching it.
  # Live sources are disabled intentionally: verifying lock, not catalog, and
  # search for test tone must come from fixture. In CI live source
  # variables are set on project and provided to every job — with them this server
  # would query MusicBrainz, making lock check dependent on internet.
  #
  # `exec`, not plain run: otherwise PID got subshell number, kill
  # removed subshell, leaving server orphaned. Audit on September 18 counted
  # twenty-five such orphans on mac from check.sh runs.
  # The child loads the pytest socket guard. A provider variable this list
  # does not name still cannot open an external socket. Live smoke is a
  # different script and is not started here.
  unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
  MUSIC_API_KEY="$KEY" PORT="$PORT" BIND_HOST=127.0.0.1 DATABASE_URL='' \
    MUSICBRAINZ_ENABLED='' EXTENSIONS='' GUARD_EXTENSIONS="fake=http://127.0.0.1:$EXT_PORT" BOOK_EXTENSIONS='' LASTFM_API_KEY='' LASTFM_API_SECRET='' PLAY_SENDER='' MBCOPY_ENABLED='' NEWS_PROXY='' LYRICS_URL='' PODCASTS_LIVE='' GLITCHTIP_DSN='' GLITCHTIP_MOBILE_DSN='' \
    PYTHONPATH="$ROOT/server/tests${PYTHONPATH:+:$PYTHONPATH}" \
    exec "$PYTHON" -c 'import conftest, os, runpy; os.environ["EXTENSIONS"] = os.environ.pop("GUARD_EXTENSIONS"); runpy.run_module("app.serve", run_name="__main__")' \
    >"$LOG" 2>&1
) &
PID="$!"

for _ in $(seq 1 60); do
  if curl -fsS --max-time 2 "http://127.0.0.1:$PORT/v1/health" >/dev/null 2>&1; then
    break
  fi
  # Server might fail to start at all — e.g. if key is shorter than allowed.
  # Then no need to wait all thirty seconds, reason is already in log.
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "FAIL: server failed to start:" >&2
    tail -20 "$LOG" >&2
    exit 1
  fi
  sleep 0.5
done

if ! curl -fsS --max-time 2 "http://127.0.0.1:$PORT/v1/health" >/dev/null 2>&1; then
  echo "FAIL: server did not respond to /v1/health in 30 seconds:" >&2
  tail -20 "$LOG" >&2
  exit 1
fi

MUSIC_API_KEY="$KEY" MUSIC_API_BASE_URL="http://127.0.0.1:$PORT" \
  bash "$ROOT/scripts/public_guard_check.sh"
