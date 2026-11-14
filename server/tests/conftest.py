from __future__ import annotations

import ipaddress
import logging
import os
import socket
import time
import uuid
from collections.abc import Iterator
from typing import Any
from urllib.parse import urlparse

import pytest

# Importing `app.main` initializes production application (`app.main:app`), which
# is intentionally not created without key — see app/guard.py. Key is set here, before
# importing test modules. The tests themselves create application via `create_app`
# and only get guard where they explicitly test the guard.
os.environ.setdefault("MUSIC_API_KEY", "pytest-key-" + "0" * 24)

# Live sources are forcefully disabled in test suite.
#
# MUSICBRAINZ_ENABLED and other live source variables are configured as project
# variables in GitLab — needed for deployment. But project variables enter every
# job, and tests picked them up silently: `create_app` without explicit catalog
# builds catalog from environment. Test suite hit the network: MusicBrainz allows one
# request per second. Locally these variables are absent, so the same 126 tests
# took 57 seconds, while in CI the job hung for twenty minutes and had to be
# cancelled. Tests must be hermetic — sources only via fixture.
# Guarded by: tests/test_hermetic_sources.py.
#
# Stripping known names is not enough: a provider variable that is not on the
# list must still be unable to open an external socket. Loopback stays
# allowed. DATABASE_URL's host
# is noted only after the contour check below. Live smoke does not load this.
_FIXTURE_HOSTS: set[str] = set()
_ALLOWED_IPS: set[str] = set()

# Catalog proxies and timeouts as well: environment timeouts change what budget and catalog tests verify. And `IMAGE_DIR`:
# with it the suite would access Cover Art Archive and Wikimedia, and write image files
# to production catalog on disk.
for _live_source in (
    "GLITCHTIP_DSN",
    "MUSICBRAINZ_ENABLED",
    "MUSICBRAINZ_CONTACT",
    "MUSICBRAINZ_PROXY",
    "EXTENSIONS",
    "BOOK_EXTENSIONS",
    "CATALOG_TIMEOUT_S",
    "CATALOG_COOLDOWN_S",
    "PLAYBACK_BUDGET_S",
    "LASTFM_API_KEY",
    "LASTFM_PROXY",
    "LASTFM_API_SECRET",
    "PLAY_SENDER",
    "IMAGE_DIR",
    "MBCOPY_ENABLED",
    "NEWS_PROXY",
    "LYRICS_URL",
    "PODCASTS_LIVE",
    # httpx trusts these and would dial an external proxy with no provider var.
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "ALL_PROXY",
    "http_proxy",
    "https_proxy",
    "all_proxy",
    ):
    os.environ.pop(_live_source, None)

# Disk free space threshold (Phase E) inspects the machine's real disk:
# on a Mac with 20 GB free, cleanup would evict everything, in CI — nothing.
# Tests that need it pass it to `create_app` themselves.
os.environ["STORAGE_MIN_FREE_GB"] = "0"

# News collection thread (FT-573) accesses network every 30 min — omitted in tests;
# collection is called manually via `collect_once` with fake fetch.
os.environ["NEWS_COLLECT"] = "0"


class ExternalSocketBlocked(OSError):
    """A test tried to open a socket outside the fixture allowlist."""


def _host_text(host: object) -> str:
    if isinstance(host, bytes):
        return host.decode("ascii", "replace")
    return str(host)


def _is_local(host: str) -> bool:
    if host == "localhost":
        return True
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return False
    return ip.is_loopback or ip.is_unspecified


def _confirmed_test_host(host: str) -> bool:
    """Loopback, or GitLab's postgres service alias while CI is set."""
    if _is_local(host):
        return True
    return bool(os.environ.get("CI")) and host == "postgres"


def _note_verified_database_host() -> None:
    host = urlparse(os.environ.get("DATABASE_URL", "")).hostname
    if host and _confirmed_test_host(host):
        _FIXTURE_HOSTS.add(host)


_note_verified_database_host()


def host_allowed(host: str) -> bool:
    return _is_local(host) or host in _FIXTURE_HOSTS or host in _ALLOWED_IPS


def remember_fixture_host(host: str) -> None:
    """Allow a fixture hostname. Does not resolve it, so it sends nothing."""
    if host:
        _FIXTURE_HOSTS.add(host)


def _reject(address: object) -> None:
    if isinstance(address, (str, bytes)):
        return
    host: object = address[0] if isinstance(address, tuple) and address else address
    if host in (None, "") or host_allowed(_host_text(host)):
        return
    raise ExternalSocketBlocked(f"external socket blocked: {host}")


def _remember_resolved(infos: list) -> None:
    for info in infos:
        sockaddr = info[4]
        if sockaddr and sockaddr[0]:
            _ALLOWED_IPS.add(sockaddr[0])


_real_getaddrinfo = socket.getaddrinfo
_real_create_connection = socket.create_connection
_real_socket = socket.socket


def _guarded_getaddrinfo(host, port, *args, **kwargs):
    if host not in (None, "") and not host_allowed(_host_text(host)):
        raise ExternalSocketBlocked(f"external socket blocked: {host}")
    infos = _real_getaddrinfo(host, port, *args, **kwargs)
    _remember_resolved(infos)
    return infos


def _guarded_create_connection(address, *args, **kwargs):
    _reject(address)
    return _real_create_connection(address, *args, **kwargs)


class _GuardedSocket(_real_socket):
    def connect(self, address):  # type: ignore[no-untyped-def]
        _reject(address)
        return super().connect(address)

    def connect_ex(self, address):  # type: ignore[no-untyped-def]
        _reject(address)
        return super().connect_ex(address)


def install_socket_guard() -> None:
    # ponytail: Python sockets only; a C extension that dials out would need its own flag.
    socket.getaddrinfo = _guarded_getaddrinfo
    socket.create_connection = _guarded_create_connection
    socket.socket = _GuardedSocket  # type: ignore[misc]


install_socket_guard()


def pytest_configure(config: pytest.Config) -> None:
    config.addinivalue_line("markers", "real_auth: exercise the real user guard")


@pytest.fixture(scope="session")
def test_principal() -> dict[str, str | bool]:
    return {"id": str(uuid.uuid4()), "is_admin": False}


@pytest.fixture(autouse=True)
def server_trace(caplog: pytest.LogCaptureFixture) -> None:
    """Server trace (`playback N`, `stream N`) is at INFO level, while pytest without
    configuration only displays WARNING and above on failure. Download tests
    flicker under load, and without the trace the cause cannot be identified from job log
    (docs/troubleshooting.md #23, #28)."""
    caplog.set_level(logging.INFO, logger="apertonodo")


@pytest.fixture(autouse=True)
def library_test_user(
    request: pytest.FixtureRequest, monkeypatch: pytest.MonkeyPatch,
    test_principal: dict[str, str | bool],
) -> None:
    if request.node.get_closest_marker("real_auth"):
        return

    from app.guard import UserGuard

    async def with_test_user(self: UserGuard, scope: dict[str, Any], receive: Any, send: Any) -> None:
        path = str(scope.get("path", ""))
        if scope.get("type") in ("http", "websocket") and path.startswith("/v1/") and path not in self.OPEN_PATHS:
            scope.setdefault("state", {})["user"] = test_principal
        await self.app(scope, receive, send)

    monkeypatch.setattr(UserGuard, "__call__", with_test_user)


@pytest.fixture(autouse=True)
def images_settle() -> Iterator[None]:
    """Test image threads complete before database is handed to next test.

    Image queue and robot are daemon threads, and test did not wait for them. Under CI
    load, the previous test's robot would write "already searched for photo" to next test's database,
    causing it not to request photos at all (`test_catalog_log_has_no_names_or_titles`,
    FT-547: three red pipelines in one night on 04.10).
    """
    yield
    from fakes import SHELVES

    deadline = time.monotonic() + 30
    for shelf in SHELVES:
        if shelf.robot is not None:
            shelf.robot.join(max(0.0, deadline - time.monotonic()))
        while shelf.queue.unfinished_tasks and time.monotonic() < deadline:
            time.sleep(0.05)
    SHELVES.clear()


@pytest.fixture(autouse=True)
def extensions_reset() -> Iterator[None]:
    """Extension playability set by test (`fakes.seed_extension`) does not outlive it."""
    yield
    from app import catalog

    catalog.use_extensions(None)


@pytest.fixture(autouse=True)
def fresh_login_window(request: pytest.FixtureRequest) -> None:
    """Global login limit (20 per minute per server) is in database and shared across run.

    Test suite with all logins was right at the limit: subsequent test with login
    received 429 from its alphabetical neighbor. Each test with database starts with clean window.
    """
    url = os.environ.get("DATABASE_URL")
    if not url or "postgres_url" not in request.fixturenames:
        return
    import asyncio

    import asyncpg

    async def clear() -> None:
        conn = await asyncpg.connect(url)
        try:
            if await conn.fetchval("SELECT to_regclass('login_global_attempts')"):
                await conn.execute("DELETE FROM login_global_attempts")
        finally:
            await conn.close()

    asyncio.run(clear())


@pytest.fixture
def postgres_url() -> str:
    """Database URL or meaningful failure.

    Locally without database running, test is skipped — convenience. In CI,
    skipping is forbidden: this was how a "green run" ceased proving anything.
    `backend_ci.sh` always exports DATABASE_URL, so legitimate runs are not affected.
    """
    url = os.environ.get("DATABASE_URL")
    if url:
        return url
    if os.environ.get("CI") or os.environ.get("FLOWTUNE_REQUIRE_DB"):
        raise AssertionError("DATABASE_URL is not set, skipping database in CI is forbidden")
    pytest.skip("DATABASE_URL is not set")
