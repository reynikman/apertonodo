"""Check guard (Р-A7, FT-448): executor does not change their card's check.

`scripts/check_guard.py` inspects commits of `wt/FT-NNN` branch on top of `main`.
Check files are named by the card — line "The check was written by the lead before work —
`path`". A commit touching them or the card itself must carry the lead's signature
`Lead-Check: FT-NNN`; without it — red, naming the file and commit.

Here the guard runs on toy repositories: honest branch is green,
every tampering is red. Otherwise a green guard proves nothing.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest
from not_in_slice import needs

pytestmark = needs("scripts/check_guard.py", "plan", "scripts/acceptance")

ROOT = Path(__file__).resolve().parents[2]
GUARD = ROOT / "scripts" / "check_guard.py"

CARD = "plan/cards/FT-900.md"
CHECK = "server/tests/test_thing.py"
CARD_TEXT = (
    "# FT-900 — игрушечная\n\nСтатус: выдана\n\n"
    "Проверку написал ведущий до работы — `server/tests/test_thing.py`.\n"
    "**Файл проверки не менять** (Р-A7).\n"
)


def _git(repo: Path, *args: str) -> str:
    out = subprocess.run(
        ["git", "-C", str(repo), *args],
        capture_output=True,
        text=True,
        check=True,
        env={
            "GIT_AUTHOR_NAME": "t",
            "GIT_AUTHOR_EMAIL": "t@example.invalid",
            "GIT_COMMITTER_NAME": "t",
            "GIT_COMMITTER_EMAIL": "t@example.invalid",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_SYSTEM": "/dev/null",
            "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
        },
    )
    return out.stdout.strip()


def _commit(repo: Path, message: str, files: dict[str, str]) -> str:
    for name, text in files.items():
        target = repo / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
    _git(repo, "add", "-A")
    _git(repo, "commit", "-q", "-m", message)
    return _git(repo, "rev-parse", "--short", "HEAD")


def _guard(repo: Path, branch: str = "wt/FT-900") -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(GUARD),
            "--repo",
            str(repo),
            "--branch",
            branch,
            "--base",
            "main",
        ],
        capture_output=True,
        text=True,
    )


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    """`main` with one code file and card branch with lead's commit."""
    _git(tmp_path, "init", "-q", "-b", "main")
    _commit(tmp_path, "start", {"server/app/thing.py": "x = 1\n"})
    _git(tmp_path, "checkout", "-q", "-b", "wt/FT-900")
    _commit(
        tmp_path,
        "FT-900: check first\n\nLead-Check: FT-900",
        {CARD: CARD_TEXT, CHECK: "def test_thing():\n    assert False\n"},
    )
    return tmp_path


def test_honest_branch_is_green(repo: Path) -> None:
    _commit(repo, "FT-900: the thing", {"server/app/thing.py": "x = 2\n"})
    out = _guard(repo)
    assert out.returncode == 0, out.stdout + out.stderr
    assert "FT-900" in out.stdout


def test_executor_edit_of_the_check_is_red(repo: Path) -> None:
    sha = _commit(
        repo,
        "FT-900: the thing",
        {"server/app/thing.py": "x = 2\n", CHECK: "def test_thing():\n    pass\n"},
    )
    out = _guard(repo)
    assert out.returncode == 1, out.stdout + out.stderr
    assert CHECK in out.stdout
    assert sha in out.stdout


def test_executor_edit_of_the_card_is_red(repo: Path) -> None:
    sha = _commit(
        repo,
        "FT-900: the thing",
        {CARD: CARD_TEXT.replace("test_thing.py", "test_other.py")},
    )
    out = _guard(repo)
    assert out.returncode == 1, out.stdout + out.stderr
    assert CARD in out.stdout
    assert sha in out.stdout


def test_deleting_the_check_is_red(repo: Path) -> None:
    _git(repo, "rm", "-q", CHECK)
    _git(repo, "commit", "-q", "-m", "FT-900: tidy up")
    out = _guard(repo)
    assert out.returncode == 1, out.stdout + out.stderr
    assert CHECK in out.stdout


def test_lead_may_fix_the_check_later(repo: Path) -> None:
    _commit(repo, "FT-900: the thing", {"server/app/thing.py": "x = 2\n"})
    _commit(
        repo,
        "FT-900: the check was wrong\n\nLead-Check: FT-900\nCo-Authored-By: x <x@example.invalid>",
        {CHECK: "def test_thing():\n    assert True\n"},
    )
    out = _guard(repo)
    assert out.returncode == 0, out.stdout + out.stderr


def test_signature_of_another_card_does_not_count(repo: Path) -> None:
    _commit(
        repo,
        "FT-900: the thing\n\nLead-Check: FT-901",
        {CHECK: "def test_thing():\n    pass\n"},
    )
    assert _guard(repo).returncode == 1


def test_signature_in_the_middle_of_a_line_does_not_count(repo: Path) -> None:
    _commit(
        repo,
        "FT-900: removed the Lead-Check: FT-900 line as asked",
        {CHECK: "def test_thing():\n    pass\n"},
    )
    assert _guard(repo).returncode == 1


def test_changes_that_came_from_main_are_not_the_executors(repo: Path) -> None:
    """Merging fresh main brings other people's test changes — that is not tampering."""
    _commit(repo, "FT-900: the thing", {"server/app/thing.py": "x = 2\n"})
    _git(repo, "checkout", "-q", "main")
    _commit(repo, "another card", {"server/tests/test_other.py": "# other\n"})
    _git(repo, "checkout", "-q", "wt/FT-900")
    _git(repo, "merge", "-q", "--no-edit", "main")
    out = _guard(repo)
    assert out.returncode == 0, out.stdout + out.stderr


def test_check_changed_inside_a_merge_is_red(repo: Path) -> None:
    """A check rewritten inside a merge commit is a rewrite too (a hole until 15.10)."""
    _git(repo, "checkout", "-q", "main")
    _commit(repo, "another card", {"server/app/other.py": "y = 1\n"})
    _git(repo, "checkout", "-q", "wt/FT-900")
    _git(repo, "merge", "-q", "--no-commit", "main")
    (repo / CHECK).write_text("def test_thing():\n    pass\n")
    _git(repo, "add", CHECK)
    _git(repo, "commit", "-q", "--no-edit")
    out = _guard(repo)
    assert out.returncode == 1, out.stdout + out.stderr
    assert CHECK in out.stdout


def test_every_named_check_is_guarded(repo: Path) -> None:
    """Two files in card line and test name after `::`."""
    text = CARD_TEXT.replace(
        "`server/tests/test_thing.py`",
        "`server/tests/test_thing.py::test_thing`, `mobile/test/thing_test.dart`",
    )
    _commit(
        repo,
        "FT-900: second check\n\nLead-Check: FT-900",
        {CARD: text, "mobile/test/thing_test.dart": "// red\n"},
    )
    assert _guard(repo).returncode == 0
    _commit(repo, "FT-900: the thing", {"mobile/test/thing_test.dart": "// green\n"})
    out = _guard(repo)
    assert out.returncode == 1, out.stdout + out.stderr
    assert "mobile/test/thing_test.dart" in out.stdout


def test_a_check_directory_guards_everything_under_it(repo: Path) -> None:
    text = CARD_TEXT.replace(
        "`server/tests/test_thing.py`", "`scripts/acceptance/cases/`"
    )
    _commit(
        repo,
        "FT-900: cases\n\nLead-Check: FT-900",
        {CARD: text, "scripts/acceptance/cases/FT-900.py": "# red\n"},
    )
    _commit(repo, "FT-900: the thing", {"scripts/acceptance/cases/FT-900.py": "# x\n"})
    out = _guard(repo)
    assert out.returncode == 1, out.stdout + out.stderr
    assert "scripts/acceptance/cases/FT-900.py" in out.stdout


def test_not_a_card_branch_is_left_alone(repo: Path) -> None:
    _commit(repo, "whatever", {CHECK: "def test_thing():\n    pass\n"})
    out = _guard(repo, branch="main")
    assert out.returncode == 0, out.stdout + out.stderr
    assert _guard(repo, branch="wt/P4-decisions").returncode == 0


def test_card_branch_with_a_suffix_is_the_same_card(repo: Path) -> None:
    _commit(repo, "FT-900: the thing", {CHECK: "def test_thing():\n    pass\n"})
    assert _guard(repo, branch="wt/FT-900-r1").returncode == 1
    assert _guard(repo, branch="wt/FT-900-fix").returncode == 1


def test_four_digit_card_is_a_card_too(tmp_path: Path) -> None:
    """After FT-999 the guard must not silently stop watching."""
    card = "plan/cards/FT-1000.md"
    _git(tmp_path, "init", "-q", "-b", "main")
    _commit(tmp_path, "start", {"server/app/thing.py": "x = 1\n"})
    _git(tmp_path, "checkout", "-q", "-b", "wt/FT-1000")
    _commit(
        tmp_path,
        "FT-1000: check first\n\nLead-Check: FT-1000",
        {card: CARD_TEXT.replace("FT-900", "FT-1000"), CHECK: "# red\n"},
    )
    _commit(tmp_path, "FT-1000: the thing", {CHECK: "# green\n"})
    assert _guard(tmp_path, branch="wt/FT-1000").returncode == 1


def test_old_card_without_a_file_is_left_alone(tmp_path: Path) -> None:
    """Old plan cards live in cards.yaml and do not name check in the card."""
    _git(tmp_path, "init", "-q", "-b", "main")
    _commit(tmp_path, "start", {"server/app/thing.py": "x = 1\n"})
    _git(tmp_path, "checkout", "-q", "-b", "wt/FT-123")
    _commit(tmp_path, "FT-123: work", {"server/tests/test_thing.py": "# x\n"})
    out = _guard(tmp_path, branch="wt/FT-123")
    assert out.returncode == 0, out.stdout + out.stderr


def test_missing_base_is_red_not_silently_green(repo: Path) -> None:
    """Shallow CI clone without `main` must not pass as "all clean"."""
    out = subprocess.run(
        [
            sys.executable,
            str(GUARD),
            "--repo",
            str(repo),
            "--branch",
            "wt/FT-900",
            "--base",
            "origin/no-such-branch",
        ],
        capture_output=True,
        text=True,
    )
    assert out.returncode not in (0, 1), out.stdout + out.stderr
