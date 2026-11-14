"""Test tones folder for the `folder` extension (FT-597, part B).

Device scenarios search for "Flowtune — Test Tone Long/Short". The old path plays them via the template list
`contracts/fixtures/source_index.json`, where the title is bound to the file. The `folder` extension takes artist
and title from the file tags themselves — which means it needs a copy with these tags. Audio is not re-encoded (`-c copy`).

    python3 scripts/tones_folder.py <folder>
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "contracts" / "fixtures"


def build(target: Path) -> list[Path]:
    target.mkdir(parents=True, exist_ok=True)
    sources = json.loads((FIXTURES / "source_index.json").read_text())["sources"]
    made: list[Path] = []
    seen: set[tuple[str, str]] = set()
    for source in sources:
        tags = source.get("tags") or {}
        artist, title = tags.get("artist"), tags.get("title")
        if artist != "Flowtune" or not title or (artist, title) in seen:
            continue
        seen.add((artist, title))
        original = FIXTURES / "audio" / source["file_path"]
        copy = target / f"{artist} - {title}{original.suffix}"
        subprocess.run(
            ["ffmpeg", "-v", "error", "-y", "-i", str(original), "-map", "0:a", "-c", "copy",
             "-map_metadata", "-1", "-metadata", f"artist={artist}", "-metadata", f"title={title}", str(copy)],
            check=True,
        )  # fmt: skip
        made.append(copy)
    if not made:
        raise SystemExit("FAIL: no Flowtune tones in source_index.json")
    return made


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    for path in build(Path(sys.argv[1])):
        print(path.name)
