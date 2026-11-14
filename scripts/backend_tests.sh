#!/usr/bin/env bash
# Server tests: migrations, pytest, and check that test suite has not shrunk.
#
# This file is executed by both platforms: local check (scripts/backend_ci.sh)
# and GitLab (job backend-tests). Previously steps were written twice, and
# local "green" could mean something different from green in CI.
#
# PYTHON   — interpreter with installed dependencies.
#            Locally this is server/.venv/bin/python, in CI — system python.
# MIN_TESTS — lower bound on suite size.
#
# This also includes public contour guard: verified against live running server,
# not just unit tests, using one-time key — no secret required.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="${PYTHON:-python}"
MIN_TESTS="${MIN_TESTS:-223}"

# The mobile DSN must not be inherited from deployment variables. Test
# collectors set their own loopback DSN; server/tests/ stays unchanged.
export GLITCHTIP_MOBILE_DSN=''

cd "$ROOT/server"
"$PYTHON" -m app.migrate
"$PYTHON" -m pytest -q --tb=short --junitxml=report.xml

# Green run of a stripped suite looks identical to green run of a
# complete one. Lower bound prevents suite from silently shrinking, and skipping is prohibited
# separately in tests/conftest.py.
# The public slice has no plan/: tests of the files it does not ship skip by themselves (FT-890),
# and each skip names the missing file. Everywhere else a skip stays a failure.
SLICE=""
[ -d "$ROOT/plan" ] || SLICE=1
MIN_TESTS="$MIN_TESTS" SLICE="$SLICE" "$PYTHON" - <<'PY'
import os
import xml.etree.ElementTree as ET

root = ET.parse("report.xml").getroot()
suite = root if root.tag == "testsuite" else root[0]
total = int(suite.attrib["tests"])
skipped = int(suite.attrib.get("skipped", 0))
minimum = int(os.environ["MIN_TESTS"])
print(f"tests={total} skipped={skipped}")
if skipped and os.environ["SLICE"]:
    print(f"public slice: {skipped} skipped tests (files that are not in the slice)")
elif skipped:
    raise SystemExit(f"FAIL: {skipped} skipped tests — skipping is forbidden")
if total < minimum:
    raise SystemExit(
        f"FAIL: collected {total} tests, expected at least {minimum} — test suite is truncated"
    )
PY

# Public contour guard on a real server: without key neither catalog,
# nor token, nor audio bytes are served. Same file verifies deployed endpoint —
# scripts/public_guard_check.sh.
# Public slice (FT-890): the live-endpoint half of the guard is not shipped — skipped by its absence. In the repository (plan/
# is there) it always runs, so a missing tone breaks the run instead of switching the guard off.
if [ -d "$ROOT/plan" ] || { [ -f "$ROOT/contracts/fixtures/audio/tone-440hz-4s.mp3" ] && [ -f "$ROOT/scripts/public_guard_check.sh" ]; }; then
  PYTHON="$PYTHON" bash "$ROOT/scripts/public_guard_local.sh"
else
  echo "public contour guard on a live server: skipped: not in public slice (scripts/public_guard_check.sh)"
fi

echo "backend verification passed"
