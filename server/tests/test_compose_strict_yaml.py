"""Compose files parse under the strict YAML of Docker Compose v2+ (go-yaml), not only PyYAML.

Rehearsal install 08.11: an unquoted value with ": " inside
(`MUSIC_API_KEY: ${MUSIC_API_KEY:?... required: run ...}`) made `docker compose` refuse
the file ("mapping values are not allowed in this context"), while PyYAML read it fine.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
PAIR = re.compile(r"^\s*(?:- )?[A-Za-z0-9_.-]+:\s+(?P<value>[^\s#].*)$")


@pytest.mark.parametrize("name", ["docker-compose.yml", "docker-compose.ci.yml"])
def test_no_unquoted_value_contains_colon_space(name: str) -> None:
    path = ROOT / name
    if not path.exists():
        pytest.skip(f"{name} not in this copy")
    bad = []
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        match = PAIR.match(line)
        if not match:
            continue
        value = match.group("value").split(" #", 1)[0]
        if value[0] in "\"'|>[{&*!":
            continue
        if ": " in value:
            bad.append(f"{name}:{number}")
    assert not bad, "quote these values (strict YAML reads ': ' as a new key): " + ", ".join(bad)
