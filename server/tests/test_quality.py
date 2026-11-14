"""FT-636 (Р-A94, Р-A96, contract D2): "Prefer lossless" mode — source selection.

Currently the server selects release by confidence that it matches the song, ignoring FLAC or MP3. In
"Prefer lossless" mode, among releases with high confidence, lossless should go first —
if available. If not — it plays whatever is available: the mode prohibits nothing.

Guarded:
- mode does not promote a release with low confidence — "wrong song" is worse than MP3;
- vinyl rip in FLAC does not outrank clean MP3: needle noise is not "better quality";
- order within a group stays the same (standard FLAC before hi-res — as ordered by resolver);
- without mode or in `opus` mode order is untouched;
- "lossless" is read from filename, or if absent — from release title; when indicators conflict
  ("FLAC + MP3") — the answer is "unknown", and release is not promoted;
- badge format is taken from actual filename, not release title.

What tests do not prove: that server calls this function during source selection and passes `audio.format` in
Play response — that is lead wiring (B7); that a release named FLAC actually contains FLAC — that is
only visible after downloading, when the badge will show the truth (D2, item 2).
"""

from __future__ import annotations

import copy
from typing import Any

import pytest

from app.matching import CONFIDENCE_THRESHOLD
from app.quality import audio_format, lossless, prefer_order


def _c(
    name: str, confidence: float, title: str = "", file_path: str = "", **extra: Any
) -> dict[str, Any]:
    return {
        "id": name,
        "confidence": confidence,
        "title": title,
        "file_path": file_path,
        **extra,
    }


def _ids(items: list[dict[str, Any]]) -> list[str]:
    return [item["id"] for item in items]


# --- lossless or not --------------------------------------------------------


@pytest.mark.parametrize(
    "path",
    ["Album/01 - One.flac", "a/b/One.FLAC", "One.ape", "One.wv", "One.wav", "One.tta"],
)
def test_file_suffix_says_lossless(path: str) -> None:
    assert (
        lossless(_c("x", 0.9, title="Metallica - One MP3 320 kbps", file_path=path))
        is True
    )


@pytest.mark.parametrize(
    "path", ["01 - One.mp3", "One.MP3", "One.ogg", "One.opus", "One.aac"]
)
def test_file_suffix_says_lossy(path: str) -> None:
    assert (
        lossless(
            _c("x", 0.9, title="Metallica - Black Album FLAC lossless", file_path=path)
        )
        is False
    )


def test_m4a_can_be_either() -> None:
    assert lossless(_c("x", 0.9, title="Metallica - One", file_path="One.m4a")) is None


@pytest.mark.parametrize(
    "title",
    [
        "(Rock) Metallica - Black Album - 1991, FLAC (tracks+.cue), lossless",
        "Metallica - One [ALAC]",
        "Metallica - One (WavPack)",
        "Metallica — One, APE (image+.cue)",
        "Metallica - One lossless",
    ],
)
def test_release_title_says_lossless_when_there_is_no_file_name(title: str) -> None:
    assert lossless(_c("x", 0.9, title=title)) is True


@pytest.mark.parametrize(
    "title",
    [
        "Metallica - Black Album - 1991, MP3, 320 kbps",
        "Metallica - One (AAC 256kbps)",
        "Metallica - One [Opus]",
        "Metallica - One, 192 kbit/s",
        "Metallica - One (OGG Vorbis)",
    ],
)
def test_release_title_says_lossy(title: str) -> None:
    assert lossless(_c("x", 0.9, title=title)) is False


@pytest.mark.parametrize(
    "title",
    [
        "Metallica - One",
        "Metallica - Black Album (FLAC + MP3)",
        "Guano Apes - Open Your Eyes",
        "The Ape - Flaco",
        "Planet of the Apes OST",
        "",
    ],
)
def test_release_title_that_does_not_tell(title: str) -> None:
    assert lossless(_c("x", 0.9, title=title)) is None


def test_folder_name_is_not_a_suffix() -> None:
    # Folder is "Album.flac/", but file is MP3.
    assert (
        lossless(_c("x", 0.9, title="", file_path="Album.flac/01 - One.mp3")) is False
    )


def test_non_audio_suffix_falls_back_to_the_title() -> None:
    assert (
        lossless(
            _c("x", 0.9, title="Metallica - One FLAC", file_path="Metallica - One FLAC")
        )
        is True
    )
    assert (
        lossless(_c("x", 0.9, title="Metallica - One", file_path="release.zip")) is None
    )


def test_missing_fields_do_not_break() -> None:
    assert lossless({"confidence": 0.9}) is None
    assert lossless({"confidence": 0.9, "title": None, "file_path": None}) is None


# --- ordering ---------------------------------------------------------------

MP3 = _c("mp3", 0.95, title="Metallica - One MP3 320 kbps")
FLAC = _c("flac", 0.82, title="Metallica - One FLAC")
HIRES = _c("hires", 0.82, title="Metallica - One FLAC 24bit/96kHz")
VINYL = _c("vinyl", 0.90, title="Metallica - One [LP] FLAC")
UNSURE = _c("unsure", CONFIDENCE_THRESHOLD - 0.01, title="Metallica - Four Cellos FLAC")
UNKNOWN = _c("unknown", 0.80, title="Metallica - One")


def test_lossless_goes_first_among_the_confident() -> None:
    assert _ids(prefer_order([MP3, FLAC], "lossless")) == ["flac", "mp3"]


def test_without_the_mode_nothing_moves() -> None:
    ranked = [MP3, FLAC, HIRES, VINYL, UNSURE]
    assert _ids(prefer_order(ranked, None)) == _ids(ranked)
    assert _ids(prefer_order(ranked, "opus")) == _ids(ranked)
    assert _ids(prefer_order(ranked, "something")) == _ids(ranked)


def test_unsure_candidate_never_jumps_ahead() -> None:
    assert _ids(prefer_order([MP3, UNSURE], "lossless")) == ["mp3", "unsure"]
    assert _ids(prefer_order([UNSURE, MP3], "lossless")) == ["mp3", "unsure"]


def test_exactly_at_the_threshold_is_confident() -> None:
    edge = _c("edge", CONFIDENCE_THRESHOLD, title="Metallica - One FLAC")
    assert _ids(prefer_order([MP3, edge], "lossless")) == ["edge", "mp3"]


def test_vinyl_rip_does_not_overtake_clean_mp3() -> None:
    assert _ids(prefer_order([MP3, VINYL], "lossless")) == ["mp3", "vinyl"]
    marked = _c("tape", 0.9, title="Metallica - One FLAC", analog=True)
    assert _ids(prefer_order([MP3, marked], "lossless")) == ["mp3", "tape"]


def test_order_inside_a_group_stays() -> None:
    ranked = [MP3, UNKNOWN, FLAC, HIRES, VINYL, UNSURE]
    assert _ids(prefer_order(ranked, "lossless")) == [
        "flac",
        "hires",
        "mp3",
        "unknown",
        "vinyl",
        "unsure",
    ]
    assert _ids(prefer_order([HIRES, FLAC, MP3], "lossless")) == [
        "hires",
        "flac",
        "mp3",
    ]
    # Resolver order accounts for more than confidence; cannot re-sort by it.
    low = _c("low", 0.80, title="Metallica - One FLAC")
    high = _c("high", 0.95, title="Metallica - One FLAC")
    assert _ids(prefer_order([low, high, MP3], "lossless")) == ["low", "high", "mp3"]
    assert _ids(prefer_order([low, high, MP3, UNKNOWN], "lossless")) == [
        "low",
        "high",
        "mp3",
        "unknown",
    ]
    lower_mp3 = _c("lower", 0.76, title="Metallica - One MP3")
    assert _ids(prefer_order([lower_mp3, MP3, FLAC], "lossless")) == [
        "flac",
        "lower",
        "mp3",
    ]


def test_unknown_format_is_not_treated_as_lossless() -> None:
    assert _ids(prefer_order([MP3, UNKNOWN], "lossless")) == ["mp3", "unknown"]


def test_no_lossless_means_the_usual_order() -> None:
    other = _c("other", 0.8, title="Metallica - One (AAC 256kbps)")
    assert _ids(prefer_order([MP3, other, UNSURE], "lossless")) == [
        "mp3",
        "other",
        "unsure",
    ]


def test_input_is_not_changed_and_nothing_is_lost() -> None:
    ranked = [MP3, FLAC, UNSURE]
    before = copy.deepcopy(ranked)
    result = prefer_order(ranked, "lossless")
    assert ranked == before
    assert result is not ranked
    assert sorted(_ids(result)) == sorted(_ids(ranked))
    assert prefer_order([], "lossless") == []
    assert prefer_order(ranked, None) is not ranked


def test_file_name_beats_the_release_title_in_the_order() -> None:
    lying = _c("lying", 0.9, title="Metallica - One FLAC lossless", file_path="One.mp3")
    honest = _c("honest", 0.8, title="Metallica - One", file_path="One.flac")
    assert _ids(prefer_order([lying, honest], "lossless")) == ["honest", "lying"]


# --- badge format -----------------------------------------------------------


@pytest.mark.parametrize(
    ("name", "fmt"),
    [
        ("01 - One.flac", "flac"),
        ("One.MP3", "mp3"),
        ("abc/0.opus", "opus"),
        ("One.ogg", "ogg"),
        ("One.m4a", "m4a"),
        ("One.aac", "aac"),
        ("One.wav", "wav"),
    ],
)
def test_audio_format_is_the_real_file_suffix(name: str, fmt: str) -> None:
    assert audio_format(name) == fmt


@pytest.mark.parametrize(
    "name",
    [
        "",
        "One",
        "One.txt",
        "Metallica - One FLAC",
        "Album.flac/cover.jpg",
        "One.flac.part",
    ],
)
def test_audio_format_does_not_guess(name: str) -> None:
    assert audio_format(name) is None
