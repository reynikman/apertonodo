"""FT-838: the branch server runs on extensions by default — the core alone plays nothing."""

from pathlib import Path
from not_in_slice import needs

pytestmark = needs("scripts/with_branch_server.sh")

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "with_branch_server.sh"


def test_branch_server_starts_the_tones_extension_unless_switched_off() -> None:
    text = SCRIPT.read_text(encoding="utf-8")
    assert '"${FLOWTUNE_BRANCH_EXTENSIONS:-1}" != "0"' in text
    assert '"${FLOWTUNE_BRANCH_EXTENSIONS:-}" == "1"' not in text
