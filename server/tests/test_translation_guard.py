"""The translation guard (P9, wave B) lets a branch change words and nothing else."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path
from not_in_slice import needs

pytestmark = needs("scripts/translation_guard.py", "plan")

ROOT = Path(__file__).resolve().parents[2]
GUARD = ROOT / "scripts" / "translation_guard.py"

CODE = '''"""Считает песни."""

def count(items):
    # пустой список — ноль
    if not items:
        raise ValueError("список пуст")
    return len(items)  # сколько всего
'''
WORDS = '"""Слова-шумы."""\n\n# русские слова из названий раздач\nSTOP = {"сборник"}\n'
SHELL = '#!/bin/bash\n# Проверка сервера\necho "готово"\nexit 0\n'


def _git(repo: Path, *args: str) -> None:
    subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True)


def _repo(tmp_path: Path) -> Path:
    repo = tmp_path / "repo"
    (repo / "app").mkdir(parents=True)
    (repo / "other").mkdir()
    (repo / "scripts").mkdir()
    (repo / "app" / "count.py").write_text(CODE)
    (repo / "app" / "run.sh").write_text(SHELL)
    (repo / "app" / "words.py").write_text(WORDS)
    (repo / "other" / "x.py").write_text("# чужое\nX = 1\n")
    (repo / "scripts" / "translation_guard.keep").write_text("# data\napp/words.py\n")
    _git(repo, "init", "-q", "-b", "main")
    _git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "add", "-A")
    _git(
        repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "base"
    )
    _git(repo, "checkout", "-q", "-b", "work")
    return repo


def _run(repo: Path, *extra: str) -> subprocess.CompletedProcess[str]:
    _git(
        repo,
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@t",
        "commit",
        "-q",
        "-a",
        "-m",
        "work",
    )
    return subprocess.run(
        [sys.executable, str(GUARD), "--root", str(repo), "--base", "main", *extra, "app"],
        capture_output=True, text=True,
    )  # fmt: skip


def test_translated_comments_and_messages_pass(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    (repo / "app" / "count.py").write_text(
        CODE.replace("Считает песни.", "Counts songs.")
        .replace("# пустой список — ноль", "# an empty list\n    # means zero")
        .replace("список пуст", "the list is empty")
        .replace("# сколько всего", "# how many")
    )
    (repo / "app" / "run.sh").write_text(
        SHELL.replace("Проверка сервера", "Server check").replace("готово", "done")
    )
    result = _run(repo, "--max", "0")
    assert result.returncode == 0, result.stdout
    assert "Russian lines left in the zone: 0" in result.stdout


def test_changed_python_code_fails(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    (repo / "app" / "count.py").write_text(
        CODE.replace("return len(items)", "return len(items) + 1")
    )
    result = _run(repo)
    assert result.returncode == 1
    assert "app/count.py: code changed" in result.stdout


def test_changed_shell_line_without_russian_fails(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    (repo / "app" / "run.sh").write_text(SHELL.replace("exit 0", "exit 1"))
    result = _run(repo)
    assert result.returncode == 1
    assert "app/run.sh: line 4 had no Russian text" in result.stdout


def test_added_shell_line_fails(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    (repo / "app" / "run.sh").write_text(SHELL + "rm -rf data\n")
    result = _run(repo)
    assert result.returncode == 1
    assert "replaces nothing Russian" in result.stdout


def test_file_outside_the_zone_fails(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    (repo / "other" / "x.py").write_text("# someone else's\nX = 1\n")
    result = _run(repo)
    assert result.returncode == 1
    assert "other/x.py: outside the card's zone" in result.stdout


def test_the_card_file_is_not_the_guards_business(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    (repo / "plan" / "cards").mkdir(parents=True)
    (repo / "plan" / "cards" / "FT-1.md").write_text("# карточка\n")
    _git(repo, "add", "-A")
    assert _run(repo).returncode == 0


def test_search_data_must_stay_russian(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    (repo / "app" / "words.py").write_text('STOP = {"collection"}\n')
    result = _run(repo)
    assert result.returncode == 1
    assert "app/words.py: on the keep list" in result.stdout


def test_comments_of_search_data_may_be_translated(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    (repo / "app" / "words.py").write_text(
        '"""Noise words."""\n\n# Russian words from release titles\nSTOP = {"сборник"}\n'
    )
    assert _run(repo).returncode == 0


def test_search_data_string_never_changes_with_its_comment(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    (repo / "app" / "words.py").write_text(
        '"""Noise words."""\n\n# Russian words from release titles\nSTOP = {"сборники"}\n'
    )
    result = _run(repo)
    assert result.returncode == 1
    assert "app/words.py: on the keep list" in result.stdout


def test_leftover_russian_fails_only_over_the_limit(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    (repo / "app" / "run.sh").write_text(SHELL.replace("готово", "done"))
    assert _run(repo, "--max", "5").returncode == 0
    (repo / "app" / "run.sh").write_text(SHELL.replace("готово", "done"))
    result = subprocess.run(
        [sys.executable, str(GUARD), "--root", str(repo), "--base", "main", "--max", "0", "app"],
        capture_output=True, text=True,
    )  # fmt: skip
    assert result.returncode == 1
    assert "lines with Cyrillic left" in result.stdout


def test_fstring_text_may_change_but_not_its_expression(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    path = repo / "app" / "count.py"
    path.write_text(CODE + 'def say(n):\n    return f"песен: {n}"\n')
    _git(
        repo,
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@t",
        "commit",
        "-q",
        "-a",
        "-m",
        "more",
    )
    _git(repo, "branch", "-f", "main", "HEAD")
    path.write_text(CODE + 'def say(n):\n    return f"songs: {n}"\n')
    assert _run(repo).returncode == 0
    path.write_text(CODE + 'def say(n):\n    return f"songs: {n + 1}"\n')
    assert _run(repo).returncode == 1
