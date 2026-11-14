#!/usr/bin/env bash
# Server static analysis without running code: ruff (typos, dead names, syntax)
# and mypy (types). The same file is run by local check (scripts/check.sh)
# and the static-analysis job in GitLab.
#
#   bash scripts/static_analysis.sh
#
# Why this on top of 316 tests. Tests execute code branches that someone
# remembered to call. A typo in a rare `except` branch survives until the first
# real outage — that is, until the day it is needed working.
#
# Fail-closed, rules learned from Lomonosov Base failures:
#   1. Ruff and mypy exit 1 on findings and 2 on their own failure. "Non-zero"
#      is not enough here: 2 means broken tool, not dirty code.
#   2. Canary: both must catch the planted defect. Without it, "0 findings"
#      is indistinguishable from "tool failed to run".
#   3. Reports are always written, even when gate is red: otherwise there is nothing
#      to inspect on failure.
#
# Versions are pinned: a blocking gate must not turn red because a new
# linter release came out with a new rule. Updates happen in a separate MR.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

RUFF_VERSION="0.16.3"
MYPY_VERSION="2.3.0"
VENV="$ROOT/.tools/lint-venv"
RUFF_REPORT="$ROOT/ruff-report.txt"
MYPY_REPORT="$ROOT/mypy-report.txt"

echo "=== Server code analysis: ruff + mypy ==="

rm -f "$RUFF_REPORT" "$MYPY_REPORT"

# Environment lives in .tools and survives runs; rebuilt if
# tool version diverges from pinned version here or if server
# dependencies change: without the latter, new library (sentry-sdk, FT-444)
# did not reach the environment, and mypy turned red on every branch.
stamp="$VENV/.versions"
want="ruff==${RUFF_VERSION} mypy==${MYPY_VERSION} deps=$(cat server/constraints.txt server/pyproject.toml | cksum)"
if [ ! -x "$VENV/bin/python" ] || [ "$(cat "$stamp" 2>/dev/null)" != "$want" ]; then
  rm -rf "$VENV"
  python3 -m venv "$VENV" || { echo "FAIL: failed to create venv at $VENV"; exit 1; }
  # Explicit check: in a third-party pipeline venv once ended up without bin/, and the error
  # surfaced down the script in an unreadable form.
  test -x "$VENV/bin/python" || { echo "FAIL: venv without bin/python."; exit 1; }
  "$VENV/bin/pip" install -q --upgrade pip \
    || { echo "FAIL: pip failed to upgrade."; exit 1; }
  # Server dependencies are installed alongside linters intentionally: mypy must
  # see the same types as code under test. Installing only linters means
  # getting a green report with a broken import graph.
  "$VENV/bin/pip" install -q -c server/constraints.txt -e "./server[dev]" \
    "ruff==${RUFF_VERSION}" "mypy==${MYPY_VERSION}" \
    || { echo "FAIL: linters or server dependencies failed to install."; exit 1; }
  printf '%s' "$want" > "$stamp"
fi
echo "ruff: $("$VENV/bin/ruff" --version) | mypy: $("$VENV/bin/mypy" --version)"

# --- canary ---------------------------------------------------------------
# Typo (name that does not exist) must turn ruff red, returning a string
# instead of an int — mypy. Exit codes are checked exactly, not "non-zero".
CANARY="$(mktemp -d)"
printf 'def f() -> int:\n    return retrun_value\n' > "$CANARY/canary_typo.py"
printf 'def g() -> int:\n    return "not a number"\n' > "$CANARY/canary_types.py"

RUFF_CANARY=0
"$VENV/bin/ruff" check --isolated --select F "$CANARY/canary_typo.py" >/dev/null 2>&1 || RUFF_CANARY=$?
MYPY_CANARY=0
"$VENV/bin/mypy" --config-file= --cache-dir="$CANARY/.mypy_cache" \
  "$CANARY/canary_types.py" >/dev/null 2>&1 || MYPY_CANARY=$?
rm -rf "$CANARY"

if [ "$RUFF_CANARY" -ne 1 ]; then
  echo "FAIL: canary — ruff returned ${RUFF_CANARY}, expected 1."
  echo "      It did not detect seeded typo or crashed."
  exit 1
fi
if [ "$MYPY_CANARY" -ne 1 ]; then
  echo "FAIL: canary — mypy returned ${MYPY_CANARY}, expected 1."
  echo "      It did not detect returning str instead of int or crashed."
  exit 1
fi
echo "Canary: both tools catch seeded defects."

# --- analysis -------------------------------------------------------------
RUFF_RC=0
MYPY_RC=0
(cd server && "$VENV/bin/ruff" check --no-cache .) > "$RUFF_REPORT" 2>&1 || RUFF_RC=$?
(cd server && "$VENV/bin/mypy") > "$MYPY_REPORT" 2>&1 || MYPY_RC=$?

echo "ruff: code ${RUFF_RC} | mypy: code ${MYPY_RC}"
if [ "$RUFF_RC" -gt 1 ] || [ "$MYPY_RC" -gt 1 ]; then
  echo "--- ruff ---"; tail -n 20 "$RUFF_REPORT"
  echo "--- mypy ---"; tail -n 20 "$MYPY_REPORT"
  echo "FAIL: tool exited with its own error, not findings."
  exit 1
fi
if [ "$RUFF_RC" -ne 0 ] || [ "$MYPY_RC" -ne 0 ]; then
  echo "--- ruff ---"; tail -n 40 "$RUFF_REPORT"
  echo "--- mypy ---"; tail -n 40 "$MYPY_REPORT"
  echo "FAIL: analysis found issues (full reports — ruff-report.txt and mypy-report.txt)."
  exit 1
fi

echo "Code analysis: clean."
