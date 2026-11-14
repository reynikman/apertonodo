"""Quality is wired to Play (wiring batch 3a: FT-633, FT-636, FT-684).

The phone sends `prefer` mode: `opus` on metered network, `lossless` — "prefer
lossless". An unknown mode is not an error: old client does not break.

The order of sources under `lossless` mode was decided by the old core; now it is the
extension's job (it returns `find` in the desired order itself), the core has nothing to test it with.
There is no `audio` block (format badge) for audio from an extension — it was not there before cleanup either.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from fake_extension import running_extension
from fastapi.testclient import TestClient
from test_extension_asset import Disk, _core, _song, _tone


def _play(client: TestClient, song: dict[str, Any], **body: Any) -> dict[str, Any]:
    response = client.post("/v1/playback", json={"track_id": song["id"], **body})
    assert response.status_code == 200, response.text
    return response.json()


def test_unknown_mode_is_not_an_error(tmp_path: Path) -> None:
    song = _song()
    disk = Disk(_tone(tmp_path / "music" / "01.flac", song))
    with (
        running_extension(disk.app()) as url,
        TestClient(_core(url, song, tmp_path)) as client,
    ):
        for prefer in ("wav", 7, "LOSSLESS "):
            assert _play(client, song, prefer=prefer)["state"]
