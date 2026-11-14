#!/usr/bin/env bash
# Release build succeeds: R8, resource shrinking, prod flavor.
#
#   bash scripts/mobile_release_check.sh
#
# Single file for two contexts: mobile-release-build job and scripts/check.sh.
# Previously release did not build in any flavor — build.gradle.kts referenced
# proguard-rules.pro which did not exist — and no check caught this:
# owner was using a debug build (audit September 18).
#
# Build key is one-time, and built APK is deleted: this verifies build succeeds,
# not a build for phone installation. For phone — bash scripts/mobile_build.sh prod release apk.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APK="$ROOT/mobile/build/app/outputs/flutter-apk/app-prod-release.apk"

MUSIC_API_KEY="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')" \
  ORG_GRADLE_PROJECT_allowDebugSigning=true \
  bash "$ROOT/scripts/mobile_build.sh" prod release apk

if [[ ! -s "$APK" ]]; then
  echo "FAIL: build passed, but APK did not appear: $APK" >&2
  exit 1
fi
size="$(wc -c <"$APK" | tr -d ' ')"
rm -f "$APK" "$APK.sha1"
echo "release build passed ($size bytes; APK removed — key in it was one-time)"
