#!/usr/bin/env python3
"""Russian strings guard in application code (FT-600, Р-A84).

    python3 scripts/l10n_check.py [--lib mobile/lib] [--strict]

Counts string literals with Russian letters in `*.dart`, by file. Comments are not counted (translated by
P9 wave B), generated translation code `l10n/` is ignored as well. Without `--strict` — report, exit 0; with it — exit 1
while at least one string remains (FT-606).
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

CYRILLIC = re.compile(r"[А-Яа-яЁё]")


def _literals(line: str) -> list[str]:
    """String literals in code line; everything after `//` outside quotes is a comment."""
    found: list[str] = []
    quote = ""
    start = 0
    i = 0
    while i < len(line):
        char = line[i]
        if quote:
            if char == "\\":
                i += 2
                continue
            if char == quote:
                found.append(line[start:i])
                quote = ""
        elif char in "'\"":
            quote, start = char, i + 1
        elif line.startswith("//", i):
            break
        i += 1
    return found


def count(lib: Path) -> dict[str, int]:
    result: dict[str, int] = {}
    for path in sorted(lib.rglob("*.dart")):
        rel = path.relative_to(lib).as_posix()
        if rel.startswith("l10n/"):
            continue
        hits = sum(
            1
            for line in path.read_text(encoding="utf-8").splitlines()
            for literal in _literals(line)
            if CYRILLIC.search(literal)
        )
        if hits:
            result[rel] = hits
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--lib", default=str(Path(__file__).resolve().parents[1] / "mobile" / "lib"))
    parser.add_argument("--strict", action="store_true")
    args = parser.parse_args()
    found = count(Path(args.lib))
    for rel, hits in sorted(found.items(), key=lambda item: (-item[1], item[0])):
        print(f"{rel}: {hits}")
    total = sum(found.values())
    print(f"Russian lines in code: {total}")
    return 1 if args.strict and total else 0


if __name__ == "__main__":
    sys.exit(main())
