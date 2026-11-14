from __future__ import annotations

import json
import os

from app.env_names import env
import signal
import subprocess
import sys
import time
import urllib.request

FAILURES = 3
GRACE_S = 120
INTERVAL_S = 10
PROBE_TIMEOUT_S = 2

_child: subprocess.Popen[bytes] | None = None


def _log(message: str) -> None:
    # PIDs, counts and exit codes only: no URLs, no file names (AGENTS.md).
    print(f"watchdog: {message}", file=sys.stderr, flush=True)


def _handle_signal(signum: int, _frame: object) -> None:
    global _child
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    if _child is not None and _child.poll() is None:
        try:
            _child.terminate()
            try:
                # The container stop sends SIGKILL 10 s after SIGTERM: leave it room.
                _child.wait(timeout=8)
            except subprocess.TimeoutExpired:
                _child.kill()
                _child.wait(timeout=2)
        except OSError:
            pass
    sys.exit(0)


def _start() -> tuple[subprocess.Popen[bytes], float]:
    proc = subprocess.Popen([sys.executable, "-m", "app.serve"])
    return proc, time.monotonic()


def _healthy(url: str, timeout: float) -> bool:
    try:
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=timeout) as response:
            if response.status != 200:
                return False
            payload = json.loads(response.read().decode("utf-8"))
            return payload == {"status": "ok"}
    except Exception:
        return False


def main() -> None:
    global _child
    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    interval = float(env("WATCHDOG_INTERVAL_S", str(INTERVAL_S)))
    limit = int(env("WATCHDOG_FAILURES", str(FAILURES)))
    grace = float(env("WATCHDOG_GRACE_S", str(GRACE_S)))
    timeout = float(env("WATCHDOG_PROBE_TIMEOUT_S", str(PROBE_TIMEOUT_S)))

    port = os.environ.get("PORT", "8088")
    url = f"http://127.0.0.1:{port}/v1/health"

    _child, started = _start()
    failed = 0

    while True:
        code = _child.poll()
        if code is not None:
            # A crash is the restart policy's job: exiting keeps it visible as a container restart, with backoff.
            _log(f"api pid {_child.pid} exited with code {code}")
            sys.exit(code if code > 0 else 1)

        if time.monotonic() - started < grace:
            time.sleep(interval)
            continue

        if _healthy(url, timeout):
            failed = 0
        else:
            failed += 1
            if failed >= limit:
                _log(f"api pid {_child.pid} failed {failed} health probes in a row, restarting it")
                try:
                    _child.kill()
                    _child.wait()
                except OSError:
                    pass
                _child, started = _start()
                failed = 0

        time.sleep(interval)


if __name__ == "__main__":
    main()
