"""FT-890 (P10): the public slice has no plan, CI files, phone and deploy scripts, nor third-party recordings.

A test that reads such a file is skipped by the absence of the file, with the reason named. In the working
repository every file exists, so nothing is skipped there (backend_tests.sh forbids skips outside the slice).
"""

from __future__ import annotations

from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]


def missing(*paths: str) -> list[str]:
    return [p for p in paths if not (ROOT / p).exists()]


def needs(*paths: str):  # type: ignore[no-untyped-def]
    """`pytestmark = needs("plan", "scripts/plan_lint.py")` or `@needs(...)` on one test."""
    gone = missing(*paths)
    return pytest.mark.skipif(bool(gone), reason="not in public slice: " + ", ".join(gone))


def skip_module(*paths: str) -> None:
    """For a module that reads the file while being imported: call before that line."""
    gone = missing(*paths)
    if gone:
        pytest.skip("not in public slice: " + ", ".join(gone), allow_module_level=True)
