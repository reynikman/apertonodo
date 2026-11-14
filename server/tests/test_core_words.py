"""FT-588 (P8, Р-A88): source words guard in core.

Р-A88: core Apertonodo contains neither sources, nor engine, nor words about them. `scripts/core_words.py` searches for them in core
paths and reports each hit as `path:line: word`. In P8 it initially only reports (exit 0), with `--strict` —
red on any match; strict mode is enabled in FT-596.

Contract:
- words — `magnet`, `torrent`, `tracker`, `info_hash`, `infohash`, case-insensitive and **inside identifiers**
  (`torrent_dir`, `TorrentEngine`, `magnet_for`, `rutracker`, `bittorrent` — count as hits as well);
- harmless Flutter package names (`leak_tracker` and its family) — not hits;
- core paths — `server/app`, `server/tests`, `mobile/lib`, `mobile/test`, `mobile/integration_test`,
  `mobile/pubspec.lock`, `contracts`, `Dockerfile`, `docker-compose.yml`; everything else (`plan/`, `docs/`,
  `extensions/`, `scripts/`) is not read by the guard;
- exceptions — `scripts/core_words.allow` file: line `path  # reason`, path — glob from root; excluded
  files produce no hits, but are counted in the summary ("исключено N") so exclusions are never silent;
- `--root DIR` — tree root (defaults to repository).
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GUARD = ROOT / "scripts" / "core_words.py"


def _run(root: Path, *flags: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(GUARD), "--root", str(root), *flags],
        capture_output=True,
        text=True,
    )


def _tree(tmp_path: Path, files: dict[str, str]) -> Path:
    for rel, text in files.items():
        path = tmp_path / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    return tmp_path


def test_names_every_hit_and_fails_only_when_strict(tmp_path: Path) -> None:
    root = _tree(
        tmp_path,
        {
            "server/app/play.py": "import os\n\ndef go():\n    return magnet_for(h)\n",
            "mobile/lib/screen.dart": "// fine\nfinal engine = TorrentEngine();\n",
            "contracts/x.json": '{"INFO_HASH": 1}\n',
        },
    )
    report = _run(root)
    assert report.returncode == 0, report.stdout + report.stderr
    out = report.stdout
    assert "server/app/play.py:4" in out
    assert "mobile/lib/screen.dart:2" in out
    assert "contracts/x.json:1" in out

    strict = _run(root, "--strict")
    assert strict.returncode == 1, "matches found, but --strict passed green"


def test_words_inside_names_count(tmp_path: Path) -> None:
    root = _tree(
        tmp_path,
        {
            "server/app/a.py": "torrent_dir = 1\n",
            "server/app/b.py": "API = 'rutracker'\n",
            "server/app/c.py": "# bittorrent engine\n",
            "server/app/d.py": "infohash = 2\n",
        },
    )
    out = _run(root).stdout
    for rel in ("server/app/a.py:1", "server/app/b.py:1", "server/app/c.py:1", "server/app/d.py:1"):
        assert rel in out, f"failed to catch {rel}"


def test_flutter_leak_tracker_is_not_a_hit(tmp_path: Path) -> None:
    root = _tree(
        tmp_path,
        {
            "mobile/pubspec.lock": "  leak_tracker:\n      name: ffi_leak_tracker\n  leak_tracker_flutter_testing:\n",
        },
    )
    result = _run(root, "--strict")
    assert result.returncode == 0, result.stdout


def test_paths_outside_the_core_are_not_read(tmp_path: Path) -> None:
    root = _tree(
        tmp_path,
        {
            "plan/p8.md": "magnet torrent tracker\n",
            "docs/live.md": "info_hash\n",
            "extensions/bittorrent/app.py": "torrent = 1\n",
            "scripts/ensure.sh": "rqbit torrent\n",
            "server/app/ok.py": "x = 1\n",
        },
    )
    result = _run(root, "--strict")
    assert result.returncode == 0, result.stdout


def test_allow_file_excludes_and_says_so(tmp_path: Path) -> None:
    root = _tree(
        tmp_path,
        {
            "mobile/test/privacy_ui_test.dart": "expect(find.text('torrent'), findsNothing);\n",
            "scripts/core_words.allow": "mobile/test/privacy_*_test.dart  # проверка, что слова нет на экране\n",
        },
    )
    result = _run(root, "--strict")
    assert result.returncode == 0, result.stdout
    assert "privacy_ui_test.dart:1" not in result.stdout
    assert "excluded 1" in result.stdout, "silent exclusion: summary does not mention 'excluded 1'"


def test_clean_tree_is_green(tmp_path: Path) -> None:
    root = _tree(tmp_path, {"server/app/main.py": "print('hello')\n", "Dockerfile": "FROM python\n"})
    result = _run(root, "--strict")
    assert result.returncode == 0, result.stdout


def test_real_repo_is_clean_in_strict_mode() -> None:
    """After FT-596 the real tree has no source words, except `core_words.allow` lines with reasons."""
    result = _run(ROOT, "--strict")
    assert result.returncode == 0, result.stdout + result.stderr
