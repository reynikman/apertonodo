"""FT-901: scripts/install.sh --dry-run makes .env with secrets and never touches an existing one."""

import os
import shutil
import stat
import subprocess
from pathlib import Path

from not_in_slice import needs

# The core slice has no extensions/: install fetches them, and the test has no network.
pytestmark = needs("extensions/folder")

ROOT = Path(__file__).resolve().parents[2]
SECRETS = ("MUSIC_API_KEY", "POSTGRES_PASSWORD", "APERTONO_ADMIN_PASSWORD")


def _install(tree: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["bash", str(tree / "scripts" / "install.sh"), "--dry-run"],
        cwd=tree, capture_output=True, text=True, timeout=60,
        env={**os.environ, "APERTONO_EXTENSIONS_SRC": str(ROOT)},  # no network in the test
    )


def _env(tree: Path) -> dict[str, str]:
    pairs = (line.split("=", 1) for line in (tree / ".env").read_text().splitlines()
             if "=" in line and not line.lstrip().startswith("#"))
    return {k.strip(): v.strip() for k, v in pairs}


def test_dry_run_creates_env_and_keeps_existing(tmp_path: Path) -> None:
    (tmp_path / "scripts").mkdir()
    shutil.copy(ROOT / "scripts" / "install.sh", tmp_path / "scripts" / "install.sh")
    shutil.copy(ROOT / "scripts" / "extension.sh", tmp_path / "scripts" / "extension.sh")
    shutil.copy(ROOT / ".env.example", tmp_path / ".env.example")
    shutil.copy(ROOT / "docker-compose.yml", tmp_path / "docker-compose.yml")

    first = _install(tmp_path)
    assert first.returncode == 0, first.stderr
    env = _env(tmp_path)
    values = [env.get(name, "") for name in SECRETS]
    assert all(len(v) >= 24 for v in values), values
    assert len(set(values)) == len(values)
    assert stat.S_IMODE(os.stat(tmp_path / ".env").st_mode) == 0o600
    assert env["APERTONO_ADMIN_PASSWORD"] in first.stdout  # the person must see the first login

    before = (tmp_path / ".env").read_bytes()
    second = _install(tmp_path)
    assert second.returncode == 0, second.stderr
    assert (tmp_path / ".env").read_bytes() == before
    assert "already exists" in second.stdout
    # A run cut short before the administrator existed is finished by running again (FT-901 second look).
    assert env["APERTONO_ADMIN_PASSWORD"] in second.stdout


def test_default_extensions_are_folder_archive_lyrics(tmp_path: Path) -> None:
    (tmp_path / "scripts").mkdir()
    for name in ("install.sh", "extension.sh"):
        shutil.copy(ROOT / "scripts" / name, tmp_path / "scripts" / name)
    shutil.copy(ROOT / ".env.example", tmp_path / ".env.example")
    shutil.copy(ROOT / "docker-compose.yml", tmp_path / "docker-compose.yml")
    assert _install(tmp_path).returncode == 0
    env = _env(tmp_path)
    assert env["COMPOSE_FILE"].split(":") == [
        "docker-compose.yml", "extensions/folder/compose.yml",
        "extensions/archive/compose.yml", "extensions/lyrics/compose.yml",
    ]
    assert env["EXTENSIONS"] == "folder=http://folder:8080,archive=http://archive:8080"
    before = (tmp_path / ".env").read_bytes()
    assert _install(tmp_path).returncode == 0
    assert (tmp_path / ".env").read_bytes() == before
