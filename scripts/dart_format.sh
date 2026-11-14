#!/usr/bin/env bash
# Runs dart at the version from mobile/.dart-format-version (the CI image Dart).
# Keeps the Mac and CI formatting with one version. Arguments are those of
# `dart format`; the only exception is `--version`, which goes to dart itself.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WANT="$(tr -d '[:space:]' < "$ROOT/mobile/.dart-format-version")"

have=""
if command -v dart >/dev/null 2>&1; then
  have="$(dart --version 2>&1 | sed -n 's/^Dart SDK version: \([0-9][0-9.]*\).*/\1/p')"
fi

# `--version` goes to dart itself, everything else to `dart format`.
run() {
  local d="$1"; shift
  if [ "${1:-}" = "--version" ]; then exec "$d" "$@"; fi
  exec "$d" format "$@"
}

if [ "$have" = "$WANT" ]; then
  run dart "$@"
fi

if [ -n "${CI:-}" ]; then
  echo "ERROR: Dart in the image is ${have:-not found}, mobile/.dart-format-version says $WANT: update the file" >&2
  exit 1
fi

case "$(uname -s)" in
  Darwin) os=macos ;;
  Linux) os=linux ;;
  *) echo "ERROR: dart_format.sh: system $(uname -s) is not supported" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  arm64|aarch64) arch=arm64 ;;
  x86_64|amd64) arch=x64 ;;
  *) echo "ERROR: dart_format.sh: architecture $(uname -m) is not supported" >&2; exit 1 ;;
esac

DIR="${XDG_CACHE_HOME:-$HOME/.cache}/apertono/dart-$WANT"
if [ ! -x "$DIR/dart-sdk/bin/dart" ]; then
  url="https://storage.googleapis.com/dart-archive/channels/stable/release/$WANT/sdk/dartsdk-$os-$arch-release.zip"
  echo "dart_format.sh: PATH has Dart ${have:-none}, need $WANT; downloading the SDK (once): $url" >&2
  mkdir -p "$(dirname "$DIR")"
  tmp="$(mktemp -d "$(dirname "$DIR")/.dl-XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  if ! curl -fsSL --retry 2 -o "$tmp/sdk.zip" "$url" || ! unzip -q "$tmp/sdk.zip" -d "$tmp/x"; then
    echo "ERROR: could not download or unpack Dart $WANT from $url" >&2
    exit 1
  fi
  rm -rf "$DIR"
  mv "$tmp/x" "$DIR"
  # `run` ends in exec, which skips the EXIT trap: remove the archive now.
  rm -rf "$tmp"
  trap - EXIT
fi

run "$DIR/dart-sdk/bin/dart" "$@"
