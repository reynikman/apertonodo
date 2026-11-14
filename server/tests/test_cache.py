from __future__ import annotations

from pathlib import Path

from app.cache import StreamCache


def test_put_evicts_oldest_unused_when_over_quota(tmp_path: Path) -> None:
    cache = StreamCache(tmp_path / "cache", quota_bytes=100)
    src = tmp_path / "src"
    src.mkdir()
    first = src / "a.bin"
    second = src / "b.bin"
    first.write_bytes(b"a" * 60)
    second.write_bytes(b"b" * 60)
    kept = cache.put(first)
    assert kept.exists()
    newer = cache.put(second)
    assert newer.exists()
    assert not kept.exists()


def test_put_does_not_evict_kept_file(tmp_path: Path) -> None:
    cache = StreamCache(tmp_path / "cache", quota_bytes=100)
    src = tmp_path / "src"
    src.mkdir()
    first = src / "a.bin"
    second = src / "b.bin"
    first.write_bytes(b"a" * 60)
    second.write_bytes(b"b" * 60)
    kept = cache.put(first)
    newer = cache.put(second, keep={kept})
    assert kept.exists()
    assert newer.exists()
