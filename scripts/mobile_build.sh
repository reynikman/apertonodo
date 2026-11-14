#!/usr/bin/env bash
# Keep the Gradle flavor and Dart environment in agreement.
# Usage: scripts/mobile_build.sh <dev|staging|prod> <debug|profile|release> [apk|appbundle]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/mobile_env.sh
source "$ROOT/scripts/mobile_env.sh"
# shellcheck source=scripts/api_key.sh
source "$ROOT/scripts/api_key.sh"
cd "$ROOT/mobile"

FLAVOR="${1:-}"
MODE="${2:-}"
ARTIFACT="${3:-apk}"
shift 3 2>/dev/null || shift $#

case "$FLAVOR" in
  dev|staging|prod) ;;
  *) echo "ERROR: flavor must be dev, staging or prod (got '${FLAVOR}')" >&2; exit 2 ;;
esac
case "$MODE" in
  debug|profile|release) ;;
  *) echo "ERROR: mode must be debug, profile or release (got '${MODE}')" >&2; exit 2 ;;
esac
case "$ARTIFACT" in
  apk|appbundle) ;;
  *) echo "ERROR: artifact must be apk or appbundle (got '${ARTIFACT}')" >&2; exit 2 ;;
esac

# Public build runs without shared key: token-based login (FT-047/FT-049).
if [[ "$FLAVOR" != "prod" ]]; then
  require_api_key || exit 1
fi

CONFIG="config/${FLAVOR}.json"
[[ -f "$CONFIG" ]] || { echo "ERROR: missing $CONFIG" >&2; exit 2; }

EXTRA=()
USE_DEVICE_HOST=0
for arg in ${@+"$@"}; do
  if [[ "$arg" == "--device" ]]; then
    USE_DEVICE_HOST=1
  else
    EXTRA+=("$arg")
  fi
done

API_OVERRIDE="${MUSIC_API_BASE_URL:-}"
if [[ "$USE_DEVICE_HOST" == "1" && -z "$API_OVERRIDE" ]]; then
  if [[ "$FLAVOR" != "dev" ]]; then
    echo "ERROR: --device only makes sense for the dev flavor" >&2
    exit 2
  fi
  LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || true)"
  [[ -n "$LAN_IP" ]] || LAN_IP="$(ipconfig getifaddr en1 2>/dev/null || true)"
  [[ -n "$LAN_IP" ]] || LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  if [[ -z "$LAN_IP" ]]; then
    echo "ERROR: could not detect a LAN address; set MUSIC_API_BASE_URL yourself" >&2
    exit 2
  fi
  API_OVERRIDE="http://${LAN_IP}:8088"
fi

if [[ -n "$API_OVERRIDE" ]]; then
  EXTRA+=(--dart-define=MUSIC_API_BASE_URL="$API_OVERRIDE")
fi
# Bug report identifies build by commit: pubspec version does not change.
APP_SHA="$(git -C "$ROOT" rev-parse --short=8 HEAD 2>/dev/null || true)"
[[ -z "$APP_SHA" ]] || EXTRA+=(--dart-define=APP_VERSION="$APP_SHA")
# Auto-update compares releases by version from pubspec, not by commit.
APP_RELEASE="$(grep '^version:' "$ROOT/mobile/pubspec.yaml" | awk '{print $2}')"
[[ -z "$APP_RELEASE" ]] || EXTRA+=(--dart-define=APP_RELEASE="$APP_RELEASE")

EFFECTIVE_URL="$API_OVERRIDE"
[[ -n "$EFFECTIVE_URL" ]] || EFFECTIVE_URL="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["MUSIC_API_BASE_URL"])' "$CONFIG")"

echo "flavor:   $FLAVOR"
echo "mode:     $MODE"
echo "artifact: $ARTIFACT"
echo "api:      $EFFECTIVE_URL"
if [[ "$EFFECTIVE_URL" == *"127.0.0.1"* || "$EFFECTIVE_URL" == *"localhost"* ]]; then
  echo
  echo "NOTE: this build points at the loopback address. On a real phone that is"
  echo "      the phone itself. Use --device or set MUSIC_API_BASE_URL."
  echo
fi

# Key goes into build, not into output: `set -x` would print it completely, and this
# output is read both in terminal and in CI log.
CMD=(
  flutter build "$ARTIFACT"
  "--$MODE"
  --flavor "$FLAVOR"
  --dart-define-from-file="$CONFIG"
  ${EXTRA[@]+"${EXTRA[@]}"}
)
if [[ "$FLAVOR" == "prod" ]]; then
  printf '+ %s\n' "${CMD[*]}"
  "${CMD[@]}"
else
  printf '+ %s --dart-define=MUSIC_API_KEY=***\n' "${CMD[*]}"
  "${CMD[@]}" --dart-define=MUSIC_API_KEY="$MUSIC_API_KEY"
fi
