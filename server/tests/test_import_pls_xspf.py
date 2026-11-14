"""FT-625 (R-A47, R-A94): two more import formats — PLS and XSPF.

PLS is produced by Winamp, foobar2000, VLC, and internet radio; XSPF — VLC, Audacious, Strawberry. A user provides
such a file — and receives a playlist, just like from M3U. Here only parsing the file into rows is covered, each format in its own
module; they are plugged into common `parse_import` by lead during merge (rule R-A92: do not touch common files).

Rule R-A48 is the same: not a single understood line is lost, order is preserved.

What tests do not prove: that `parse_import` recognizes these files on its own — that is lead's line.
"""

from __future__ import annotations

import pytest

from app.import_formats import MAX_ROWS, ImportFormatError, ImportRow
from app.import_pls import parse_pls
from app.import_xspf import parse_xspf

# --- PLS -----------------------------------------------------------------------


def test_pls_titles_lengths_and_order_by_number() -> None:
    text = (
        "[playlist]\n"
        "File2=/music/Кино/Группа крови.flac\n"
        "Title2=Кино — Группа крови\n"
        "Length2=285\n"
        "File1=C:\\Music\\Linkin Park\\03 - Numb.mp3\n"
        "Title1=Linkin Park - Numb\n"
        "Length1=187\n"
        "NumberOfEntries=2\n"
        "Version=2\n"
    )

    playlist = parse_pls("Дорога", text)

    assert playlist.name == "Дорога"
    assert playlist.rows == [
        ImportRow("Linkin Park", "Numb", duration_ms=187_000),
        ImportRow("Кино", "Группа крови", duration_ms=285_000),
    ], "order is by entry number, not by file lines"


def test_pls_keys_any_case_spaces_and_crlf() -> None:
    text = (
        "[Playlist]\r\nfile1 = a.mp3\r\nTITLE1 = Nirvana - Lithium\r\nlength1 = 257\r\n"
    )

    assert parse_pls("x", text).rows == [
        ImportRow("Nirvana", "Lithium", duration_ms=257_000)
    ]


def test_pls_without_title_takes_file_name() -> None:
    text = (
        "[playlist]\n"
        "File1=/music/Metallica - One.mp3\n"
        "File2=D:\\rock\\07. Nirvana - Come as You Are.flac\n"
        "File3=/music/просто песня.ogg\n"
    )

    assert parse_pls("x", text).rows == [
        ImportRow("Metallica", "One"),
        ImportRow("Nirvana", "Come as You Are"),
        ImportRow("", "просто песня"),
    ]


def test_pls_unknown_length_and_radio_streams() -> None:
    text = (
        "[playlist]\n"
        "File1=http://radio.example/stream\n"
        "Title1=Radio Example\n"
        "Length1=-1\n"
        "File2=https://radio.example/other.mp3\n"
        "File3=a.mp3\n"
        "Title3=Muse - Uprising\n"
        "Length3=-1\n"
        "Length4=abc\n"
        "Title4=Muse - Starlight\n"
    )

    assert parse_pls("x", text).rows == [
        ImportRow("", "Radio Example"),
        ImportRow("Muse", "Uprising"),
        ImportRow("Muse", "Starlight"),
    ], "stream URL without title is not a song; length -1 and garbage mean 'unknown'"


def test_pls_title_without_dash_keeps_whole_line() -> None:
    text = "[playlist]\nTitle1=Bohemian Rhapsody\nTitle2=Jean-Michel Jarre - Oxygène\n"

    assert parse_pls("x", text).rows == [
        ImportRow("", "Bohemian Rhapsody"),
        ImportRow("Jean-Michel Jarre", "Oxygène"),
    ]


def test_pls_ignores_comments_and_foreign_lines() -> None:
    text = (
        "; made by hand\n[playlist]\n\nnonsense\nTitle1=A - B\n[other]\nTitle2=C - D\n"
    )

    assert parse_pls("x", text).rows == [ImportRow("A", "B"), ImportRow("C", "D")]


def test_pls_empty_is_an_empty_list_not_an_error() -> None:
    assert parse_pls("x", "[playlist]\nNumberOfEntries=0\n").rows == []


def test_pls_row_limit() -> None:
    text = "[playlist]\n" + "".join(
        f"Title{i}=A - T{i}\n" for i in range(1, MAX_ROWS + 2)
    )

    with pytest.raises(ImportFormatError) as error:
        parse_pls("x", text)
    assert error.value.code == "too_many_rows"


# --- XSPF ----------------------------------------------------------------------

XSPF = """<?xml version="1.0" encoding="UTF-8"?>
<playlist version="1" xmlns="http://xspf.org/ns/0/">
  <title>Вечер</title>
  <trackList>
    <track>
      <location>file:///music/Linkin%20Park/Numb.mp3</location>
      <creator>Linkin Park</creator>
      <title>Numb</title>
      <album>Meteora</album>
      <duration>187000</duration>
    </track>
    <track>
      <creator>Кино</creator>
      <title>Группа  крови</title>
    </track>
  </trackList>
</playlist>
"""


def test_xspf_tracks_in_order_with_album_and_duration() -> None:
    playlist = parse_xspf("файл", XSPF.encode())

    assert playlist.name == "Вечер", "name comes from the file itself"
    assert playlist.rows == [
        ImportRow("Linkin Park", "Numb", album="Meteora", duration_ms=187_000),
        ImportRow("Кино", "Группа  крови"),
    ]


def test_xspf_without_namespace_and_title_uses_file_name() -> None:
    data = b"<playlist><trackList><track><creator>A</creator><title>B</title></track></trackList></playlist>"

    playlist = parse_xspf("Мой список", data)

    assert playlist.name == "Мой список"
    assert playlist.rows == [ImportRow("A", "B")]


def test_xspf_track_without_title_takes_location_name() -> None:
    data = (
        '<playlist xmlns="http://xspf.org/ns/0/"><trackList>'
        "<track><location>file:///music/Metallica%20-%20One.mp3</location></track>"
        "<track><location>https://radio.example/stream</location></track>"
        "<track><creator>Muse</creator></track>"
        "<track><title>  </title><location>C:\\rock\\Nirvana - Lithium.flac</location></track>"
        "</trackList></playlist>"
    ).encode()

    assert parse_xspf("x", data).rows == [
        ImportRow("Metallica", "One"),
        ImportRow("Nirvana", "Lithium"),
    ], "network URL and entry without title is not a song"


def test_xspf_bad_duration_is_unknown() -> None:
    data = (
        "<playlist><trackList>"
        "<track><creator>A</creator><title>B</title><duration>-5</duration></track>"
        "<track><creator>C</creator><title>D</title><duration>soon</duration></track>"
        "</trackList></playlist>"
    ).encode()

    assert parse_xspf("x", data).rows == [ImportRow("A", "B"), ImportRow("C", "D")]


def test_xspf_utf16_and_bom() -> None:
    data = XSPF.replace('encoding="UTF-8"', 'encoding="UTF-16"').encode("utf-16")

    assert parse_xspf("x", data).rows[1] == ImportRow("Кино", "Группа  крови")
    assert parse_xspf("x", b"\xef\xbb\xbf" + XSPF.encode()).rows[0].title == "Numb"


@pytest.mark.parametrize(
    "data",
    [
        b"<playlist><trackList><track><title>A</title></trackList></playlist>",
        b"not xml at all",
        b"<html><body>hello</body></html>",
        b"",
    ],
)
def test_xspf_broken_or_foreign_file_is_refused(data: bytes) -> None:
    with pytest.raises(ImportFormatError) as error:
        parse_xspf("x", data)
    assert error.value.code == "bad_file"


def test_xspf_entities_are_refused_not_expanded() -> None:
    """The file is sent by a user: billion laughs and reading foreign files must not work."""
    bomb = (
        '<?xml version="1.0"?><!DOCTYPE lolz [<!ENTITY a "ha"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;">'
        '<!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;">]>'
        "<playlist><trackList><track><creator>X</creator><title>&c;</title></track></trackList></playlist>"
    ).encode()
    outside = (
        '<?xml version="1.0"?><!DOCTYPE p [<!ENTITY x SYSTEM "file:///etc/passwd">]>'
        "<playlist><trackList><track><creator>X</creator><title>&x;</title></track></trackList></playlist>"
    ).encode()

    for data in (bomb, outside):
        with pytest.raises(ImportFormatError) as error:
            parse_xspf("x", data)
        assert error.value.code == "bad_file"


def test_xspf_empty_list_and_row_limit() -> None:
    assert parse_xspf("x", b"<playlist><trackList/></playlist>").rows == []

    tracks = "".join(
        f"<track><creator>A</creator><title>T{i}</title></track>"
        for i in range(MAX_ROWS + 1)
    )
    with pytest.raises(ImportFormatError) as error:
        parse_xspf(
            "x", f"<playlist><trackList>{tracks}</trackList></playlist>".encode()
        )
    assert error.value.code == "too_many_rows"


def test_modules_do_not_touch_files_network_or_logs() -> None:
    """Like `import_formats.py`: in-memory parsing, no disk, network, or log (the file contains song titles)."""
    from pathlib import Path

    root = Path(__file__).resolve().parents[1] / "app"
    for name in ("import_pls.py", "import_xspf.py"):
        source = (root / name).read_text()
        for word in (
            "open(",
            "logging",
            "logger",
            "httpx",
            "urlopen",
            "socket",
            "print(",
        ):
            assert word not in source, f"{name}: {word}"
