"""The test suite never accesses live sources, even when the environment enables them.

Why this is a dedicated test file and not just a line in conftest: a single line is easy
to lose during a subsequent edit, and the loss would be silent. Silently it previously cost twenty
minutes of a hanging job — CI passes project variables (live catalog and live
indexer) to all jobs indiscriminately, and tests picked them up and made network calls.

What these tests prove: in the test process a live catalog is not created, and
resolver does not receive a live indexer — regardless of what is set in
the external environment. What they do not prove: that live sources work at all —
that is checked by `scripts/live_source_check.sh` on the production host, and only there.
"""

from __future__ import annotations

import os

import pytest

from app.images import images_from_env
from app.lastfm import lastfm_from_env
from app.main import app as production_app
from app.mbcopy import mbcopy_from_env
from app.musicbrainz import catalog_from_env

LIVE_SOURCE_KEYS = (
    "MUSICBRAINZ_ENABLED",
    "MUSICBRAINZ_CONTACT",
    "MUSICBRAINZ_PROXY",
    "CATALOG_TIMEOUT_S",
    "CATALOG_COOLDOWN_S",
    "PLAYBACK_BUDGET_S",
    "LASTFM_API_KEY",
    "LASTFM_PROXY",
    "LASTFM_API_SECRET",
    "PLAY_SENDER",
    "IMAGE_DIR",
    "MBCOPY_ENABLED",
    "GLITCHTIP_DSN",
    "NEWS_PROXY",
    "LYRICS_URL",
    "PODCASTS_LIVE",
)


def test_live_source_variables_do_not_survive_into_the_test_process() -> None:
    """Live source variables are stripped before importing the application."""
    leaked = [key for key in LIVE_SOURCE_KEYS if os.environ.get(key)]
    assert leaked == [], f"live source variables remained in tests: {leaked}"


def test_catalog_stays_fixture_bound() -> None:
    """Catalog from environment is not built: MusicBrainz is not invoked in tests."""
    assert catalog_from_env(dict(os.environ)) is None


def test_production_app_object_is_fixture_bound_in_tests() -> None:
    """Even imported production application in tests has no live catalog.

    `app.main:app` is created at import time — if variables were stripped later,
    this object would have already made network calls, and tests would not have noticed.
    """
    assert production_app.state.catalog_port is None


def test_lastfm_robot_is_off_in_tests() -> None:
    """Last.fm key from environment does not reach the worker: it is not created in tests."""
    assert lastfm_from_env(dict(os.environ), "postgresql://music@127.0.0.1/none") is None


def test_image_robot_is_off_in_tests() -> None:
    """Images from environment are not created in tests.

    Otherwise the suite would access Cover Art Archive, Wikidata, and Wikimedia Commons,
    writing image files to the production directory on disk.
    """
    assert images_from_env(dict(os.environ), "postgresql://music@127.0.0.1/none") is None


def test_mbcopy_robot_is_off_in_tests() -> None:
    """MusicBrainz replica worker from environment is not created in tests."""
    assert mbcopy_from_env(dict(os.environ), "postgresql://music@127.0.0.1/none") is None


def test_unknown_provider_variable_does_not_send_an_external_request(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A provider name the strip-list does not know still cannot leave the machine.

    The variable stays set on purpose: deleting it would hide a missing socket
    guard. 203.0.113.10 is documentation space; the guard must raise before a
    packet, not after a timeout.
    """
    import socket

    import httpx

    monkeypatch.setenv("DEEZER_URL", "http://203.0.113.10:9/search")
    assert "DEEZER_URL" not in LIVE_SOURCE_KEYS
    assert os.environ["DEEZER_URL"]

    with pytest.raises(OSError, match="external socket blocked"):
        socket.create_connection(("203.0.113.10", 9), timeout=1)
    with pytest.raises(OSError, match="external socket blocked"):
        socket.getaddrinfo("musicbrainz.org", 443)

    try:
        httpx.get(os.environ["DEEZER_URL"], timeout=1)
    except Exception as exc:
        text = _exception_text(exc)
        assert "external socket blocked" in text, text
    else:
        raise AssertionError("unknown provider variable received a response")


def test_loopback_sockets_stay_allowed() -> None:
    """Legal loopback is on the allowlist. A closed port is not a block."""
    import socket

    server = socket.socket()
    server.bind(("127.0.0.1", 0))
    server.listen(1)
    port = server.getsockname()[1]
    try:
        client = socket.create_connection(("127.0.0.1", port), timeout=1)
        client.close()
        refused = socket.socket()
        refused.settimeout(1)
        try:
            refused.connect(("127.0.0.1", 1))
        except OSError as exc:
            assert "external socket blocked" not in str(exc)
        finally:
            refused.close()
    finally:
        server.close()


def _fresh_guard(env: dict[str, str]) -> str:
    """Import conftest in a clean process. The allowlist is built at import."""
    import subprocess
    import sys
    from pathlib import Path

    tests = str(Path(__file__).resolve().parent)
    child = os.environ.copy()
    for key in (
        "DATABASE_URL", "CI", "HTTP_PROXY", "HTTPS_PROXY",
        "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy",
    ):
        child.pop(key, None)
    child.update(env)
    previous = child.get("PYTHONPATH")
    child["PYTHONPATH"] = tests if not previous else tests + os.pathsep + previous
    script = (
        "import os, socket\nimport conftest\n"
        "host = os.environ['PROBE_HOST']\n"
        "print('allowed', int(conftest.host_allowed(host)))\n"
        "try:\n"
        "    conftest._reject((host, 9))\n"
        "    print('reject open')\n"
        "except OSError as exc:\n"
        "    print('reject', exc)\n"
        "if os.environ.get('TRY_SOCKET') == '1':\n"
        "    os.environ['DEEZER_URL'] = 'http://%s:9/x' % host\n"
        "    print('deezer', int(bool(os.environ.get('DEEZER_URL'))))\n"
        "    try:\n"
        "        socket.create_connection((host, 9), timeout=1)\n"
        "        print('socket open')\n"
        "    except OSError as exc:\n"
        "        print('socket', exc)\n"
    )
    completed = subprocess.run(
        [sys.executable, "-c", script],
        env=child,
        capture_output=True,
        text=True,
        timeout=20,
        check=False,
    )
    blob = completed.stdout + completed.stderr
    assert "secret" not in blob
    assert completed.returncode == 0, completed.stderr
    return completed.stdout


def test_unlisted_live_host_stays_blocked() -> None:
    """A host nobody put on the allowlist stays blocked in a fresh process."""
    out = _fresh_guard({
        "DATABASE_URL": "",
        "PROBE_HOST": "203.0.113.10",
        "TRY_SOCKET": "1",
    })
    assert "allowed 0" in out
    assert "deezer 1" in out
    assert out.count("external socket blocked") >= 2
    assert "socket open" not in out


def test_remote_database_url_is_not_a_fixture_host() -> None:
    """CI does not turn an arbitrary DATABASE_URL host into a fixture."""
    out = _fresh_guard({
        "CI": "1",
        "DATABASE_URL": "postgresql://music:secret@203.0.113.10:5432/music",
        "PROBE_HOST": "203.0.113.10",
        "TRY_SOCKET": "1",
    })
    assert "allowed 0" in out
    assert "external socket blocked" in out
    assert "socket open" not in out


def test_ci_postgres_service_is_allowed_only_inside_the_job() -> None:
    """The GitLab service alias is a fixture host only when CI confirmed the job."""
    blocked = _fresh_guard({
        "DATABASE_URL": "postgresql://music@postgres:5432/music",
        "PROBE_HOST": "postgres",
    })
    assert "allowed 0" in blocked
    assert "external socket blocked" in blocked
    allowed = _fresh_guard({
        "CI": "1",
        "DATABASE_URL": "postgresql://music@postgres:5432/music",
        "PROBE_HOST": "postgres",
    })
    assert "allowed 1" in allowed
    assert "reject open" in allowed


def test_fixture_host_is_allowed_and_an_external_name_is_not() -> None:
    """CI's PostgreSQL hostname is a fixture address, not an open network."""
    import sys

    guard = next(
        module
        for name, module in sys.modules.items()
        if hasattr(module, "remember_fixture_host")
        and (name == "conftest" or name.endswith(".conftest"))
    )
    guard.remember_fixture_host("postgres")
    assert guard.host_allowed("postgres")
    assert guard.host_allowed("127.0.0.1")
    assert not guard.host_allowed("203.0.113.10")
    assert not guard.host_allowed("musicbrainz.org")


def _exception_text(exc: BaseException) -> str:
    parts: list[str] = []
    seen: set[int] = set()
    current: BaseException | None = exc
    while current is not None and id(current) not in seen:
        seen.add(id(current))
        parts.append(type(current).__name__)
        parts.append(str(current))
        current = current.__cause__ or current.__context__
    return " ".join(parts)
