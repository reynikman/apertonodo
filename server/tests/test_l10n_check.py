"""FT-600: Russian strings guard in mobile app code (`scripts/l10n_check.py`, Р-A84).

Prior to FT-606 the guard is a report: it prints how many lines with Russian letters remain in `mobile/lib` and where, and
exits 0. With `--strict` — exit 1 while any remain. Generated localization code (`lib/l10n/`)
and comments are not counted: comments are translated by wave B.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CHECK = ROOT / "scripts" / "l10n_check.py"


def _run(lib: Path, *flags: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(CHECK), "--lib", str(lib), *flags], capture_output=True, text=True, timeout=60
    )


def _lib(tmp_path: Path, files: dict[str, str]) -> Path:
    for name, text in files.items():
        path = tmp_path / "lib" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    return tmp_path / "lib"


def test_counts_russian_literals_and_names_files(tmp_path: Path) -> None:
    lib = _lib(
        tmp_path,
        {
            "screens/a.dart": "Text('Привет');\nText(\"Ещё\");\nText('Hello');\n",
            "screens/b.dart": "Text('Fine');\n",
        },
    )
    result = _run(lib)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "screens/a.dart: 2" in result.stdout
    assert "screens/b.dart" not in result.stdout
    assert result.stdout.strip().splitlines()[-1] == "Russian lines in code: 2"


def test_comments_and_generated_code_are_not_counted(tmp_path: Path) -> None:
    lib = _lib(
        tmp_path,
        {
            "screens/a.dart": "// Комментарий 'в кавычках'\n/// Док 'тоже'\nText('Hello'); // хвост 'тут'\n",
            "l10n/app_localizations_ru.dart": "String get next => 'Далее';\n",
        },
    )
    result = _run(lib, "--strict")
    assert result.returncode == 0, result.stdout + result.stderr
    assert result.stdout.strip().splitlines()[-1] == "Russian lines in code: 0"


def test_strict_is_red_while_any_left(tmp_path: Path) -> None:
    lib = _lib(tmp_path, {"main.dart": "Text('Привет');\n"})
    assert _run(lib).returncode == 0
    strict = _run(lib, "--strict")
    assert strict.returncode == 1, strict.stdout
    assert "main.dart: 1" in strict.stdout


def test_real_app_report_runs() -> None:
    result = _run(ROOT / "mobile" / "lib")
    assert result.returncode == 0, result.stdout + result.stderr
    assert result.stdout.strip().splitlines()[-1].startswith("Russian lines in code: ")
