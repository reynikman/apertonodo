"""FT-699: admin panel is wired to the server, and the lock is opened to exactly three of its files.

The check was written by the lead before work. Page /admin is served without a key (there is
no data in it: login goes via /v1/auth/login), while /v1/admin/* stays locked.
"""

from __future__ import annotations

import secrets
from pathlib import Path

import httpx
import pytest

from app.guard import OPEN_PATHS
from app.main import create_app

KEY = secrets.token_urlsafe(32)

PAGE = {
    "/admin": "text/html",
    "/admin/": "text/html",
    "/admin/admin.css": "text/css",
    "/admin/admin.js": "text/javascript",
}


def _client(**kwargs: object) -> httpx.AsyncClient:
    app = create_app(database_url=None, catalog=[], api_key=KEY, **kwargs)  # type: ignore[arg-type]
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test")


def test_open_paths_are_exactly_these() -> None:
    assert OPEN_PATHS == frozenset(
        {"/v1/health", "/v1/auth/login", "/v1/auth/claim", "/admin", "/admin/admin.css", "/admin/admin.js"}
    )


@pytest.mark.parametrize("path", sorted(PAGE))
async def test_page_files_open_without_key(path: str) -> None:
    async with _client() as client:
        resp = await client.get(path)
    assert resp.status_code == 200
    assert resp.headers["content-type"].startswith(PAGE[path])
    assert resp.headers["cache-control"] == "no-store"
    assert "default-src 'none'" in resp.headers["content-security-policy"]
    assert resp.content


@pytest.mark.parametrize(
    "path",
    [
        "/admin/index.html",
        "/admin/other.js",
        "/admin/admin.js.map",
        "/admin/admin.css/x",
        "/administrator",
        "/admin2",
        "/v1/admin",
        "/v1/admin/users",
        "/v1/admin/state",
        "/docs",
        "/openapi.json",
    ],
)
async def test_everything_else_stays_locked(path: str) -> None:
    async with _client() as client:
        resp = await client.get(path)
    assert resp.status_code == 401


async def test_admin_api_rejects_wrong_key() -> None:
    async with _client() as client:
        resp = await client.get("/v1/admin/users", headers={"x-apertonodo-key": KEY + "a"})
    assert resp.status_code == 401


@pytest.mark.parametrize("path", ["/v1/admin/users", "/v1/admin/state"])
async def test_admin_api_is_installed(path: str) -> None:
    # With the key the request reaches the endpoint: without database it replies with rejection, but not 404.
    async with _client() as client:
        resp = await client.get(path, headers={"x-apertonodo-key": KEY})
    assert resp.status_code not in (401, 404, 405)


async def test_page_is_read_only() -> None:
    async with _client() as client:
        resp = await client.post("/admin", content=b"x")
    assert resp.status_code == 405


def test_storage_probe_counts_cache(tmp_path: Path) -> None:
    app = create_app(database_url=None, catalog=[], api_key=KEY, cache_dir=tmp_path)
    (tmp_path / "a.mp3").write_bytes(b"x" * 1000)
    (tmp_path / "b.flac").write_bytes(b"y" * 234)
    (tmp_path / "dir").mkdir()
    space = app.state.admin.storage()
    assert set(space) == {"total_bytes", "free_bytes", "cache_bytes"}
    assert space["cache_bytes"] == 1234
    assert space["total_bytes"] >= space["free_bytes"] > 0
    assert all(type(v) is int for v in space.values())


def test_no_cache_no_storage_probe() -> None:
    app = create_app(database_url=None, catalog=[], api_key=KEY)
    assert app.state.admin.storage is None


def test_admin_knows_the_key() -> None:
    app = create_app(database_url=None, catalog=[], api_key=KEY)
    assert app.state.admin.api_key == KEY


@pytest.mark.parametrize("path", ["/docs", "/redoc", "/openapi.json", "/admin/x", "/"])
async def test_made_up_bearer_does_not_open_paths_outside_v1(path: str) -> None:
    # A bearer is checked against the token table only under /v1/ (UserGuard); outside it
    # any "Bearer x" used to pass the outer lock and hand out the whole API schema.
    async with _client() as client:
        resp = await client.get(path, headers={"authorization": "Bearer made-up"})
    assert resp.status_code == 401
