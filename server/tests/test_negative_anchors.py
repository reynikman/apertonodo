"""FT-831: every spot a negative control breaks must still exist in the code.

A negative control (scripts/unlazy/*_negative.mjs, mutation_control.mjs) breaks one exact line and demands
a red test. When that line is rewritten, the control can no longer break anything — and nobody notices,
because these controls need a database or a phone and run in neither check.sh nor CI. On 13.10.2026 seven
of 47 spots were gone on main. `--anchors` is the cheap static part: no database, no tests, just "is every
`find` still in its file". check.sh runs it, so a stale spot turns the ordinary check red.
"""

import re
import shutil
import subprocess
from pathlib import Path

import pytest
from not_in_slice import needs

ROOT = Path(__file__).resolve().parents[2]
CONTROLS = sorted(
    path.name
    for path in (ROOT / "scripts" / "unlazy").glob("*.mjs")
    if path.name.endswith("_negative.mjs") or path.name == "mutation_control.mjs"
)

pytestmark = [
    pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed"),
    needs("scripts/unlazy", ".gitlab-ci.yml", "docker-compose.ci.yml"),
]


def anchors(script: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["node", f"scripts/unlazy/{script}", "--anchors"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=60,
        env={"PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"},
    )


def test_all_seven_controls_are_covered():
    assert len(CONTROLS) == 7, CONTROLS


@pytest.mark.parametrize("script", CONTROLS)
def test_every_anchor_is_found_without_a_database(script):
    result = anchors(script)
    assert result.returncode == 0, result.stdout + result.stderr
    found = re.search(r"anchors: (\d+), missing: 0\b", result.stdout)
    assert found, result.stdout
    assert int(found.group(1)) >= 3, result.stdout


def test_a_stale_anchor_turns_the_run_red(tmp_path):
    """The mode must look at the real file: a control whose file lost the line exits non-zero and names the case."""
    copy = tmp_path / "repo"
    (copy / "scripts").mkdir(parents=True)
    shutil.copytree(ROOT / "scripts" / "unlazy", copy / "scripts" / "unlazy")
    for part in (
        "server/app",
        "server/tests",
        "mobile/lib",
        "mobile/test",
        "extensions",
        "contracts",
    ):
        if (ROOT / part).exists():
            shutil.copytree(
                ROOT / part,
                copy / part,
                ignore=shutil.ignore_patterns(
                    ".venv", "__pycache__", "build", ".dart_tool", "node_modules"
                ),
            )
    for name in ("docker-compose.ci.yml", ".gitlab-ci.yml"):
        if (ROOT / name).exists():
            shutil.copy(ROOT / name, copy / name)
    target = copy / "server" / "app" / "search.py"
    target.write_text(target.read_text().replace("ORDER BY", "ORDER  BY"))
    result = subprocess.run(
        ["node", "scripts/unlazy/search_negative.mjs", "--anchors"],
        cwd=copy,
        capture_output=True,
        text=True,
        timeout=60,
        env={"PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"},
    )
    out = result.stdout + result.stderr
    assert result.returncode != 0, out
    assert re.search(r"anchors: \d+, missing: [1-9]", out), out
    assert "weight" in out


def test_check_sh_runs_the_anchor_check():
    text = (ROOT / "scripts" / "check.sh").read_text()
    assert "--anchors" in text
