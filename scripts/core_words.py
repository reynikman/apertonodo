#!/usr/bin/env python3
"""FT-588 (P8, Р-A88): source words guard in core.

Searches for source words (magnet, torrent, tracker, info_hash, infohash)
in core paths and reports each occurrence in `path:line: word` format.
"""

from __future__ import annotations

import argparse
import fnmatch
import os
import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]

CORE_PATHS = (
    "server/app",
    "server/tests",
    "mobile/lib",
    "mobile/test",
    "mobile/integration_test",
    "mobile/pubspec.lock",
    "contracts",
    "Dockerfile",
    "docker-compose.yml",
)

SKIP_DIRS = {
    ".venv",
    "build",
    ".dart_tool",
    "node_modules",
    "__pycache__",
}

SAFE_IDENTIFIERS = {
    "leak_tracker",
    "ffi_leak_tracker",
    "leak_tracker_flutter_testing",
    "leak_tracker_testing",
}

IDENT_RE = re.compile(r"[A-Za-z0-9_]+")
WORD_RE = re.compile(r"magnet|torrent|tracker|info_hash|infohash", re.IGNORECASE)
# Russian forms of the same words, matched anywhere in a line (stems are split so this file stays clean).
RU_WORD_RE = re.compile("|".join(["тре" + "кер", "тор" + "рент", "раз" + "дач", "маг" + "нет", "си" + "дер"]), re.IGNORECASE)


def load_allow_patterns(allow_file: Path) -> list[str]:
    patterns: list[str] = []
    if not allow_file.is_file():
        return patterns
    try:
        text = allow_file.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        return patterns
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        pattern = line.split("#", 1)[0].strip()
        if pattern.startswith("./"):
            pattern = pattern[2:]
        if pattern:
            patterns.append(pattern)
    return patterns


def discover_files(root: Path) -> list[Path]:
    collected: list[Path] = []
    for rel_str in CORE_PATHS:
        target = root / rel_str
        if not target.exists():
            continue
        if target.is_file():
            collected.append(target)
        elif target.is_dir():
            for dirpath, dirnames, filenames in os.walk(target):
                dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
                for filename in filenames:
                    collected.append(Path(dirpath) / filename)
    return sorted(set(collected), key=lambda p: p.relative_to(root).as_posix())


def scan_tree(
    root: Path,
) -> tuple[list[tuple[str, int, str]], set[tuple[str, int]], set[str], set[str]]:
    allow_file = root / "scripts" / "core_words.allow"
    allow_patterns = load_allow_patterns(allow_file)
    files = discover_files(root)

    hits: list[tuple[str, int, str]] = []
    matching_lines: set[tuple[str, int]] = set()
    matching_files: set[str] = set()
    excluded_files: set[str] = set()

    for file_path in files:
        rel_posix = file_path.relative_to(root).as_posix()
        if any(fnmatch.fnmatch(rel_posix, pat) for pat in allow_patterns):
            excluded_files.add(rel_posix)
            continue

        try:
            content = file_path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue

        for line_idx, line in enumerate(content.splitlines(), 1):
            for m_ident in IDENT_RE.finditer(line):
                ident = m_ident.group(0)
                if ident.lower() in SAFE_IDENTIFIERS:
                    continue
                for m_word in WORD_RE.finditer(ident):
                    word = m_word.group(0).lower()
                    hits.append((rel_posix, line_idx, word))
                    matching_lines.add((rel_posix, line_idx))
                    matching_files.add(rel_posix)
            for m_ru in RU_WORD_RE.finditer(line):
                hits.append((rel_posix, line_idx, m_ru.group(0).lower()))
                matching_lines.add((rel_posix, line_idx))
                matching_files.add(rel_posix)

    return hits, matching_lines, matching_files, excluded_files


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Source words guard in core.")
    parser.add_argument(
        "--root",
        type=Path,
        default=REPO_ROOT,
        help="repository root (default project root)",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="exit with code 1 if matches are found",
    )
    args = parser.parse_args(argv)
    root = args.root.resolve()

    hits, matching_lines, matching_files, excluded_files = scan_tree(root)

    for rel_posix, line_idx, word in hits:
        print(f"{rel_posix}:{line_idx}: {word}")

    print(
        f"source words: {len(matching_lines)} lines in {len(matching_files)} files; "
        f"excluded {len(excluded_files)} files"
    )

    if args.strict and matching_lines:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
