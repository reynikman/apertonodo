#!/bin/sh
set -eu

FLOWTUNE_DB_WAIT_S="${FLOWTUNE_DB_WAIT_S:-60}"
deadline=$(( $(date +%s) + FLOWTUNE_DB_WAIT_S ))

while true; do
  now=$(date +%s)
  remaining=$(( deadline - now ))
  if [ "$remaining" -le 0 ]; then
    echo "database did not become ready within deadline" >&2
    exit 1
  fi
  timeout=2
  if [ "$timeout" -gt "$remaining" ]; then
    timeout="$remaining"
  fi
  if python -c "import asyncio, asyncpg, os, sys; asyncio.run(asyncpg.connect(os.environ['DATABASE_URL'], timeout=float(sys.argv[1])))" "$timeout" >/dev/null 2>&1; then
    break
  fi
  now=$(date +%s)
  if [ "$now" -ge "$deadline" ]; then
    echo "database did not become ready within deadline" >&2
    exit 1
  fi
  sleep 1
done

python -m app.migrate
exec python -m app.watchdog
