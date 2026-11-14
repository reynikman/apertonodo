from __future__ import annotations

import asyncio
import json
import os
import secrets
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SERVER = ROOT / "server"
SECRET = "secret-query-xyz"


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def test_uvicorn_access_log_omits_query_and_client_ip(postgres_url: str) -> None:
    import asyncpg

    from app.migrate import apply
    from app.users import create_user

    username = f"privacy_{secrets.token_hex(12)}"
    password = secrets.token_urlsafe(32)

    async def prepare() -> None:
        await apply(postgres_url)
        conn = await asyncpg.connect(postgres_url)
        try:
            await create_user(conn, username, password)
        finally:
            await conn.close()

    asyncio.run(prepare())
    port = _free_port()
    env = os.environ.copy()
    env["PORT"] = str(port)
    env["BIND_HOST"] = "127.0.0.1"
    env["DATABASE_URL"] = postgres_url
    proc = subprocess.Popen(
        [sys.executable, "-m", "app.serve"],
        cwd=SERVER,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    log = ""
    try:
        deadline = time.monotonic() + 8
        last_error = None
        while time.monotonic() < deadline:
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{port}/v1/health", timeout=0.5)
                break
            except (urllib.error.URLError, TimeoutError, ConnectionError) as exc:
                last_error = exc
                time.sleep(0.1)
        else:
            raise AssertionError(f"server did not start: {last_error}")
        login = urllib.request.urlopen(
            urllib.request.Request(
                f"http://127.0.0.1:{port}/v1/auth/login",
                data=json.dumps({"username": username, "password": password, "device_name": "privacy-test"}).encode(),
                headers={"x-apertonodo-key": env["MUSIC_API_KEY"], "Content-Type": "application/json"},
            ),
            timeout=2,
        )
        assert login.status == 200
        token = json.load(login)["token"]
        # Both real handlers must run; a guard-only 401 does not test their logs.
        for path in (f"/v1/search?q={SECRET}", f"/v1/suggest?q={SECRET}"):
            response = urllib.request.urlopen(
                urllib.request.Request(
                    f"http://127.0.0.1:{port}{path}",
                    headers={
                        "x-apertonodo-key": env["MUSIC_API_KEY"],
                        "Authorization": f"Bearer {token}",
                    },
                ),
                timeout=2,
            )
            assert response.status == 200
        time.sleep(0.3)
        proc.terminate()
        log, _ = proc.communicate(timeout=5)
    finally:
        if proc.poll() is None:
            proc.kill()
            log += proc.communicate(timeout=5)[0]
    assert SECRET not in log
    assert token not in log
    assert f"q={SECRET}" not in log
    assert "/v1/search?" not in log
    assert "/v1/suggest?" not in log
    for endpoint in ("/v1/search", "/v1/suggest"):
        access_lines = [line for line in log.splitlines() if f"GET {endpoint}" in line]
        assert access_lines, log
        for line in access_lines:
            assert SECRET not in line
            assert "?" not in line.split(f"GET {endpoint}", 1)[-1].split("HTTP", 1)[0]
            assert not line.lstrip()[:1].isdigit()


def test_access_log_hides_the_stream_token() -> None:
    """Token is a pass to audio for one hour; it does not go into access log or the log collector.

    September 18 audit: `GET /v1/stream/<token>` line went into log in full.
    """
    import logging

    from app.access_log import SafeAccessFormatter

    formatter = SafeAccessFormatter('%(client_addr)s - "%(request_line)s"', use_colors=False)
    token = "zYF1PIT8947LMFjOSlcnctEeCxdEUIJn"

    def line(method: str, path: str) -> str:
        record = logging.LogRecord(
            "uvicorn.access", logging.INFO, __file__, 1, '%s - "%s %s HTTP/%s" %d',
            ("203.0.113.7:5555", method, path, "1.1", 200), None,
        )
        return formatter.format(record)

    assert line("GET", f"/v1/stream/{token}?t=1") == '- - "GET /v1/stream/… HTTP/1.1"'
    assert line("HEAD", f"/v1/stream/{token}") == '- - "HEAD /v1/stream/… HTTP/1.1"'
    assert line("GET", f"/v1/playback/{token}/status") == (
        '- - "GET /v1/playback/…/status HTTP/1.1"'
    )
    # Positive control: paths without token remain as is.
    assert line("POST", "/v1/playback") == '- - "POST /v1/playback HTTP/1.1"'
    assert line("GET", "/v1/search?q=secret") == '- - "GET /v1/search HTTP/1.1"'
    # Suggestion is typed letter by letter, meaning its line would hit the log more often
    # than all other requests combined.
    assert line("GET", "/v1/suggest?q=secret") == '- - "GET /v1/suggest HTTP/1.1"'
    # Catalog: artist name goes into query string, path contains only UUID.
    assert line("GET", "/v1/artist?name=Secret%20Band") == '- - "GET /v1/artist HTTP/1.1"'
    assert line("GET", "/v1/artists?letter=S&genre=") == '- - "GET /v1/artists HTTP/1.1"'


def test_search_and_suggest_do_not_log_the_query(caplog) -> None:
    """Application logs do not print query either — neither in search nor suggestion.

    Access log strips query string, but `logger.info` in a handler could
    print anything. This specifically checks the handler log.
    """
    import logging

    from fastapi.testclient import TestClient

    from app.main import create_app

    with TestClient(create_app(database_url=None, catalog=[], catalog_port=None)) as http:
        with caplog.at_level(logging.DEBUG):
            http.get("/v1/search", params={"q": SECRET})
            http.get("/v1/suggest", params={"q": SECRET})
    lines = " ".join(
        record.getMessage() for record in caplog.records if record.name.startswith("apertonodo")
    )
    # Positive control: log lines about the requests themselves are present.
    assert "search" in lines and "suggest" in lines
    assert SECRET not in lines


def test_lastfm_key_never_reaches_the_log(caplog) -> None:
    """Last.fm key goes in URL (`api_key=`), and no log line prints the URL.

    Two vulnerabilities this catches: httpx at INFO level logs the full request
    line, and exception messages contain URL. Log is set to DEBUG here
    for everything — just like anyone debugging will turn it on.
    """
    import logging

    import httpx
    import pytest

    from app.lastfm import LastFm, LastFmStop

    key = "lastfm-secret-" + "9" * 18
    caplog.set_level(logging.DEBUG)

    def answer(request: httpx.Request) -> httpx.Response:
        if request.url.params.get("artist") == "down":
            raise httpx.ConnectError(f"cannot reach {request.url}", request=request)
        return httpx.Response(200, json={"artist": {"name": "x", "bio": {"summary": ""}}})

    robot = LastFm(key, "postgresql://unused", pause_s=0)
    with httpx.Client(transport=httpx.MockTransport(answer)) as client:
        assert robot.ask(client, "artist.getinfo", "up") is not None
        with pytest.raises(LastFmStop) as stopped:
            robot.ask(client, "artist.getinfo", "down")
    logging.getLogger("apertonodo").info("lastfm: stopped after 0 artists: %s", stopped.value)

    # Positive control: requests occurred, line about stopping is present in the log.
    assert "stopped after 0 artists: ConnectError" in caplog.text
    assert key not in caplog.text and "api_key" not in caplog.text
    assert key not in str(stopped.value) and stopped.value.__cause__ is None
