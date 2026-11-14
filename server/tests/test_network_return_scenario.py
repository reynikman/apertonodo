"""FT-782: phone scenario "network was lost and returned" (beta condition, Р-A85).

The scenario itself runs only on a physical phone via a button in MR. Here is the guard
ensuring it is structured like the others: a wrapper around `device_run.sh`, the network is cut
by the script, not the scenario, and the run must prove that the disconnect took place.
"""

from pathlib import Path
from not_in_slice import needs

pytestmark = needs("scripts/device_network.sh", "scripts/device_run.sh", "scripts/with_branch_server.sh", ".gitlab-ci.yml")

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "device_network.sh"
SCENARIO = ROOT / "mobile" / "integration_test" / "network_return_test.dart"
CI = ROOT / ".gitlab-ci.yml"
MUTATIONS = ROOT / "scripts" / "unlazy" / "mutation_control.mjs"


def _job(name: str) -> str:
    lines = CI.read_text(encoding="utf-8").splitlines()
    start = lines.index(f"{name}:")
    body = []
    for line in lines[start + 1 :]:
        if line and not line.startswith((" ", "#")):
            break
        body.append(line)
    return "\n".join(body)


def test_script_wraps_the_single_runner() -> None:
    text = SCRIPT.read_text(encoding="utf-8")
    # flutter drive flags live in device_run.sh as a single instance.
    assert "scripts/device_run.sh" in text
    assert "flutter drive" not in text


def test_script_cuts_and_restores_the_tunnel() -> None:
    text = SCRIPT.read_text(encoding="utf-8")
    assert "NET_ASK=offline" in text and "NET_ASK=online" in text
    assert "reverse --remove" in text
    # The tunnel is restored even on scenario failure, otherwise the next phone
    # run would proceed without a server.
    assert "trap" in text
    assert text.count("reverse tcp:") >= 1


def test_script_refuses_the_public_address() -> None:
    # Production address cannot be disconnected this way: run would be green without a break.
    assert "http://127.0.0.1:" in SCRIPT.read_text(encoding="utf-8")


def test_scenario_proves_the_break_and_the_return() -> None:
    text = SCENARIO.read_text(encoding="utf-8")
    assert "NET_ASK=offline" in text and "NET_ASK=online" in text
    # Without this marker a green run cannot be distinguished from a song entirely
    # stored in the buffer.
    assert "NET_BREAK_SEEN" in text
    assert "NET_RESUMED" in text
    assert "Test Tone Long" in text


def test_ci_has_a_manual_phone_job() -> None:
    job = _job("device-network")
    assert "resource_group: flowtune-phone" in job
    assert "scripts/with_branch_server.sh" in job and "scripts/device_network.sh" in job
    assert '$CI_PIPELINE_SOURCE == "schedule"' in job
    assert "when: manual" in job


def test_mutation_control_knows_the_case() -> None:
    assert "network-return" in MUTATIONS.read_text(encoding="utf-8")
