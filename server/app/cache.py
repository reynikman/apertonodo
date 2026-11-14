from __future__ import annotations

from dataclasses import dataclass
import errno
import hashlib
import logging
import os
from pathlib import Path
import shutil
from typing import Any

logger = logging.getLogger("apertonodo")


@dataclass
class StorageReconcileResult:
    orphans_on_disk: int
    orphans_counted: int
    orphan_files: list[Path]
    kept_assets: list[str]
    evicted_assets: list[str]

    def __getitem__(self, item: str) -> Any:
        return getattr(self, item)

    def get(self, item: str, default: Any = None) -> Any:
        return getattr(self, item, default)


def _is_safely_inside(root: Path, target: Path) -> bool:
    try:
        resolved_root = root.resolve()
        resolved_target = target.resolve()
        return resolved_root in resolved_target.parents
    except (ValueError, OSError, RuntimeError):
        return False


def reconcile_cache(
    managed_root: Path,
    manifest_assets: dict[str, int],
    pins: dict[str, set[str]],
    active_assets: set[str] | None = None,
    quota_bytes: int | None = None,
) -> StorageReconcileResult:
    """Reconciles managed-cache directory against disk storage."""
    managed_root = Path(managed_root)
    if not managed_root.exists():
        return StorageReconcileResult(0, 0, [], [], [])

    root_resolved = managed_root.resolve()
    all_pinned: set[str] = {
        asset for user_pins in pins.values() for asset in user_pins
    }
    active: set[str] = set(active_assets or ())

    valid_manifest: dict[str, int] = {}
    for rel_key, expected_size in manifest_assets.items():
        candidate = managed_root / rel_key
        if not _is_safely_inside(managed_root, candidate):
            continue
        if candidate.is_symlink() and not _is_safely_inside(managed_root, candidate.resolve()):
            continue
        rel = candidate.relative_to(managed_root)
        if rel.parts and rel.parts[0] in ("session", ".session"):
            continue
        valid_manifest[rel_key] = expected_size

    orphan_files: list[Path] = []
    orphans_on_disk = 0

    for dirpath, dirnames, filenames in os.walk(managed_root, followlinks=False):
        current_dir = Path(dirpath)
        try:
            rel_dir = current_dir.relative_to(managed_root)
        except ValueError:
            continue
        if rel_dir.parts and rel_dir.parts[0] in ("session", ".session"):
            dirnames.clear()
            continue

        dirnames[:] = [
            d for d in dirnames
            if d not in ("session", ".session")
            and not (current_dir / d).is_symlink()
        ]

        for fn in filenames:
            file_path = current_dir / fn
            if file_path.is_symlink():
                try:
                    target_resolved = file_path.resolve()
                    if root_resolved not in target_resolved.parents and target_resolved != root_resolved:
                        continue
                except (OSError, RuntimeError):
                    continue

            rel_file = file_path.relative_to(managed_root)
            rel_str = str(rel_file)
            rel_posix = rel_file.as_posix()

            if (
                rel_str in valid_manifest
                or rel_posix in valid_manifest
                or rel_str in all_pinned
                or rel_posix in all_pinned
                or rel_str in active
                or rel_posix in active
            ):
                continue

            size = os.stat(file_path, follow_symlinks=False).st_size
            orphans_on_disk += size
            orphan_files.append(file_path)

    orphans_counted = orphans_on_disk

    managed_asset_sizes: dict[str, int] = {}
    for rel_key in valid_manifest:
        file_path = managed_root / rel_key
        # A manifest entry whose file is gone takes no disk: counting its expected
        # size would evict live files for bytes that are not there.
        managed_asset_sizes[rel_key] = (
            os.stat(file_path, follow_symlinks=False).st_size if file_path.is_file() else 0
        )

    total_used = orphans_counted + sum(managed_asset_sizes.values())

    evicted_assets: list[str] = []
    if quota_bytes is not None and total_used > quota_bytes:
        protected_keys = all_pinned | active
        disposable_keys = [k for k in valid_manifest if k not in protected_keys]

        def _get_mtime(k: str) -> float:
            p = managed_root / k
            try:
                return p.stat().st_mtime
            except (OSError, ValueError):
                return 0.0

        disposable_keys.sort(key=_get_mtime)

        for k in disposable_keys:
            if total_used <= quota_bytes:
                break
            p = managed_root / k
            if p.is_file() or p.is_symlink():
                try:
                    p.unlink(missing_ok=True)
                except OSError:
                    pass
            total_used -= managed_asset_sizes.get(k, 0)
            evicted_assets.append(k)

    evicted_set = set(evicted_assets)
    kept_assets = [k for k in valid_manifest if k not in evicted_set]

    logger.info(
        "reconcile_cache: %d orphans on disk (%d bytes), kept=%d, evicted=%d",
        len(orphan_files),
        orphans_counted,
        len(kept_assets),
        len(evicted_assets),
    )

    return StorageReconcileResult(
        orphans_on_disk=orphans_on_disk,
        orphans_counted=orphans_counted,
        orphan_files=orphan_files,
        kept_assets=kept_assets,
        evicted_assets=evicted_assets,
    )


class StreamCache:
    def __init__(self, root: Path, quota_bytes: int | None = None) -> None:
        self.root = root
        self.quota_bytes = quota_bytes
        self.root.mkdir(parents=True, exist_ok=True)

    def put(self, source: Path, keep: set[Path] | None = None) -> Path:
        dest = self.root / f"{hashlib.sha256(str(source).encode()).hexdigest()}{source.suffix}"
        part = dest.with_name(f"{dest.name}.part")
        try:
            if dest.is_file() and dest.stat().st_size == source.stat().st_size:
                return dest
            for leftover in self.root.glob("*.part"):
                if leftover.is_file() or leftover.is_symlink():
                    leftover.unlink(missing_ok=True)
            self._evict_for(source.stat().st_size, keep or set())
            with source.open("rb") as src_f, part.open("wb") as dst_f:
                shutil.copyfileobj(src_f, dst_f)
            os.replace(part, dest)
            return dest
        except OSError as exc:
            try:
                part.unlink(missing_ok=True)
            except OSError:
                pass
            err_name = (
                errno.errorcode.get(exc.errno, type(exc).__name__)
                if exc.errno is not None
                else type(exc).__name__
            )
            logger.warning("cache: copy failed %s", err_name)
            return source

    def purge_unused(self, keep: set[Path]) -> None:
        kept = {path.resolve() for path in keep}
        for path in self.root.iterdir():
            if path.is_file() and path.resolve() not in kept:
                path.unlink()

    def _evict_for(self, needed: int, keep: set[Path]) -> None:
        if self.quota_bytes is None:
            return
        kept = {path.resolve() for path in keep}
        files = [path for path in self.root.iterdir() if path.is_file()]
        used = sum(path.stat().st_size for path in files)
        if used + needed <= self.quota_bytes:
            return
        victims = sorted(
            (path for path in files if path.resolve() not in kept),
            key=lambda path: path.stat().st_mtime,
        )
        for victim in victims:
            used -= victim.stat().st_size
            victim.unlink()
            if used + needed <= self.quota_bytes:
                return
