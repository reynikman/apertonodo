"""Error report from the app goes via own server to GlitchTip Apertono (P3.5, Р-A11, Р-A36).

GlitchTip lives only in home network. The app sends report to
`POST /v1/reports` of its server, behind the same lock as the rest of `/v1/*`;
the server forwards it to project `apertono-mobile` (`GLITCHTIP_MOBILE_DSN`).

Report has only allowed fields: error kind, screen, app and
Android version, code location. No free text at all: extra field or non-matching
value yields 422, and nothing leaves outside. Thus query text, song
or file name will not get into the report even on app error.
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

GOOD = {
    "kind": "play.no_source",
    "screen": "search",
    "app_version": "0.9.1+42",
    "os": "Android 14",
    "frames": [
        {
            "function": "_SearchState._run.<anonymous closure>",
            "file": "package:flowtune/screens/search.dart",
            "line": 118,
        },
        {
            "function": "PlayerModel.select",
            "file": "package:flowtune/player.dart",
            "line": 138,
        },
    ],
}


class _Collector(BaseHTTPRequestHandler):
    seen: list[tuple[str, bytes]] = []

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
        type(self).seen.append((self.path, raw))
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *args: object) -> None:
        return


@pytest.fixture
def glitchtip(monkeypatch: pytest.MonkeyPatch) -> Iterator[list[tuple[str, bytes]]]:
    """Error server is project 3, app is project 4 of the same GlitchTip."""
    _Collector.seen = []
    server = ThreadingHTTPServer(("127.0.0.1", 0), _Collector)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = f"{'a' * 32}@127.0.0.1:{server.server_port}"
    monkeypatch.setenv("GLITCHTIP_DSN", f"http://{base}/3")
    monkeypatch.setenv("GLITCHTIP_MOBILE_DSN", f"http://{base}/4")
    try:
        yield _Collector.seen
    finally:
        import sentry_sdk

        sentry_sdk.get_client().close()
        sentry_sdk.init()
        server.shutdown()


def _client() -> TestClient:
    return TestClient(create_app(), raise_server_exceptions=False)


def _post(client: TestClient, body: object, *, key: bool = True):  # type: ignore[no-untyped-def]
    headers = {"x-forwarded-for": CLIENT_IP}
    if key:
        headers["x-apertonodo-key"] = os.environ["MUSIC_API_KEY"]
    return client.post("/v1/reports", json=body, headers=headers)


def _wait(seen: list[tuple[str, bytes]], seconds: float) -> None:
    deadline = time.monotonic() + seconds
    while not seen and time.monotonic() < deadline:
        time.sleep(0.05)


def test_report_reaches_mobile_project_without_private_data(
    glitchtip: list[tuple[str, bytes]],
) -> None:
    with _client() as client:
        response = _post(client, GOOD)
    assert response.status_code == 202, response.text
    _wait(glitchtip, 5)
    assert glitchtip, "report did not reach GlitchTip"
    paths = {path for path, _ in glitchtip}
    assert all("/api/4/" in path for path in paths), (
        f"app report went to wrong project: {paths}"
    )
    sent = b"\n".join(body for _, body in glitchtip).decode("utf-8", "replace")
    # Report names the error and code location — otherwise it is useless.
    for needed in (
        "play.no_source",
        "search",
        "0.9.1+42",
        "Android 14",
        "PlayerModel.select",
        "player.dart",
    ):
        assert needed in sent, f"missing from report: {needed}"
    for secret in (CLIENT_IP, os.environ["MUSIC_API_KEY"]):
        assert secret not in sent, f"leaked into report: {secret}"


def test_report_needs_the_lock(glitchtip: list[tuple[str, bytes]]) -> None:
    with _client() as client:
        response = _post(client, GOOD, key=False)
    assert response.status_code == 401
    _wait(glitchtip, 1)
    assert glitchtip == []


@pytest.mark.parametrize(
    "broken",
    [
        {**GOOD, "message": f"query {PROBE}"},
        {**GOOD, "kind": f"поиск {PROBE}"},
        {**GOOD, "screen": f"/search?q={PROBE}"},
        {**GOOD, "app_version": f"1.0 {PROBE} Song.mp3"},
        {
            **GOOD,
            "frames": [
                {"function": "run", "file": f"/cache/{PROBE} - Song.mp3", "line": 1}
            ],
        },
        {
            **GOOD,
            "frames": [
                {
                    "function": "run",
                    "file": "package:flowtune/a.dart",
                    "line": 1,
                    "vars": PROBE,
                }
            ],
        },
        {**GOOD, "frames": [GOOD["frames"][0]] * 101},
        {k: v for k, v in GOOD.items() if k != "kind"},
    ],
    ids=[
        "extra-field",
        "kind-text",
        "screen-url",
        "version-text",
        "frame-file",
        "frame-extra",
        "too-many-frames",
        "no-kind",
    ],
)
def test_free_text_is_refused_and_nothing_leaves(
    glitchtip: list[tuple[str, bytes]], broken: dict[str, object]
) -> None:
    with _client() as client:
        response = _post(client, broken)
    assert response.status_code == 422, response.text
    assert PROBE not in response.text
    _wait(glitchtip, 1)
    assert glitchtip == [], "rejected report was sent anyway"


def test_no_mobile_dsn_says_reports_are_off(
    monkeypatch: pytest.MonkeyPatch, glitchtip: list[tuple[str, bytes]]
) -> None:
    monkeypatch.delenv("GLITCHTIP_MOBILE_DSN")
    with _client() as client:
        response = _post(client, GOOD)
    # App should honestly say "reports off", not "sent".
    assert response.status_code == 503
    assert response.json() == {"status": "reports_off"}
    _wait(glitchtip, 1)
    assert glitchtip == []
