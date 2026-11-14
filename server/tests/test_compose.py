"""An entrypoint without command resets the image CMD — Postgres will not start."""

from __future__ import annotations

from pathlib import Path
from not_in_slice import needs

pytestmark = needs("docker-compose.ci.yml")

ROOT = Path(__file__).resolve().parents[2]
COMPOSE_FILES = ("docker-compose.yml", "docker-compose.ci.yml")


def _service_blocks(text: str) -> dict[str, str]:
    lines = text.splitlines()
    in_services = False
    blocks: dict[str, list[str]] = {}
    current: str | None = None
    for line in lines:
        if line.startswith("services:"):
            in_services = True
            continue
        if in_services and line and not line.startswith(" ") and not line.startswith("\t"):
            break
        if in_services and line.startswith("  ") and not line.startswith("    ") and line.rstrip().endswith(":"):
            current = line.strip().rstrip(":")
            blocks[current] = []
            continue
        if current is not None:
            blocks[current].append(line)
    return {name: "\n".join(body) for name, body in blocks.items()}


def _has_key(block: str, key: str) -> bool:
    prefix = f"    {key}:"
    return any(line.startswith(prefix) for line in block.splitlines())


def test_entrypoint_has_command() -> None:
    missing: list[str] = []
    for name in COMPOSE_FILES:
        for service, block in _service_blocks((ROOT / name).read_text()).items():
            if _has_key(block, "entrypoint") and not _has_key(block, "command"):
                missing.append(f"{name}:{service}")
    assert missing == [], (
        "entrypoint without command resets the image CMD, Postgres will not start: "
        + ", ".join(missing)
    )


def _mem_bytes(value: str) -> int:
    units = {"k": 2**10, "m": 2**20, "g": 2**30}
    value = value.strip().strip("\"'").lower().rstrip("b")
    return int(value[:-1]) * units[value[-1]] if value[-1] in units else int(value)
