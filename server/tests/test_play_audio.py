"""FT-684: Play response `audio` block and quality mode from request (Contract D2)."""

from __future__ import annotations

import inspect
import json
import math

import pytest

from app import play_audio
from app.play_audio import MAX_GAIN_DB, PREFER_MODES, audio_block, normalize_prefer


def test_constants() -> None:
    assert PREFER_MODES == ("opus", "lossless")
    assert MAX_GAIN_DB == 60.0


@pytest.mark.parametrize(
    ("raw", "mode"),
    [
        ("opus", "opus"),
        ("lossless", "lossless"),
        ("LOSSLESS", "lossless"),
        ("  Opus \n", "opus"),
        ("", None),
        ("   ", None),
        ("flac", None),
        ("lossless!", None),
        ("opus lossless", None),
        (None, None),
        (1, None),
        (True, None),
        (b"opus", None),
        (["opus"], None),
        ({"prefer": "opus"}, None),
    ],
)
def test_prefer(raw: object, mode: str | None) -> None:
    assert normalize_prefer(raw) == mode


@pytest.mark.parametrize(
    ("name", "fmt"),
    [
        ("One.flac", "flac"),
        ("Album/CD 1/02 Two.MP3", "mp3"),
        ("a\\b\\three.Opus", "opus"),
        ("  four.m4a  ", "m4a"),
        ("five.ogg", "ogg"),
        ("six.aac", "aac"),
        ("seven.wav", "wav"),
    ],
)
def test_format_comes_from_the_real_file_name(name: str, fmt: str) -> None:
    assert audio_block(name) == {"format": fmt}


@pytest.mark.parametrize(
    "name",
    [
        "",
        "   ",
        "One.flac.part",
        "Album FLAC 2019",
        "folder.flac/",
        "cover.jpg",
        "noext",
        None,
        5,
        b"a.flac",
        ["a.flac"],
    ],
)
def test_unknown_format_gives_no_block(name: object) -> None:
    assert audio_block(name) is None
    assert audio_block(name, gain_db=-3.0) is None


@pytest.mark.parametrize(
    ("gain", "sent"),
    [
        (-3.0, -3.0),
        (0, 0.0),
        (0.0, 0.0),
        (-7, -7.0),
        (2.5, 2.5),
        (-3.14159, -3.14),
        (-3.145001, -3.15),
        (60, 60.0),
        (-60.0, -60.0),
    ],
)
def test_gain_is_sent_rounded(gain: float, sent: float) -> None:
    block = audio_block("One.flac", gain_db=gain)
    assert block == {"format": "flac", "gain_db": sent}
    assert type(block["gain_db"]) is float


@pytest.mark.parametrize(
    "gain",
    [
        None,
        math.nan,
        math.inf,
        -math.inf,
        True,
        False,
        "-3",
        b"-3",
        [-3.0],
        60.01,
        -60.01,
        1e308,
    ],
)
def test_bad_gain_is_left_out(gain: object) -> None:
    assert audio_block("One.flac", gain_db=gain) == {"format": "flac"}


def test_block_is_plain_json() -> None:
    block = audio_block("One.flac", gain_db=-4.004)
    assert json.loads(json.dumps(block)) == {"format": "flac", "gain_db": -4.0}
    assert list(block) == ["format", "gain_db"]


def test_each_call_gives_its_own_block() -> None:
    first = audio_block("One.flac")
    first["gain_db"] = 1.0
    assert audio_block("One.flac") == {"format": "flac"}


def test_gain_is_keyword_only() -> None:
    with pytest.raises(TypeError):
        audio_block("One.flac", -3.0)  # type: ignore[misc]


def test_module_is_pure() -> None:
    source = inspect.getsource(play_audio)
    for word in ("logging", "print(", "asyncpg", "httpx", "open(", "os."):
        assert word not in source


class _Says:
    def __init__(self, text: str) -> None:
        self._text = text

    def __str__(self) -> str:
        return self._text


def test_only_real_strings_are_read() -> None:
    assert normalize_prefer(_Says("opus")) is None
    assert audio_block(_Says("One.flac")) is None
