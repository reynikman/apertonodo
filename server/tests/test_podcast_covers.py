"""FT-859: podcast pictures come through our server (owner 14.10: "ок").

Guarded here:
- the first request downloads the picture once and keeps it as a file; the next one is served from disk;
- only https addresses are taken; a non-picture answer is not saved and not asked again for a day;
- without `IMAGE_DIR` there are no podcast pictures, and without the live network only saved ones;
- the picture address never reaches the log.

Not proven here: the address check of the downloader (tests/test_news_fetch*.py), shrinking with ffmpeg
(tests of app/images.py), the screens in the app.
"""

from __future__ import annotations

import logging
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app import podcast_covers
from app.podcast_covers import RETRY_S, install_podcast_covers

PICTURE = b"\x89PNG\r\n\x1a\n" + b"0" * 64
URL = "https://cdn.example.org/show/art.png"
PATH = "/v1/covers/podcast/image"


def _app(tmp_path: Path, answers: list[bytes | None], *, root: bool = True) -> tuple[TestClient, list[str]]:
    asked: list[str] = []

    async def fetch(url: str) -> bytes | None:
        asked.append(url)
        return answers.pop(0) if answers else None

    app = FastAPI()
    install_podcast_covers(app, env={"IMAGE_DIR": str(tmp_path)} if root else {}, live=True, fetch=fetch)
    return TestClient(app), asked


def test_first_request_downloads_once_then_disk_answers(tmp_path: Path) -> None:
    client, asked = _app(tmp_path, [PICTURE])
    first = client.get(PATH, params={"u": URL})
    assert first.status_code == 200
    assert first.headers["content-type"] == "image/png"
    assert first.content == PICTURE
    assert list(tmp_path.glob("podcasts/*/*.png"))
    again = client.get(PATH, params={"u": URL})
    assert again.status_code == 200 and again.content == PICTURE
    assert asked == [URL]


@pytest.mark.parametrize("bad", ["", "http://cdn.example.org/a.png", "ftp://x/a.png", "https://a b", "https://" + "a" * 2050])
def test_only_https_addresses_are_taken(tmp_path: Path, bad: str) -> None:
    client, asked = _app(tmp_path, [PICTURE])
    assert client.get(PATH, params={"u": bad}).status_code == 404
    assert asked == []


def test_not_a_picture_is_not_saved_and_not_asked_again_for_a_day(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    now = [1000.0]
    monkeypatch.setattr(podcast_covers.time, "monotonic", lambda: now[0])
    client, asked = _app(tmp_path, [b"<html>not a picture</html>", None, PICTURE])
    assert client.get(PATH, params={"u": URL}).status_code == 404
    assert client.get(PATH, params={"u": URL}).status_code == 404
    assert asked == [URL]
    assert not list(tmp_path.glob("podcasts/**/*.*"))
    now[0] += RETRY_S + 1
    assert client.get(PATH, params={"u": URL}).status_code == 404
    now[0] += RETRY_S + 1
    assert client.get(PATH, params={"u": URL}).status_code == 200
    assert asked == [URL, URL, URL]


def test_without_image_folder_there_are_no_podcast_pictures(tmp_path: Path) -> None:
    client, asked = _app(tmp_path, [PICTURE], root=False)
    assert client.get(PATH, params={"u": URL}).status_code == 404
    assert asked == []


def test_without_live_network_only_saved_pictures(tmp_path: Path) -> None:
    online, _ = _app(tmp_path, [PICTURE])
    assert online.get(PATH, params={"u": URL}).status_code == 200
    app = FastAPI()
    install_podcast_covers(app, env={"IMAGE_DIR": str(tmp_path)}, live=False)
    offline = TestClient(app)
    assert offline.get(PATH, params={"u": URL}).status_code == 200
    assert offline.get(PATH, params={"u": URL + "?other"}).status_code == 404


def test_picture_address_never_reaches_the_log(tmp_path: Path, caplog: pytest.LogCaptureFixture) -> None:
    caplog.set_level(logging.DEBUG, logger="apertonodo")
    client, _ = _app(tmp_path, [None])
    client.get(PATH, params={"u": URL})
    ours = [r.getMessage() for r in caplog.records if r.name.startswith("apertonodo")]
    assert not any("cdn.example.org" in line for line in ours)
