"""FT-760: a failed image reports its reason in the log — "Stop http 503", not just "Stop".

On 11.10 there were 573 log lines `image: cover failed: Stop` without a single reason: whether the proxy
failed or the cover art archive, had to be checked manually. The `Stop` text is safe — it contains
only the status code or exception name, no URL is placed there (`Images.get`). The text
of any other exception does not enter the log: it might contain a URL revealing what is currently
being viewed. Lead check — do not change (Р-A7).
"""

from __future__ import annotations

import logging
from pathlib import Path

import pytest

from app import images

SECRET = "https://coverartarchive.org/release-group/04f53329/front"


def _run(tmp_path: Path, monkeypatch: pytest.MonkeyPatch, exc: Exception) -> None:
    pictures = images.Images(tmp_path, "postgresql://unused")

    def explode(_client: object, _job: object) -> None:
        raise exc

    monkeypatch.setattr(pictures, "_one", explode)
    pictures.want(("cover", "04f53329", "Nirvana", "Nevermind"))
    pictures.queue.join()


@pytest.mark.parametrize("reason", ["http 503", "RemoteProtocolError", "ValueError"])
def test_stop_reason_is_in_the_log(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    caplog: pytest.LogCaptureFixture,
    reason: str,
) -> None:
    with caplog.at_level(logging.INFO, logger="apertonodo"):
        _run(tmp_path, monkeypatch, images.Stop(reason))
    assert f"image: cover failed: Stop {reason}" in caplog.text


def test_other_errors_keep_only_their_name(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    with caplog.at_level(logging.INFO, logger="apertonodo"):
        _run(tmp_path, monkeypatch, RuntimeError(f"bad answer from {SECRET}"))
    assert "image: cover failed: RuntimeError" in caplog.text
    assert SECRET not in caplog.text
    assert "Nirvana" not in caplog.text and "Nevermind" not in caplog.text
