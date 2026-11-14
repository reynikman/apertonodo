"""FT-837: the whole chain core -> music extension -> source extension is checked.

Three switchover-day breakages were written, tested piece by piece and never
connected. Only a run of the real services together catches that class.
"""

from __future__ import annotations

from pathlib import Path
from not_in_slice import needs

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "chain_check.sh"
BREAKS = ("own-schema", "source-routes", "music-routes")


@needs("scripts/chain_check.sh")
def test_the_chain_check_exists_and_names_its_breaks() -> None:
    text = SCRIPT.read_text(encoding="utf-8")
    assert "--break" in text
    for name in BREAKS:
        assert name in text, name


def test_the_common_check_runs_the_chain() -> None:
    assert "chain_check.sh" in (ROOT / "scripts" / "check.sh").read_text(
        encoding="utf-8"
    )


@needs(".gitlab-ci.yml")
def test_ci_runs_the_chain() -> None:
    ci = (ROOT / ".gitlab-ci.yml").read_text(encoding="utf-8")
    backend = (ROOT / "scripts" / "backend_ci.sh").read_text(encoding="utf-8")
    assert "chain_check.sh" in ci + backend
