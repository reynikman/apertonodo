from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_mit_license_and_third_party_notices_exist() -> None:
    license_text = (ROOT / "LICENSE").read_text()
    assert "MIT License" in license_text
    notices = (ROOT / "THIRD_PARTY_NOTICES.md").read_text()
    assert "Apache-2.0" in notices
    apache = (ROOT / "third_party" / "licenses" / "Apache-2.0.txt").read_text()
    assert "Apache License" in apache
    assert "Version 2.0" in apache
    assert "Onest" in notices
    assert "Plus Jakarta" not in notices
    assert "SIL Open Font License" in (ROOT / "mobile" / "fonts" / "OFL-Onest.txt").read_text()
