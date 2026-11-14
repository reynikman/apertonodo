"""FT-906: scripts/extension.sh adds, removes and lists the five extensions; --dry-run never calls Docker."""

import shutil
import subprocess
from pathlib import Path

import pytest
from not_in_slice import needs

# The core slice has no extensions/: they are fetched at install time, so nothing here can run there.
pytestmark = needs("extensions/folder", "extensions/bittorrent", "extensions/rutracker")

ROOT = Path(__file__).resolve().parents[2]
NAMES = ("folder", "archive", "lyrics", "bittorrent", "rutracker")
BASE = "docker-compose.yml"


def _tree(tmp_path: Path) -> Path:
    (tmp_path / "scripts").mkdir(parents=True)
    shutil.copy(ROOT / "scripts" / "extension.sh", tmp_path / "scripts" / "extension.sh")
    shutil.copy(ROOT / ".env.example", tmp_path / ".env")
    shutil.copy(ROOT / BASE, tmp_path / BASE)
    return tmp_path


def _run(tree: Path, *args: str, src: Path | None = ROOT) -> subprocess.CompletedProcess:
    env = {"PATH": "/usr/bin:/bin", "HOME": str(tree)}  # no docker on PATH: a dry run must not need it
    if src is not None:
        env["APERTONO_EXTENSIONS_SRC"] = str(src)
    return subprocess.run(["bash", str(tree / "scripts" / "extension.sh"), "--dry-run", *args],
                          cwd=tree, capture_output=True, text=True, timeout=60, env=env)


def _env(tree: Path) -> dict[str, str]:
    pairs = (line.split("=", 1) for line in (tree / ".env").read_text().splitlines()
             if "=" in line and not line.lstrip().startswith("#"))
    return {k.strip(): v.strip() for k, v in pairs}


def _files(tree: Path) -> list[str]:
    return _env(tree)["COMPOSE_FILE"].split(":")


@pytest.mark.parametrize("name", NAMES)
def test_every_extension_has_a_compose_fragment(name: str) -> None:
    text = (ROOT / "extensions" / name / "compose.yml").read_text()
    assert text.startswith("services:") or "\nservices:" in text
    assert f"  {name}:" in text


def test_add_is_idempotent_and_writes_compose_file_and_extensions(tmp_path: Path) -> None:
    tree = _tree(tmp_path)
    for _ in range(2):
        out = _run(tree, "add", "folder")
        assert out.returncode == 0, out.stderr
    assert _files(tree) == [BASE, "extensions/folder/compose.yml"]
    assert _env(tree)["EXTENSIONS"] == "folder=http://folder:8080"
    assert (tree / "extensions/folder/compose.yml").exists()  # fetched from APERTONO_EXTENSIONS_SRC
    assert (tree / ".env").read_text().count("COMPOSE_FILE=") == 1

    assert _run(tree, "add", "archive").returncode == 0
    assert _env(tree)["EXTENSIONS"] == "folder=http://folder:8080,archive=http://archive:8080"
    assert _run(tree, "add", "lyrics").returncode == 0
    assert "extensions/lyrics/compose.yml" in _files(tree)
    assert "lyrics" not in _env(tree)["EXTENSIONS"]  # the core reaches lyrics by LYRICS_URL


def test_rutracker_brings_bittorrent_and_stays_out_of_extensions(tmp_path: Path) -> None:
    tree = _tree(tmp_path)
    out = _run(tree, "add", "rutracker")
    assert out.returncode == 0, out.stderr
    files = _files(tree)
    assert files.index("extensions/bittorrent/compose.yml") < files.index("extensions/rutracker/compose.yml")
    assert _env(tree)["EXTENSIONS"] == "bittorrent=http://bittorrent:8080"
    assert "release_index" in out.stdout  # NEXT_STEP of its extension.env
    refuse = _run(tree, "remove", "bittorrent")
    assert refuse.returncode != 0 and "rutracker" in refuse.stderr


def test_remove_and_list(tmp_path: Path) -> None:
    tree = _tree(tmp_path)
    _run(tree, "add", "folder")
    _run(tree, "add", "archive")
    assert _run(tree, "remove", "folder").returncode == 0
    assert _run(tree, "remove", "folder").returncode == 0
    assert _files(tree) == [BASE, "extensions/archive/compose.yml"]
    assert _env(tree)["EXTENSIONS"] == "archive=http://archive:8080"
    assert _run(tree, "list").stdout.splitlines() == ["archive on", "folder off"]  # on first, then fetched but off


def test_unknown_name_and_missing_source_fail_without_changing_env(tmp_path: Path) -> None:
    tree = _tree(tmp_path)
    before = (tree / ".env").read_bytes()
    assert _run(tree, "add", "Not_A_Name").returncode == 2
    assert _run(tree, "add", "nonsense").returncode != 0  # a well-formed name that nobody publishes
    bad = _run(tree, "add", "folder", src=tmp_path / "nowhere")
    assert bad.returncode != 0
    assert (tree / ".env").read_bytes() == before


def _fake_src(tmp_path: Path) -> Path:
    src = tmp_path / "src" / "extensions"
    for name, meta in (("a", ""), ("b", "REQUIRES=a\n"), ("c", "REQUIRES=a missing\n")):
        (src / name).mkdir(parents=True)
        (src / name / "compose.yml").write_text(f"services:\n  {name}:\n    image: x\n")
        (src / name / "extension.env").write_text(meta)
    return src.parent


def test_requires_are_added_first_and_removal_is_refused_while_needed(tmp_path: Path) -> None:
    tree, src = _tree(tmp_path / "t"), _fake_src(tmp_path)
    assert _run(tree, "add", "b", src=src).returncode == 0
    assert _files(tree) == [BASE, "extensions/a/compose.yml", "extensions/b/compose.yml"]
    refuse = _run(tree, "remove", "a", src=src)
    assert refuse.returncode != 0 and "b" in refuse.stderr


def test_failed_add_puts_env_back_exactly(tmp_path: Path) -> None:
    tree, src = _tree(tmp_path / "t"), _fake_src(tmp_path)
    before = (tree / ".env").read_bytes()
    out = _run(tree, "add", "c", src=src)  # a is added first, then the missing dependency fails
    assert out.returncode != 0
    assert "extensions/a/compose.yml" not in (tree / ".env").read_text()
    assert (tree / ".env").read_bytes() == before


def test_bad_name_from_downloaded_requires_is_refused_before_any_path_use(tmp_path: Path) -> None:
    tree, src = _tree(tmp_path / "t"), _fake_src(tmp_path)
    (src / "extensions" / "d").mkdir()
    (src / "extensions" / "d" / "compose.yml").write_text("services:\n  d:\n    image: x\n")
    (src / "extensions" / "d" / "extension.env").write_text("REQUIRES=../scripts\n")
    before = (tree / ".env").read_bytes()
    out = _run(tree, "add", "d", src=src)
    assert out.returncode != 0 and "bad extension name" in out.stderr
    assert (tree / "scripts" / "extension.sh").exists()  # nothing outside extensions/ was removed
    assert (tree / ".env").read_bytes() == before
