#!/usr/bin/env bash
# Run extension tests in dedicated virtual environment (FT-590).
#
#   bash scripts/extension_tests.sh folder
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="${1:-}"

if [ -z "$NAME" ]; then
  echo "Usage: $0 <extension-name>" >&2
  exit 1
fi

EXT_DIR="$ROOT/extensions/$NAME"
if [ ! -d "$EXT_DIR" ]; then
  echo "Extension $NAME not found in $EXT_DIR" >&2
  exit 1
fi

# An extension may need something prepared before its tests (a real service, say).
if [ -f "$EXT_DIR/pre_test.sh" ]; then
  bash "$EXT_DIR/pre_test.sh"
fi

VENV="$EXT_DIR/.venv"
if [ ! -d "$VENV" ]; then
  python3 -m venv "$VENV"
fi

cd "$EXT_DIR"

"$VENV/bin/pip" install -q -e ".[dev]"

shift
exec "$VENV/bin/pytest" -q "$@"
