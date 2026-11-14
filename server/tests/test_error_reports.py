"""Server errors are reported to GlitchTip Apertono — without anything identifying the user or song (P3.5, Р-A11, Р-A22).

`GLITCHTIP_DSN` empty — no reports sent at all. Set — exception is sent, but the
report contains no query text, IP, key, token from path, or file
name (the file name identifies the song). Therefore the exception message is also
omitted — just like in the log, where only the error class is written.
"""

from __future__ import annotations

import gzip
import os
import threading
import time
import zlib
from collections.abc import Iterator
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest
from fastapi.testclient import TestClient

from app.main import create_app

PROBE = "zqxwvprobe"
CLIENT_IP = "203.0.113.77"


class _Collector(BaseHTTPRequestHandler):
    bodies: list[bytes] = []

    def do_POST(self) -> None:  # noqa: N802
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        encoding = self.headers.get("Content-Encoding", "")
        if encoding == "gzip":
            raw = gzip.decompress(raw)
        elif encoding == "deflate":
            raw = zlib.decompress(raw)
        elif encoding == "br":
            import brotli

            raw = brotli.decompress(raw)
        type(self).bodies.append(raw)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *args: object) -> None:
        return


@pytest.fixture
def collector() -> Iterator[tuple[str, list[bytes]]]:
    _Collector.bodies = []
    server = ThreadingHTTPServer(("127.0.0.1", 0), _Collector)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://{'a' * 32}@127.0.0.1:{server.server_port}/3", _Collector.bodies
    finally:
        server.shutdown()


def _boom(app: object) -> TestClient:
    async def fail(token: str) -> None:
        try:
            raise RuntimeError(f"query {PROBE}")
        except RuntimeError as exc:
            raise FileNotFoundError(2, "No such file", f"/cache/{PROBE} - Song.mp3") from exc

    app.add_api_route("/v1/boom/{token}", fail)  # type: ignore[attr-defined]
    return TestClient(app, raise_server_exceptions=False)  # type: ignore[arg-type]


def _hit(client: TestClient) -> None:
    response = client.get(
        f"/v1/boom/{PROBE}?q={PROBE}",
        headers={"x-apertonodo-key": os.environ["MUSIC_API_KEY"], "x-forwarded-for": CLIENT_IP},
    )
    assert response.status_code == 500


def _wait(bodies: list[bytes], seconds: float) -> None:
    deadline = time.monotonic() + seconds
    while not bodies and time.monotonic() < deadline:
        time.sleep(0.05)


def test_no_dsn_sends_nothing(monkeypatch: pytest.MonkeyPatch, collector: tuple[str, list[bytes]]) -> None:
    _, bodies = collector
    monkeypatch.delenv("GLITCHTIP_DSN", raising=False)
    _hit(_boom(create_app()))
    _wait(bodies, 1.5)
    assert bodies == []


def test_error_reaches_glitchtip_without_private_data(
    monkeypatch: pytest.MonkeyPatch, collector: tuple[str, list[bytes]]
) -> None:
    import sentry_sdk

    dsn, bodies = collector
    monkeypatch.setenv("GLITCHTIP_DSN", dsn)
    try:
        _hit(_boom(create_app()))
        sentry_sdk.flush(timeout=5)
        _wait(bodies, 5)
    finally:
        sentry_sdk.get_client().close()
        sentry_sdk.init()
    sent = b"\n".join(bodies).decode("utf-8", "replace")
    # The report was indeed sent and identifies the error: class and code location.
    assert "FileNotFoundError" in sent, "exception did not reach GlitchTip"
    assert "fail" in sent
    for secret in (PROBE, CLIENT_IP, os.environ["MUSIC_API_KEY"], "Song.mp3"):
        assert secret not in sent, f"leaked into report: {secret}"
