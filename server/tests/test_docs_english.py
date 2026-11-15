"""FT-836: operator documents that ship to GitHub read in English.

Only words change: every fenced block keeps its commands. A line of a fenced
block may differ from the base only if the base line carried Cyrillic (a
translated comment); the number of lines in each block stays the same.
"""

import re
import subprocess
from pathlib import Path

import pytest
from not_in_slice import missing

ROOT = Path(__file__).resolve().parents[2]
BASE = "21aff12880"
DOCS = [
    "docs/logs.md",
    "docs/live-sources.md",
    "docs/alerts.md",
    "docs/migrations.md",
    "docs/reverse-proxy.md",
    "docs/soak.md",
    "docs/backup.md",
    "docs/rollback.md",
]
# FT-910: lines of fenced blocks changed on purpose after the base commit.
DROPPED = {"python3 scripts/acceptance/cases/FT-010.py verify   # exit 0; VERIFY_OK FT-010"}
RENAMED = ("flowtune_", "apertonodo_")
CYRILLIC = re.compile("[а-яА-ЯёЁ]")
FENCE = "`" * 3
# Quoted interface strings and names of the owner's decisions may stay.
ALLOWED_PER_FILE = 4


def fenced(text: str) -> list[list[str]]:
    blocks: list[list[str]] = []
    inside: list[str] | None = None
    for line in text.splitlines():
        if line.lstrip().startswith(FENCE):
            if inside is None:
                inside = []
            else:
                blocks.append(inside)
                inside = None
        elif inside is not None:
            inside.append(line)
    return blocks


@pytest.mark.parametrize("doc", DOCS)
def test_document_reads_in_english(doc: str) -> None:
    if missing(doc):
        pytest.skip(f"not in public slice: {doc}")
    left = [
        line for line in (ROOT / doc).read_text().splitlines() if CYRILLIC.search(line)
    ]
    assert len(left) <= ALLOWED_PER_FILE, f"{doc}: {len(left)} lines with Cyrillic left"


@pytest.mark.parametrize("doc", DOCS)
def test_commands_in_fenced_blocks_are_untouched(doc: str) -> None:
    if missing(doc):
        pytest.skip(f"not in public slice: {doc}")
    shown = subprocess.run(
        ["git", "show", f"{BASE}:{doc}"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if shown.returncode != 0:
        pytest.skip("base commit is not in this clone")
    before = [
        [x.replace(*RENAMED) for x in blk if x not in DROPPED]
        for blk in fenced(shown.stdout)
    ]
    after = fenced((ROOT / doc).read_text())
    assert len(before) == len(after), f"{doc}: number of fenced blocks changed"
    for old, new in zip(before, after, strict=True):
        assert len(old) == len(new), f"{doc}: a fenced block changed its length"
        for a, b in zip(old, new, strict=True):
            assert a == b or CYRILLIC.search(a), (
                f"{doc}: command changed: {a!r} -> {b!r}"
            )
