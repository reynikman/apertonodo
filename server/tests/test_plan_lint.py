"""`plan/` lint (Р-A1, Р-A9): accepted decision without card or test is red.

`scripts/plan_lint.py` reads `plan/decisions/*.md`, `plan/cards/*.md`,
`plan/cards.yaml` and `plan/STATUS.md`. Here it runs on the real
`plan/` (must be green) and on copies with injected failures — each
must produce red and name the file. Otherwise green lint proves nothing.
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path

import pytest
from not_in_slice import needs

pytestmark = needs("plan", "scripts/plan_lint.py")

ROOT = Path(__file__).resolve().parents[2]
LINT = ROOT / "scripts" / "plan_lint.py"


def _run(plan: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(LINT), "--plan", str(plan), "--repo", str(ROOT)],
        capture_output=True,
        text=True,
    )


def _edit(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    assert old in text, f"mutation did not find {old!r} in {path.name} — test is stale"
    path.write_text(text.replace(old, new, 1))


def _field(path: Path, key: str, value: str) -> None:
    text = path.read_text()
    new, n = re.subn(
        rf"^{key}: .*$", f"{key}: {value}", text, count=1, flags=re.MULTILINE
    )
    assert n == 1, f"{path.name} has no {key} field"
    path.write_text(new)


def _decision(plan: Path, number: int) -> Path:
    (found,) = (plan / "decisions").glob(f"A{number:02d}-*.md")
    return found


def test_real_plan_is_clean() -> None:
    out = _run(ROOT / "plan")
    assert out.returncode == 0, out.stdout + out.stderr


BROKEN: dict[str, tuple[Callable[[Path], None], str]] = {
    "accepted-without-card-or-test": (
        lambda p: _field(_decision(p, 1), "proof", "[plan/README.md]"),
        "A01-",
    ),
    "proof-card-missing": (
        lambda p: _field(_decision(p, 10), "proof", "[FT-999]"),
        "FT-999",
    ),
    "proof-path-missing": (
        lambda p: _field(_decision(p, 21), "proof", "[docs/no-such-file.md]"),
        "docs/no-such-file.md",
    ),
    "unknown-decision-status": (
        lambda p: _field(_decision(p, 13), "status", "maybe"),
        "A13-",
    ),
    "policy-without-proof": (
        lambda p: _field(_decision(p, 6), "proof", "[]"),
        "A06-",
    ),
    "id-does-not-match-file": (
        lambda p: _field(_decision(p, 5), "id", "Р-A6"),
        "A05-",
    ),
    "card-without-check-section": (
        lambda p: _edit(
            p / "cards" / "FT-443.md", "## Проверка", "## Как-нибудь проверим"
        ),
        "FT-443",
    ),
    "card-without-volume-section": (
        lambda p: _edit(p / "cards" / "FT-446.md", "## Объём", "## Размеры"),
        "FT-446",
    ),
    "card-unknown-status": (
        lambda p: _field(p / "cards" / "FT-446.md", "Статус", "готово"),
        "FT-446",
    ),
    # "writes" instead of "wrote" — check_guard cannot see test files (FT-571…FT-581).
    "card-check-line-the-guard-cannot-read": (
        lambda p: _edit(
            p / "cards" / "FT-571.md",
            "Проверку написал ведущий",
            "Проверку пишет ведущий",
        ),
        "FT-571",
    ),
    # Receipt without minutes and returns — nothing to count executor work by (FT-565…FT-570).
    "accepted-card-with-a-loose-receipt": (
        lambda p: (p / "cards" / "FT-586.md").write_text(
            (p / "cards" / "TEMPLATE.md").read_text()
            .replace("# FT-NNN —", "# FT-586 —", 1)
            .replace("Статус: черновик", "Статус: принята", 1)
            + "\n## Приёмка\n\nКвитанция: check.sh exit 0 на ветке.\n"
        ),
        "FT-586",
    ),
    "card-title-does-not-match-file": (
        lambda p: _edit(p / "cards" / "FT-440.md", "# FT-440 —", "# FT-441 —"),
        "FT-440",
    ),
    "status-without-date": (
        lambda p: _edit(p / "STATUS.md", "Обновлено: ", "Когда-то: "),
        "STATUS.md",
    ),
}


@pytest.mark.parametrize("case", sorted(BROKEN))
def test_broken_plan_is_red(case: str, tmp_path: Path) -> None:
    plan = tmp_path / "plan"
    shutil.copytree(ROOT / "plan", plan)
    breaker, named = BROKEN[case]
    breaker(plan)
    out = _run(plan)
    assert out.returncode == 1, (
        f"{case}: lint did not catch mutation\n{out.stdout}{out.stderr}"
    )
    assert named in out.stdout + out.stderr, (
        f"{case}: lint did not name {named}\n{out.stdout}{out.stderr}"
    )


GREEN: dict[str, Callable[[Path], None]] = {
    # Old plan card is from cards.yaml, not just from cards/.
    "proof-card-from-cards-yaml": lambda p: _field(
        _decision(p, 25), "proof", "[FT-034]"
    ),
    # Test instead of card is also backing for an accepted decision.
    "accepted-with-test": lambda p: (
        _field(_decision(p, 4), "status", "accepted"),
        _field(_decision(p, 4), "proof", "[server/tests/test_local_search.py]"),
    ),
    # Card draft can be incomplete: check is written before dispatch.
    "accepted-card-with-a-strict-receipt": lambda p: (p / "cards" / "FT-586.md").write_text(
        (p / "cards" / "TEMPLATE.md").read_text()
        .replace("# FT-NNN —", "# FT-586 —", 1)
        .replace("Статус: черновик", "Статус: принята", 1)
        + "\n## Приёмка\n\nКвитанция: DeepSeek, deepseek-v4.1-flash, 25 мин, возвратов 0, правок ведущего 1.\n"
    ),
    "draft-card-may-be-short": lambda p: (p / "cards" / "FT-460.md").write_text(
        "# FT-460 — черновик\n\nСтатус: черновик\n\n## Зачем\nПотом.\n"
    ),
}


@pytest.mark.parametrize("case", sorted(GREEN))
def test_allowed_plan_is_green(case: str, tmp_path: Path) -> None:
    plan = tmp_path / "plan"
    shutil.copytree(ROOT / "plan", plan)
    GREEN[case](plan)
    out = _run(plan)
    assert out.returncode == 0, f"{case}\n{out.stdout}{out.stderr}"


def test_lint_runs_in_ci_and_check_sh() -> None:
    assert "plan_lint.py" in (ROOT / ".gitlab-ci.yml").read_text()
    assert "plan_lint.py" in (ROOT / "scripts" / "check.sh").read_text()
