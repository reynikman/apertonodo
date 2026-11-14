"""FT-544: covers — cache with space quota (Р-A65).

Covers consume unlimited space: in production 2 GB in a week, and for a user with
a small disk they would exhaust everything. Owner decision 03.10: quota,
default 20 GB (~300k covers); when space runs out — those not opened longest
are evicted, like the music cache (`cache_quota_bytes`). An evicted cover
is not marked "searched, not found": if the album is opened — the worker downloads it again.
"""

from __future__ import annotations

import asyncio
from pathlib import Path

import asyncpg
from fakes import FakeWeb, pictures
from test_catalog_browse import JPEG
from test_images import _rows, built  # noqa: F401 — fixture

from app import images

A = "a0000000-0000-4000-8000-000000000544"
B = "b0000000-0000-4000-8000-000000000544"
C = "c0000000-0000-4000-8000-000000000544"


async def _open(url: str, album_id: str) -> str | None:
    """Like the phone: `/v1/covers/{id}` asks `cover_file` for the path."""
    conn = await asyncpg.connect(url)
    try:
        return await images.cover_file(conn, album_id)
    finally:
        await conn.close()


def test_least_recently_opened_cover_goes_first(built: str, tmp_path: Path) -> None:  # noqa: F811
    web = FakeWeb({"coverartarchive.org": JPEG})
    # Space for exactly two covers.
    shelf = pictures(tmp_path, built, web, cover_quota_bytes=2 * len(JPEG) + len(JPEG) // 2)
    with web.client() as client:
        assert shelf.cover(client, A, "Glass Harbor", "One") == "stored"
        assert shelf.cover(client, B, "Glass Harbor", "Two") == "stored"
        # A was downloaded before B, but it was opened — meaning it is needed.
        path_a = asyncio.run(_open(built, A))
        assert path_a is not None
        path_b = asyncio.run(_rows(built, "SELECT path FROM album_images WHERE album_id = $1::uuid", B))[0]["path"]
        assert shelf.cover(client, C, "Glass Harbor", "Three") == "stored"

    assert asyncio.run(_open(built, A)) is not None, "recently opened cover was evicted instead of least recently used"
    assert asyncio.run(_open(built, C)) is not None, "just-downloaded cover was evicted"
    assert asyncio.run(_open(built, B)) is None, "space quota exceeded — excess cover was not evicted"
    assert not (tmp_path / path_b).exists(), "database row removed, but file remained on disk"
    # Not "searched, not found": if the album is opened again — the cover will be re-downloaded.
    left = asyncio.run(_rows(built, "SELECT 1 FROM album_images WHERE album_id = $1::uuid", B))
    assert left == [], "evicted cover recorded as 'missing' and will not re-download until RETRY"
    on_disk = sum(f.stat().st_size for f in (tmp_path / "covers").rglob("*") if f.is_file())
    assert on_disk <= 2 * len(JPEG) + len(JPEG) // 2


def test_quota_is_20_gb_by_default_and_set_by_env(tmp_path: Path) -> None:
    shelf = images.images_from_env({"IMAGE_DIR": str(tmp_path)}, "postgresql://x/y")
    assert shelf is not None and shelf.cover_quota_bytes == 20 * 1024**3
    shelf = images.images_from_env({"IMAGE_DIR": str(tmp_path), "COVER_QUOTA_BYTES": "1000000"}, "postgresql://x/y")
    assert shelf is not None and shelf.cover_quota_bytes == 1_000_000
