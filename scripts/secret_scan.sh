#!/bin/sh
# Secret scan. One file for two environments: local check and the
# gitleaks job in GitLab. Previously both canary and scan were written twice.
#
#   sh scripts/secret_scan.sh canary   # scanner must find the planted token
#   sh scripts/secret_scan.sh repo     # repository must contain no keys
#   sh scripts/secret_scan.sh          # both
#
# Written in POSIX sh intentionally: gitleaks image has neither bash nor python3.
#
# Rules from Lomonosov Base, learned from its own failures:
#   1. Non-zero exit code, other than "secrets found", is a scanner failure,
#      not a clean result.
#   2. No report file means scan is unproven.
#   3. Without positive control, "0 findings" means nothing.
set -u

REPORT="${REPORT:-gitleaks-report.json}"
# Scanner version is identical for both environments. CI had v8.18.4 which does not understand
# [[allowlists]] from .gitleaks.toml, while locally it was 8.30.1 which does: the exact
# same repository received different answers (September 18 audit). Image in
# .gitlab-ci.yml keeps the same version as here.
GITLEAKS_VERSION="8.30.1"
CONFIG="${CONFIG:-.gitleaks.toml}"
MODE="${1:-all}"

same_version() {
  HAVE="$(gitleaks version 2>/dev/null | sed 's/^v//')"
  if [ "$HAVE" != "$GITLEAKS_VERSION" ]; then
    echo "FAIL: gitleaks ${HAVE:-not found}, need $GITLEAKS_VERSION — other version reads .gitleaks.toml differently."
    return 1
  fi
  echo "gitleaks $HAVE"
  return 0
}

canary() {
  # Canary is a GitLab token: exactly the dangerous kind here. AWS example key
  # from documentation does not work, gitleaks keeps it in its allowlist and
  # silently misses it — verified, exit 0 instead of 1. Literal is assembled from
  # parts, otherwise repository scan would find it right in this file.
  DIR="$(mktemp -d)"
  printf '%s-%s\n' "glpat" "AbCdEfGhIjKlMnOpQrSt" > "$DIR/canary.txt"
  gitleaks detect --source="$DIR" --no-git --no-banner >/dev/null 2>&1
  RC=$?
  rm -rf "$DIR"
  if [ "$RC" -ne 1 ]; then
    echo "FAIL: positive control failed (exit $RC) — scanner does not detect seeded token."
    return 1
  fi
  echo "Positive control: OK"
  return 0
}

repo() {
  rm -f "$REPORT"
  gitleaks detect --source="." --config="$CONFIG" \
    --report-format json --report-path "$REPORT" \
    --redact --no-banner
  RC=$?
  echo "gitleaks exit code: $RC"
  # 0 — clean, 1 — secrets found. Anything else means the scanner failed
  # to run, and that is also a red result, not "zero findings".
  if [ "$RC" -ne 0 ] && [ "$RC" -ne 1 ]; then
    echo "FAIL: gitleaks failed (exit $RC)."
    return 1
  fi
  if [ ! -f "$REPORT" ]; then
    echo "FAIL: report not created — scan not confirmed."
    return 1
  fi
  COUNT=$(grep -o '"RuleID"' "$REPORT" | wc -l | tr -d ' ')
  echo "Gitleaks: $COUNT findings"
  if [ "$RC" -eq 1 ] || [ "$COUNT" -ne 0 ]; then
    echo "FAIL: secrets detected — see report $REPORT (values redacted)."
    return 1
  fi
  echo "secret scan passed"
  return 0
}

case "$MODE" in
  canary) same_version && canary ;;
  repo)   same_version && repo ;;
  all)    same_version && canary && repo ;;
  *)      echo "usage: secret_scan.sh [canary|repo|all]"; exit 2 ;;
esac
