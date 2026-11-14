"""FT-907 (P10): THIRD_PARTY_NOTICES.md must name every direct dependency.

The list drifted once (new packages added, a removed one left behind). This test reads the dependency
declarations (server `pyproject.toml`, each extension's own notices, `mobile/pubspec.yaml`) and fails on a missing name.
"""

from __future__ import annotations

import re
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
NOTICES = (ROOT / "THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8")
PYPROJECTS = [ROOT / "server" / "pyproject.toml"]


def _norm(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def _python_names(path: Path) -> set[str]:
    project = tomllib.loads(path.read_text(encoding="utf-8"))["project"]
    specs = list(project.get("dependencies", []))
    for group in project.get("optional-dependencies", {}).values():
        specs += group
    return {_norm(re.match(r"[A-Za-z0-9_.-]+", spec).group(0)) for spec in specs}  # type: ignore[union-attr]


def _pubspec_names() -> set[str]:
    names: set[str] = set()
    section = ""
    for line in (ROOT / "mobile" / "pubspec.yaml").read_text(encoding="utf-8").splitlines():
        if re.match(r"^\S", line):
            section = line.rstrip(":").strip()
            continue
        match = re.match(r"^  ([a-z_0-9]+):(.*)$", line)
        if match and section in ("dependencies", "dev_dependencies") and match.group(2).strip():
            names.add(_norm(match.group(1)))
    return names


def _documented() -> set[str]:
    return {_norm(token) for token in re.findall(r"[A-Za-z][A-Za-z0-9_.-]*", NOTICES)}


def test_python_dependencies_are_listed() -> None:
    documented = _documented()
    for path in PYPROJECTS:
        missing = sorted(name for name in _python_names(path) if name not in documented)
        assert not missing, f"{path.relative_to(ROOT)}: not in THIRD_PARTY_NOTICES.md: {missing}"


def test_extension_dependencies_are_listed_in_their_own_notices() -> None:
    for pyproject in sorted((ROOT / "extensions").glob("*/pyproject.toml")):
        name = pyproject.parent.name
        notices = pyproject.parent / "THIRD_PARTY_NOTICES.md"
        documented = {_norm(t) for t in re.findall(r"[A-Za-z][A-Za-z0-9_.-]*", notices.read_text(encoding="utf-8"))}
        missing = sorted(n for n in _python_names(pyproject) if n not in documented)
        assert not missing, f"extensions/{name}/THIRD_PARTY_NOTICES.md: missing {missing}"


def test_core_notices_do_not_list_extension_files_or_tinytag() -> None:
    assert "extensions/{" not in NOTICES
    assert "tinytag" not in NOTICES.lower()


def test_last_fm_is_listed_as_data() -> None:
    assert "Last.fm" in NOTICES


def test_mobile_dependencies_are_listed() -> None:
    names = _pubspec_names()
    assert {"just-audio", "http"} <= names  # the parser really sees the section
    missing = sorted(name for name in names if name not in _documented())
    assert not missing, f"mobile/pubspec.yaml: not in THIRD_PARTY_NOTICES.md: {missing}"


def test_removed_dependency_is_not_listed() -> None:
    assert "just_audio_background" not in NOTICES
