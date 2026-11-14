"""Catalog can access the Internet through a proxy.

Why this is needed: musicbrainz.org cannot be reached directly from production server — TLS
to this SNI is blocked (the same connection without SNI passes, neighboring sites with SNI
pass). Direct request gives `ConnectTimeout`, via proxy the same request gives 200 in 1.2 s.
Therefore the egress address is set by the `MUSICBRAINZ_PROXY` environment variable,
rather than hardcoded.

What is tested is not "the field is set", but that the request actually egresses via proxy:
the destination address in the test does not exist, and a response can only come from
the fake proxy. Without a proxy the same call fails — this is the red half of the test.
"""

from __future__ import annotations

import asyncio
import json
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import httpx
import pytest

from app.musicbrainz import ThrottledHttpJson, catalog_from_env, http_from_env

# Address that does not exist: any response to it proves it was not reached directly.
UNREACHABLE = "http://musicbrainz.invalid/ws/2/recording"


class _ProxyHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802 — name defined by base class
        self.server.seen.append(self.path)  # type: ignore[attr-defined]
        body = json.dumps({"recordings": [], "proxied": True}).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args: object) -> None:
        return


@pytest.fixture
def fake_proxy():
    server = HTTPServer(("127.0.0.1", 0), _ProxyHandler)
    server.seen = []  # type: ignore[attr-defined]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()


def test_request_goes_through_the_proxy(fake_proxy: HTTPServer) -> None:
    host, port = fake_proxy.server_address[0], fake_proxy.server_address[1]
    http = ThrottledHttpJson(proxy=f"http://{host}:{port}", min_interval_s=0.0)

    payload = asyncio.run(http.get_json(UNREACHABLE, {"query": "duality", "fmt": "json"}))

    assert payload["proxied"] is True
    assert fake_proxy.seen, "proxy saw no requests"
    assert fake_proxy.seen[0].startswith(UNREACHABLE), fake_proxy.seen


def test_without_proxy_the_same_request_fails() -> None:
    """Red half: without a proxy this address cannot be reached."""
    http = ThrottledHttpJson(min_interval_s=0.0)

    with pytest.raises(httpx.HTTPError):
        asyncio.run(http.get_json(UNREACHABLE, {"query": "duality", "fmt": "json"}))


def test_proxy_comes_from_the_environment() -> None:
    assert http_from_env({}).proxy is None
    assert http_from_env({"MUSICBRAINZ_PROXY": "  "}).proxy is None
    assert http_from_env({"MUSICBRAINZ_PROXY": "http://10.0.0.1:8888"}).proxy == "http://10.0.0.1:8888"


def test_catalog_still_turns_on_only_by_its_own_switch() -> None:
    """Proxy by itself does not enable the catalog."""
    assert catalog_from_env({"MUSICBRAINZ_PROXY": "http://10.0.0.1:8888"}) is None
