"""Large images are shrunk to screen size (FT-545, Р-A65).

Production measurement 04.10: 16,135 covers — 2.0 GB, median 68 KB, but 789 files
over 300 KB take 48% of the space. Covers from Cover Art Archive already arrive
shrunk (`front-500`), while the fallback path — release file — and photos from
Wikimedia Commons were stored as is, up to 5 MB. Now such images are shrunk to
500 pixels (photos — to `PHOTO_WIDTH`) using the same `ffmpeg` already present in the image
for Opus copies; small ones are stored byte for byte.

What these tests do not prove: that the 789 large files already in production
will become smaller — the card touches only new ones.
"""

from __future__ import annotations

import asyncio
import logging
import subprocess
from pathlib import Path

import asyncpg
import pytest
from fakes import FakeWeb, photo_routes, pictures
from test_catalog_browse import _extension, ARTIST, LOW_TIDE, _seed

from app import images


def _picture(tmp_path: Path, name: str, size: int, quality: int, noise: bool) -> bytes:
    """Real JPEG of required size: noise makes it heavy, like a scan from a release."""
    source = f"testsrc2=size={size}x{size}" + (",noise=alls=40:allf=t" if noise else "")
    path = tmp_path / name
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", source, "-frames:v", "1", "-q:v", str(quality), str(path)],
        check=True,
    )
    return path.read_bytes()


def _side(path: Path) -> int:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "stream=width,height", "-of", "csv=p=0", str(path)],
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    return max(int(value) for value in out.split(","))


@pytest.fixture
def built(postgres_url: str) -> str:
    asyncio.run(_seed(postgres_url))
    asyncio.run(_extension().build_catalog(postgres_url))
    return postgres_url


async def _row(url: str, sql: str) -> asyncpg.Record:
    conn = await asyncpg.connect(url)
    try:
        return await conn.fetchrow(sql)
    finally:
        await conn.close()


def test_big_cover_from_release_shrinks_to_500(built: str, tmp_path: Path, caplog) -> None:
    big = _picture(tmp_path, "scan.jpg", 1500, 2, noise=True)
    assert len(big) > 1_000_000  # positive control: source is indeed heavy
    root = tmp_path / "images"
    shelf = pictures(root, built, FakeWeb({"coverartarchive.org": 404}), from_release=lambda _a, _t: big)
    with caplog.at_level(logging.INFO, logger="apertonodo"):
        shelf.want(("cover", LOW_TIDE, "Glass Harbor", "Low Tide"))
        shelf.queue.join()

    row = asyncio.run(_row(built, "SELECT path, size_bytes FROM album_images"))
    assert row["path"] is not None
    stored = root / row["path"]
    assert stored.read_bytes().startswith(images.JPEG)
    assert _side(stored) <= 500
    assert stored.stat().st_size < 150_000
    # Space cap counts what went to disk, not what arrived.
    assert row["size_bytes"] == stored.stat().st_size
    assert f"cover: stored {stored.stat().st_size // 1024} KB from release" in caplog.text


def test_small_cover_from_archive_is_kept_as_is(built: str, tmp_path: Path) -> None:
    small = _picture(tmp_path, "front.jpg", 500, 5, noise=False)
    root = tmp_path / "images"
    shelf = pictures(root, built, FakeWeb({"coverartarchive.org": small}))
    shelf.want(("cover", LOW_TIDE, "Glass Harbor", "Low Tide"))
    shelf.queue.join()

    row = asyncio.run(_row(built, "SELECT path, size_bytes FROM album_images"))
    assert (root / row["path"]).read_bytes() == small
    assert row["size_bytes"] == len(small)


def test_unreadable_picture_is_kept_as_before(built: str, tmp_path: Path) -> None:
    """Bytes look like JPEG, but ffmpeg cannot read it: behave as before —
    store as is (up to `MAX_BYTES`), without losing the cover or dropping the queue."""
    broken = images.JPEG + b"\x00" * 400_000
    root = tmp_path / "images"
    shelf = pictures(root, built, FakeWeb({"coverartarchive.org": broken}))
    shelf.want(("cover", LOW_TIDE, "Glass Harbor", "Low Tide"))
    shelf.queue.join()

    row = asyncio.run(_row(built, "SELECT path, size_bytes FROM album_images"))
    assert row["path"] is not None
    assert (root / row["path"]).read_bytes() == broken


def test_big_photo_shrinks_to_photo_width(built: str, tmp_path: Path) -> None:
    big = _picture(tmp_path, "band.jpg", 2000, 2, noise=True)
    root = tmp_path / "images"
    shelf = pictures(root, built, FakeWeb(photo_routes(ARTIST, big)))
    shelf.want(("photo", "glass harbor", ARTIST, ""))
    shelf.queue.join()

    row = asyncio.run(_row(built, "SELECT path, author FROM artist_photos"))
    assert row["path"] is not None and row["author"]
    stored = root / row["path"]
    assert _side(stored) <= images.PHOTO_WIDTH
    assert stored.stat().st_size < 200_000
