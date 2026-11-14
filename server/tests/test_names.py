"""FT-586 (P8, Р-A88): name normalization — core, not release index code.

`norm` and `first_artist` lived in `app/release_index.py` (dump and index robot), and were imported by
eleven core modules: catalog, search, library, import. After P8 `release_index` moves to
an extension, and core would not start without it. Contract:
- `app.names` provides `norm` and `first_artist` — byte-for-byte identical behavior (below — responses taken
  on `main` b300e28): `tracks_norm` and indexes on production are already built from these strings;
- core modules take them from `app.names`, not from `app.release_index`.
"""

from __future__ import annotations

import ast
from pathlib import Path

import pytest

APP = Path(__file__).resolve().parents[1] / "app"

# Not a single import from release_index: core module only needed normalization from there.
PURE_CORE = (
    "catalog_browse",
    "catalog_genres",
    "images",
    "import_match",
    "lastfm",
    "library",
    "local_search",
    "musicbrainz",
    "search",
)
# These still pull other things from release_index (will move in FT-592…FT-596), but no longer `norm` and `first_artist`.
MIXED = ("catalog", "catalog_api", "main")

SAMPLES = [
    ("Metallica — St. Anger (2003) [FLAC]", "metallica st anger 2003 flac", "metallica st anger 2003 flac"),
    ("Кино - Группа крови", "кино группа крови", "кино группа крови"),
    ("AC/DC  &  Friends", "ac dc and friends", "ac dc and friends"),
    ("Beyoncé feat. Jay-Z", "beyoncé feat jay z", "beyoncé"),
    ("ЁЛКА", "елка", "елка"),
    ("Guns N' Roses, Slash", "guns n roses slash", "guns n roses slash"),
    ("  ", "", ""),
]


@pytest.mark.parametrize(("raw", "normed", "first"), SAMPLES)
def test_names_keep_the_old_behaviour(raw: str, normed: str, first: str) -> None:
    from app.names import first_artist, norm

    assert norm(raw) == normed
    assert first_artist(raw) == first


def _imports_from_release_index(module: str) -> set[str]:
    tree = ast.parse((APP / f"{module}.py").read_text(encoding="utf-8"))
    names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom) and node.module in {"app.release_index", "release_index"}:
            names.update(alias.name for alias in node.names)
        if isinstance(node, ast.ImportFrom) and node.module == "app" and any(
            alias.name == "release_index" for alias in node.names
        ):
            names.add("*module*")
        if isinstance(node, ast.Import) and any(alias.name == "app.release_index" for alias in node.names):
            names.add("*module*")
    return names


@pytest.mark.parametrize("module", PURE_CORE)
def test_core_module_does_not_import_release_index(module: str) -> None:
    assert _imports_from_release_index(module) == set(), f"{module}.py imports index code"


@pytest.mark.parametrize("module", MIXED)
def test_mixed_module_takes_names_from_core(module: str) -> None:
    leaked = _imports_from_release_index(module) & {"norm", "first_artist", "*module*"}
    assert leaked == set(), f"{module}.py takes {sorted(leaked)} from release_index, not from app.names"
