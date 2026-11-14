"""FT-839: phone scripts grant test-build permissions on a line flutter drive always prints."""

from pathlib import Path

import pytest
from not_in_slice import needs

pytestmark = needs("scripts/device_gapless.sh", "scripts/device_offline.sh")

SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"
DRIVER_LINE = "VMServiceFlutterDriver: Connecting"


@pytest.mark.parametrize(
    ("script", "ask"),
    [("device_gapless.sh", "GAP_ASK=grant"), ("device_offline.sh", "OFF_ASK=grant")],
)
def test_grant_does_not_depend_on_the_app_line_alone(script: str, ask: str) -> None:
    lines = (SCRIPTS / script).read_text(encoding="utf-8").splitlines()
    pattern = next(line for line in lines if ask in line and line.rstrip().endswith(")"))
    assert DRIVER_LINE in pattern, f"{script}: grant waits only for {ask}, which can be lost"
