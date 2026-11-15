#!/usr/bin/env bash
# Single command that checks everything that can be checked without a phone.
#
#   bash scripts/check.sh
#
# Prints what was checked and what broke in Russian. Non-zero return code
# means "something is wrong" — list at the bottom.
set -uo pipefail

# printf counts bytes, and UTF-8 Cyrillic is multibyte — without an explicit
# locale columns misalign.
export LC_ALL="${LC_ALL:-ru_RU.UTF-8}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; OFF=$'\033[0m'

# Pad a string with spaces to desired width in characters, not in bytes.
pad() {
  local text="$1" width="$2" len=${#1}
  printf '%s' "$text"
  while [ "$len" -lt "$width" ]; do printf ' '; len=$((len + 1)); done
}

FAILED=()
LOG_DIR="$ROOT/.check-logs"
rm -rf "$LOG_DIR" && mkdir -p "$LOG_DIR"

step() {
  local name="$1" hint="$2"; shift 2
  local log
  log="$LOG_DIR/$(echo "$name" | tr ' /' '__').log"
  printf '  '; pad "$name" 34
  if "$@" >"$log" 2>&1; then
    printf '%sok%s\n' "$GREEN" "$OFF"
  else
    printf '%sbroken%s\n' "$RED" "$OFF"
    printf '    %s%s%s\n' "$DIM" "$hint" "$OFF"
    printf '    %sdetails: %s%s\n' "$DIM" "${log/#$ROOT\//}" "$OFF"
    FAILED+=("$name")
  fi
}

# Public slice (P10): a step whose file is not in the slice is skipped, by the absence of the file.
# In the working repository (plan/ is there) a missing file is a breakage, not a skip.
need() {
  local name="$1" f; shift
  for f in "$@"; do
    [ -e "$f" ] && continue
    printf '  '; pad "$name" 34
    if [ -d plan ]; then
      printf '%sbroken%s\n    %smissing: %s%s\n' "$RED" "$OFF" "$DIM" "$f" "$OFF"
      FAILED+=("$name")
    else
      printf '%sskipped: not in public slice%s\n' "$DIM" "$OFF"
    fi
    return 1
  done
}

# App paths — the `.app-changes` list from .gitlab-ci.yml turned into a
# regular expression: the same filter CI uses to decide whether to build the APK.
app_pattern() {
  [ -f .gitlab-ci.yml ] || return 0
  sed -n '/^\.app-changes: &app-changes/,/^$/s/^  - //p' .gitlab-ci.yml |
    sed -e 's/\./\\./g' -e 's/\*\*\/\*/@ANY@/g' -e 's/\*/[^\/]*/g' -e 's/@ANY@/.*/g' \
        -e 's/^/^/' -e 's/$/$/' | paste -sd'|' -
}

# Did the app change compared to origin/main, including uncommitted files. If no origin/main
# or no list — assume changed: an extra run is cheaper than a missed breakage.
app_changed() {
  [ "${FLOWTUNE_CHECK_APP:-}" = 1 ] && return 0
  local base pattern
  base="$(git merge-base HEAD origin/main 2>/dev/null)" || return 0
  pattern="$(app_pattern)"
  [ -n "$pattern" ] || return 0
  # grep without -q: with pipefail early exit of grep gives git SIGPIPE and false "did not change".
  { git diff --name-only "$base"; git ls-files --others --exclude-standard; } | grep -E "$pattern" >/dev/null
}

echo
echo "Apertonodo check. Phone not required."
echo

echo "Server"
step "server tests" \
  "Server logic broken. See last lines of log." \
  bash scripts/backend_ci.sh
EXT_NAMES=""
for dir in extensions/*/; do
  [ -d "$dir" ] || continue
  name="$(basename "$dir")"
  EXT_NAMES="$EXT_NAMES $name"
done
if [ -n "$EXT_NAMES" ]; then
  step "extension tests" \
    "Extension logic broken. See last lines of log." \
    bash -c 'for name in "$@"; do bash scripts/extension_tests.sh "$name" || exit 1; done' _ $EXT_NAMES
else
  printf '  '; pad "extension tests" 34; printf '%sskipped%s\n' "$DIM" "$OFF"
  printf '    %sskipped: extensions/ not in this copy (they live in the separate extensions repository)%s\n' "$DIM" "$OFF"
fi
need "core and extensions chain" scripts/chain_check.sh && step "core and extensions chain" \
  "Services do not fit together: core and its source extensions. See log; three known breakages: bash scripts/chain_check.sh --break all." \
  bash scripts/chain_check.sh
step "source words in core" \
  "Source word appeared in core (see scripts/core_words.py). Rename or explain with line in scripts/core_words.allow." \
  python3 scripts/core_words.py --strict
# The same file that the static-analysis job runs in GitLab.
step "server code analysis" \
  "ruff or mypy found typo or mismatched types. Reports: ruff-report.txt, mypy-report.txt." \
  bash scripts/static_analysis.sh

echo
echo "App"
need "Flutter/Dart version floor" scripts/flutter_floor_check.py .gitlab-ci.yml && step "Flutter/Dart version floor" \
  "Packages in pubspec.lock require Flutter or Dart newer than in CI and pubspec.yaml." \
  python3 scripts/flutter_floor_check.py mobile/pubspec.lock mobile/pubspec.yaml .gitlab-ci.yml
# When editing the server alone these two steps took more than half the run
# (~5.5 min on Mac). CI without app changes does not run them either.
APP_SKIPPED=""
if app_changed; then
  step "app tests" \
    "App logic broken or Dart analyzer found error." \
    bash scripts/mobile_ci.sh
  # The same file that the mobile-release-build job runs in GitLab.
  step "release build" \
    "Release does not build: R8, Gradle or shrinking rules." \
    bash scripts/mobile_release_check.sh
else
  APP_SKIPPED=1
  printf '  '; pad "tests and release build" 34; printf '%sskipped%s\n' "$DIM" "$OFF"
  printf '    %sapp did not change from origin/main (.app-changes). Run anyway: FLOWTUNE_CHECK_APP=1%s\n' \
    "$DIM" "$OFF"
fi

echo
echo "Scripts"
if command -v shellcheck >/dev/null 2>&1; then
  # The same file that the scripts-lint job runs in GitLab.
  step "script analysis" \
    "shellcheck found error in one of project scripts." \
    sh scripts/lint_shell.sh
else
  printf '  '; pad "script analysis" 34; printf '%sskipped%s\n' "$DIM" "$OFF"
  printf '    %sshellcheck not installed: brew install shellcheck. It still runs in CI.%s\n' \
    "$DIM" "$OFF"
fi
need "gap measure" scripts/gap_measure_check.py && step "gap measure" \
  "Track gap measure (P7, Р-A62) fails on synthetic recordings." \
  python3 scripts/gap_measure_check.py

echo
echo "Structure and privacy"
need "files in place" scripts/unlazy/check_layout.mjs && step "files in place" \
  "Required file or directory missing." \
  node scripts/unlazy/check_layout.mjs
need "decisions and plan cards" scripts/plan_lint.py plan && step "decisions and plan cards" \
  "plan/ missing decision evidence or card format broken." \
  python3 scripts/plan_lint.py
need "card check untouched" scripts/check_guard.py plan && step "card check untouched" \
  "Executor changed check file or card without lead signature." \
  python3 scripts/check_guard.py
step "Android icon and splash" \
  "Icon wrong, clips launcher mask, title not Apertono or splash is white." \
  python3 scripts/icon_check.py
need "mutation control anchors" scripts/unlazy/anchors.mjs && step "mutation control anchors" \
  "A control breaks a code line that no longer exists: update the case in scripts/unlazy/ (run: node scripts/unlazy/<control>.mjs --anchors) or mobile/tool/negative_control.dart (run: cd mobile && dart run tool/negative_control.dart --anchors)." \
  bash -c 'rc=0; for c in search_negative songs_negative mbcopy_negative genres_negative covers_negative design_negative mutation_control; do echo "== $c"; node scripts/unlazy/$c.mjs --anchors || rc=1; done; echo "== negative_control (app)"; (cd mobile && dart run tool/negative_control.dart --anchors) || rc=1; exit $rc'
need "no traces of foreign project" scripts/unlazy/check_no_baza_leak.mjs && step "no traces of foreign project" \
  "Identifiers or telemetry of Lomonosov Base leaked into code." \
  node scripts/unlazy/check_no_baza_leak.mjs

echo
echo "Secrets"
if command -v gitleaks >/dev/null 2>&1; then
  # The same file that the gitleaks job runs in GitLab.
  step "scanner canary" \
    "Scanner does not detect seeded token — results cannot be trusted." \
    sh scripts/secret_scan.sh canary
  step "no keys in repository" \
    "Secret found. Open report and remove it from history." \
    env REPORT=.check-logs/gitleaks.json sh scripts/secret_scan.sh repo
else
  printf '  '; pad "secret scanner" 34; printf '%sskipped%s\n' "$DIM" "$OFF"
  printf '    %sgitleaks not installed: brew install gitleaks. It still runs in CI.%s\n' \
    "$DIM" "$OFF"
fi

echo
if [ ${#FAILED[@]} -eq 0 ]; then
  echo "${GREEN}All good.${OFF} You can continue working."
  echo
  echo "${DIM}What this does not verify: audio on physical phone and lock on production endpoint.${OFF}"
  [ -n "$APP_SKIPPED" ] && echo "${DIM}App was not checked: it did not change from origin/main.${OFF}"
  [ -e scripts/check_device.sh ] && echo "${DIM}Connect phone and run: bash scripts/check_device.sh${OFF}"
  [ -e scripts/public_guard_check.sh ] && echo "${DIM}Lock on production endpoint: bash scripts/public_guard_check.sh${OFF}"
  [ -e scripts/ci_status.sh ] && echo "${DIM}The same checks run in GitLab on every push: bash scripts/ci_status.sh${OFF}"
  echo
  exit 0
fi

echo "${RED}Broken: ${#FAILED[@]}${OFF}"
for name in "${FAILED[@]}"; do echo "  • $name"; done
echo
echo "${DIM}Logs of each check are in .check-logs/${OFF}"
echo
exit 1
