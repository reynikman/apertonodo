#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/mobile"

# shellcheck source=scripts/mobile_env.sh
source "$ROOT/scripts/mobile_env.sh"

if ! command -v flutter >/dev/null 2>&1; then
  echo "ERROR: Flutter SDK is not installed"
  exit 1
fi

flutter pub get
bash "$ROOT/scripts/dart_format.sh" --output=none --set-exit-if-changed .
dart analyze --fatal-infos
flutter test
echo "mobile verification passed"
