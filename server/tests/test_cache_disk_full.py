"""FT-647 (Х5): disk ran out in the middle of copying song to cache.

Previously a truncated file with real name remained on disk, and subsequent Play press served it as
a whole song — forever. Here copying is cut off in the middle, and it is verified that nothing believable
remains in cache, while the song still plays — from its previous location.
"""

from __future__ import annotations

import errno
import logging
from pathlib import Path
from typing import Any

import pytest

from app import cache as cache_module
from app.cache import StreamCache

SONG = bytes(range(256)) * 400


@pytest.fixture
def song(tmp_path: Path) -> Path:
    src = tmp_path / "src"
    src.mkdir()
    path = src / "Secret Artist - Secret Song.flac"
    path.write_bytes(SONG)
    return path


@pytest.fixture
def cache(tmp_path: Path) -> StreamCache:
    return StreamCache(tmp_path / "cache")


def _files(cache: StreamCache) -> list[Path]:
    return sorted(path for path in cache.root.rglob("*") if path.is_file())


def _disk_ends_halfway(monkeypatch: pytest.MonkeyPatch) -> None:
    def copy(source: Any, target: Any, length: int = 0) -> None:
        target.write(source.read(len(SONG) // 2))
        target.flush()
        raise OSError(errno.ENOSPC, "No space left on device")

    monkeypatch.setattr(cache_module.shutil, "copyfileobj", copy)


def test_song_is_copied_whole(cache: StreamCache, song: Path) -> None:
    kept = cache.put(song)
    assert kept.parent == cache.root and kept != song
    assert kept.read_bytes() == SONG
    assert kept.suffix == ".flac"
    assert _files(cache) == [kept]


def test_second_put_does_not_copy_again(
    cache: StreamCache, song: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    kept = cache.put(song)

    def no_copy(*args: Any, **kwargs: Any) -> None:
        raise AssertionError("целый файл в кэше копировать второй раз незачем")

    monkeypatch.setattr(cache_module.shutil, "copyfileobj", no_copy)
    assert cache.put(song) == kept
    assert kept.read_bytes() == SONG


def test_disk_full_halfway_leaves_nothing_and_the_song_still_plays(
    cache: StreamCache, song: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _disk_ends_halfway(monkeypatch)
    answer = cache.put(song)
    assert answer == song, "song plays from its previous location"
    assert _files(cache) == [], (
        "truncated file is not in cache — neither under real name nor under temporary"
    )
    assert song.read_bytes() == SONG


def test_after_the_disk_is_freed_the_song_is_cached_whole(
    cache: StreamCache, song: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    with monkeypatch.context() as broken:
        _disk_ends_halfway(broken)
        cache.put(song)
    kept = cache.put(song)
    assert kept != song
    assert kept.read_bytes() == SONG
    assert _files(cache) == [kept]


def test_the_real_name_never_holds_a_part_of_the_song(
    cache: StreamCache, song: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    final = cache.put(song)
    final.unlink()
    during: list[bool] = []
    real_copy = cache_module.shutil.copyfileobj

    def watching(source: Any, target: Any, *args: Any) -> None:
        target.write(source.read(100))
        target.flush()
        during.append(final.exists())
        real_copy(source, target, *args)

    monkeypatch.setattr(cache_module.shutil, "copyfileobj", watching)
    assert cache.put(song) == final
    assert during == [False], "while file is being written, it does not exist under real name"
    assert final.read_bytes() == SONG


def test_truncated_file_from_an_old_failure_is_replaced(
    cache: StreamCache, song: Path
) -> None:
    kept = cache.put(song)
    kept.write_bytes(SONG[: len(SONG) // 2])
    again = cache.put(song)
    assert again == kept
    assert again.read_bytes() == SONG


def test_leftover_of_an_interrupted_copy_is_swept(
    cache: StreamCache, song: Path
) -> None:
    kept = cache.put(song)
    kept.unlink()
    # Remainder of this song and remainder of another: server crashed during copy, no one swept them.
    (cache.root / (kept.name + ".part")).write_bytes(SONG[:1000])
    (cache.root / ("0" * 64 + ".mp3.part")).write_bytes(b"x" * 1000)
    assert cache.put(song) == kept
    assert _files(cache) == [kept]


def test_failed_rename_also_leaves_nothing(
    cache: StreamCache, song: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    def no_rename(*args: Any, **kwargs: Any) -> None:
        raise OSError(errno.EIO, "Input/output error")

    monkeypatch.setattr(cache_module.os, "replace", no_rename)
    assert cache.put(song) == song
    assert _files(cache) == []


def test_cache_folder_closed_for_writing_is_not_a_crash(
    cache: StreamCache, song: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # Folder permissions do not work: in CI tests run as root, which writes even into closed folder.
    real_open = Path.open

    def closed(self: Path, mode: str = "r", *args: Any, **kwargs: Any) -> Any:
        if "w" in mode and self.parent == cache.root:
            raise PermissionError(errno.EACCES, "Permission denied")
        return real_open(self, mode, *args, **kwargs)

    monkeypatch.setattr(Path, "open", closed)
    assert cache.put(song) == song
    assert _files(cache) == []


def test_other_songs_in_the_cache_survive_a_failed_copy(
    cache: StreamCache, song: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    other = song.with_name("other.mp3")
    other.write_bytes(b"x" * 500)
    kept = cache.put(other)
    _disk_ends_halfway(monkeypatch)
    assert cache.put(song) == song
    assert _files(cache) == [kept]
    assert kept.read_bytes() == b"x" * 500


def test_failure_is_logged_without_the_song(
    cache: StreamCache,
    song: Path,
    monkeypatch: pytest.MonkeyPatch,
    caplog: pytest.LogCaptureFixture,
) -> None:
    _disk_ends_halfway(monkeypatch)
    with caplog.at_level(logging.DEBUG, logger="apertonodo"):
        cache.put(song)
    lines = [record.getMessage() for record in caplog.records]
    assert any(
        line.startswith("cache: copy failed") and "ENOSPC" in line for line in lines
    ), lines
    text = "\n".join(lines)
    assert "Secret" not in text and "flac" not in text and str(cache.root) not in text
    assert [record.levelname for record in caplog.records] == ["WARNING"]


def test_success_logs_nothing(
    cache: StreamCache, song: Path, caplog: pytest.LogCaptureFixture
) -> None:
    with caplog.at_level(logging.DEBUG, logger="apertonodo"):
        cache.put(song)
    assert caplog.records == []


def test_quota_is_still_made_room_for_before_copying(
    tmp_path: Path, song: Path
) -> None:
    small = StreamCache(tmp_path / "small", quota_bytes=len(SONG) + 100)
    other = song.with_name("other.mp3")
    other.write_bytes(b"x" * 500)
    first = small.put(other)
    kept = small.put(song)
    assert kept.read_bytes() == SONG
    assert not first.exists()
