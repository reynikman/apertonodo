"""Parsing import files: four formats before beta (R-A47, FT-492).

A user migrates to us from Spotify (Exportify), Apple Music (library XML),
Navidrome and media players (M3U), or any service via an intermediary (text). Parsing is
only file -> rows; catalog lookup and database are subsequent steps of P5. The key
rule R-A48: not a single understood line is lost and order is preserved.
"""

from __future__ import annotations

import io
import plistlib
import zipfile

import pytest

from app.import_formats import (
    MAX_BYTES,
    MAX_ROWS,
    ImportFormatError,
    ImportRow,
    parse_import,
)

EXPORTIFY_HEADER = (
    '"Track URI","Track Name","Artist URI(s)","Artist Name(s)","Album URI","Album Name",'
    '"Album Artist URI(s)","Album Artist Name(s)","Album Release Date","Album Image URL",'
    '"Disc Number","Track Number","Track Duration (ms)","Track Preview URL","Explicit",'
    '"Popularity","ISRC","Added By","Added At"'
)


def exportify_row(title: str, artists: str, album: str, ms: int, isrc: str) -> str:
    cells = [
        "spotify:track:x",
        title,
        "spotify:artist:x",
        artists,
        "spotify:album:x",
        album,
        "spotify:artist:x",
        artists,
        "2003-03-25",
        "https://i.scdn.co/image/x",
        "1",
        "1",
        str(ms),
        "",
        "false",
        "70",
        isrc,
        "",
        "2024-01-01T00:00:00Z",
    ]
    return ",".join('"' + cell.replace('"', '""') + '"' for cell in cells)


def exportify(*rows: str) -> bytes:
    return ("\n".join([EXPORTIFY_HEADER, *rows]) + "\n").encode("utf-8")


# --- text "artist - track" ---------------------------------------------------


def test_text_lines_in_order_with_any_dash() -> None:
    data = "Linkin Park — Numb\nКино – Группа крови\nNirvana - Lithium\n".encode()

    [playlist] = parse_import("Мой список.txt", data)

    assert playlist.name == "Мой список"
    assert playlist.rows == [
        ImportRow(artist="Linkin Park", title="Numb"),
        ImportRow(artist="Кино", title="Группа крови"),
        ImportRow(artist="Nirvana", title="Lithium"),
    ]


def test_text_splits_on_first_spaced_dash_only() -> None:
    data = "AC/DC - T.N.T. - Live\nJay-Z - 99 Problems\n".encode()

    [playlist] = parse_import("list.txt", data)

    assert playlist.rows == [
        ImportRow(artist="AC/DC", title="T.N.T. - Live"),
        ImportRow(artist="Jay-Z", title="99 Problems"),
    ]


def test_text_numbering_and_blank_lines_are_not_songs() -> None:
    data = "1. Muse - Uprising\n\n  2) Muse - Starlight  \n\r\n03 Muse - Madness\n".encode()

    [playlist] = parse_import("list.txt", data)

    assert [(r.artist, r.title) for r in playlist.rows] == [
        ("Muse", "Uprising"),
        ("Muse", "Starlight"),
        ("Muse", "Madness"),
    ]


def test_band_names_that_start_with_a_number_stay_whole() -> None:
    """Line number — "1.", "2)", or "03 " with leading zero; "50 Cent" and "311" are band names."""
    data = "50 Cent - In da Club\n311 - Down\n10 Years - Wasteland\n".encode()

    [playlist] = parse_import("list.txt", data)

    assert [r.artist for r in playlist.rows] == ["50 Cent", "311", "10 Years"]


def test_text_line_without_dash_is_kept_as_title() -> None:
    """R-A48: a line that was not understood is not lost — it becomes a dimmed row."""
    [playlist] = parse_import("list.txt", "Bohemian Rhapsody\n".encode())

    assert playlist.rows == [ImportRow(artist="", title="Bohemian Rhapsody")]


def test_pasted_text_without_file_name() -> None:
    [playlist] = parse_import(None, "Queen - Bohemian Rhapsody".encode())

    assert playlist.name == "Импорт"
    assert playlist.rows == [ImportRow(artist="Queen", title="Bohemian Rhapsody")]


# --- M3U / M3U8 -------------------------------------------------------------------


def test_m3u_from_navidrome_takes_extinf_and_playlist_name() -> None:
    data = (
        "#EXTM3U\n#PLAYLIST:Zlist\n"
        "#EXTINF:189,Yello - Oh Yeah\nZ:\\Media\\Yello\\Oh Yeah.flac\n"
        "#EXTINF:301,Nirvana - Smells Like Teen Spirit\n/music/Nirvana/01.flac\n"
    ).encode()

    [playlist] = parse_import("Zlist.m3u", data)

    assert playlist.name == "Zlist"
    assert playlist.rows == [
        ImportRow(artist="Yello", title="Oh Yeah", duration_ms=189000),
        ImportRow(
            artist="Nirvana", title="Smells Like Teen Spirit", duration_ms=301000
        ),
    ]


def test_m3u_without_extinf_reads_file_name_and_folders() -> None:
    data = (
        "/music/Nirvana/Nevermind/01 - Smells Like Teen Spirit.flac\n"
        "D:\\Music\\Кино\\Группа крови\\02 Закрой за мной дверь.mp3\n"
        "Muse - Uprising.mp3\n"
    ).encode()

    [playlist] = parse_import("old.m3u8", data)

    assert playlist.name == "old"
    assert [(r.artist, r.title) for r in playlist.rows] == [
        ("Nirvana", "Smells Like Teen Spirit"),
        ("Кино", "Закрой за мной дверь"),
        ("Muse", "Uprising"),
    ]


def test_m3u_unknown_length_has_no_duration() -> None:
    data = "#EXTM3U\n#EXTINF:-1,Radiohead - Creep\nhttp://x/creep.mp3\n".encode()

    [playlist] = parse_import("a.m3u", data)

    assert playlist.rows == [ImportRow(artist="Radiohead", title="Creep")]


def test_m3u_in_windows_1251_is_read() -> None:
    """Older players write .m3u in Windows encoding rather than UTF-8."""
    data = "#EXTM3U\n#EXTINF:200,Кино - Звезда по имени Солнце\nC:\\a.mp3\n".encode(
        "cp1251"
    )

    [playlist] = parse_import("old.m3u", data)

    assert playlist.rows == [
        ImportRow(artist="Кино", title="Звезда по имени Солнце", duration_ms=200000)
    ]


# --- CSV Exportify (Spotify) ------------------------------------------------------


def test_exportify_keeps_isrc_album_duration_and_order() -> None:
    data = exportify(
        exportify_row("Numb", "Linkin Park", "Meteora", 185586, "USWB10300474"),
        exportify_row("Группа крови", "Кино", "Группа крови", 286000, "RUA1D0800001"),
    )

    [playlist] = parse_import("Мой плейлист.csv", data)

    assert playlist.name == "Мой плейлист"
    assert playlist.rows == [
        ImportRow("Linkin Park", "Numb", "Meteora", 185586, "USWB10300474"),
        ImportRow("Кино", "Группа крови", "Группа крови", 286000, "RUA1D0800001"),
    ]


def test_exportify_several_artists_first_is_the_artist() -> None:
    data = exportify(
        exportify_row("Under Pressure", "Queen,David Bowie", "Hot Space", 248000, "")
    )

    [playlist] = parse_import("p.csv", data)

    assert playlist.rows[0].artist == "Queen"
    assert playlist.rows[0].isrc == ""


def test_exportify_quotes_commas_and_newlines_inside_a_field() -> None:
    data = exportify(
        exportify_row('Hello, "World"\nagain', "Band", "Album, Vol. 2", 1000, "")
    )

    [playlist] = parse_import("p.csv", data)

    assert playlist.rows[0].title == 'Hello, "World" again'
    assert playlist.rows[0].album == "Album, Vol. 2"


def test_exportify_columns_are_found_by_name_not_position() -> None:
    data = (
        '"ISRC","Artist Name(s)","Track Name"\n"GBUM71029604","Muse","Uprising"\n'
    ).encode("utf-8-sig")

    [playlist] = parse_import("p.csv", data)

    assert playlist.rows == [ImportRow("Muse", "Uprising", isrc="GBUM71029604")]


def test_unknown_csv_names_the_columns_it_needs() -> None:
    data = "Song,Singer\nNumb,Linkin Park\n".encode()

    with pytest.raises(ImportFormatError) as error:
        parse_import("tunemymusic.csv", data)

    assert error.value.code == "bad_columns"
    assert "Track Name" in str(error.value)
    assert "Artist Name(s)" in str(error.value)


def test_exportify_zip_gives_one_playlist_per_csv_in_name_order() -> None:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr(
            "Rock.csv",
            exportify(exportify_row("Numb", "Linkin Park", "Meteora", 1, "")),
        )
        archive.writestr(
            "Liked_Songs.csv",
            exportify(exportify_row("Creep", "Radiohead", "Pablo Honey", 1, "")),
        )
        archive.writestr("readme.txt", "not a playlist")

    playlists = parse_import("spotify_playlists.zip", buffer.getvalue())

    assert [p.name for p in playlists] == ["Liked Songs", "Rock"]
    assert playlists[0].rows == [ImportRow("Radiohead", "Creep", "Pablo Honey", 1)]


def test_zip_that_unpacks_too_big_is_refused() -> None:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("bomb.csv", EXPORTIFY_HEADER + "\n" + " " * (5 * MAX_BYTES))

    with pytest.raises(ImportFormatError) as error:
        parse_import("all.zip", buffer.getvalue())

    assert error.value.code == "too_large"


# --- Apple Music library XML --------------------------------------------------


def apple_library(playlists: list[dict], tracks: dict[str, dict]) -> bytes:
    return plistlib.dumps(
        {"Major Version": 1, "Tracks": tracks, "Playlists": playlists}
    )


APPLE_TRACKS = {
    "101": {
        "Track ID": 101,
        "Name": "Numb",
        "Artist": "Linkin Park",
        "Album": "Meteora",
        "Total Time": 185000,
    },
    "102": {
        "Track ID": 102,
        "Name": "Creep",
        "Artist": "Radiohead",
        "Total Time": 238000,
    },
    "103": {"Track ID": 103, "Name": "Song 2", "Artist": "Blur", "Album": "Blur"},
}


def test_apple_library_user_playlists_in_their_order() -> None:
    data = apple_library(
        [
            {
                "Name": "Library",
                "Master": True,
                "Playlist Items": [
                    {"Track ID": 101},
                    {"Track ID": 102},
                    {"Track ID": 103},
                ],
            },
            {
                "Name": "Music",
                "Distinguished Kind": 4,
                "Playlist Items": [{"Track ID": 101}],
            },
            {
                "Name": "Дорога",
                "Playlist Items": [{"Track ID": 103}, {"Track ID": 101}],
            },
        ],
        APPLE_TRACKS,
    )

    playlists = parse_import("Library.xml", data)

    assert [p.name for p in playlists] == ["Медиатека Apple Music", "Дорога"]
    assert playlists[1].rows == [
        ImportRow("Blur", "Song 2", "Blur"),
        ImportRow("Linkin Park", "Numb", "Meteora", 185000),
    ]
    assert [r.title for r in playlists[0].rows] == ["Numb", "Creep", "Song 2"]


def test_apple_single_playlist_export_is_that_playlist() -> None:
    data = apple_library(
        [{"Name": "Workout", "Playlist Items": [{"Track ID": 102}]}], APPLE_TRACKS
    )

    [playlist] = parse_import("Workout.xml", data)

    assert playlist.name == "Workout"
    assert playlist.rows == [ImportRow("Radiohead", "Creep", duration_ms=238000)]


def test_apple_item_pointing_to_missing_track_is_skipped_not_fatal() -> None:
    data = apple_library(
        [{"Name": "P", "Playlist Items": [{"Track ID": 999}, {"Track ID": 101}]}],
        APPLE_TRACKS,
    )

    [playlist] = parse_import("p.xml", data)

    assert [r.title for r in playlist.rows] == ["Numb"]


def test_xml_that_is_not_a_library_is_a_clear_error() -> None:
    with pytest.raises(ImportFormatError) as error:
        parse_import("x.xml", b"<?xml version='1.0'?><rss><channel/></rss>")

    assert error.value.code == "bad_file"


# --- limits and empty files ---------------------------------------------------


def test_file_over_size_limit_is_refused_before_parsing() -> None:
    with pytest.raises(ImportFormatError) as error:
        parse_import("big.txt", b"a - b\n" * (MAX_BYTES // 6 + 1))

    assert error.value.code == "too_large"


def test_more_rows_than_limit_is_refused() -> None:
    data = "".join(f"Artist - Song {i}\n" for i in range(MAX_ROWS + 1)).encode()

    with pytest.raises(ImportFormatError) as error:
        parse_import("many.txt", data)

    assert error.value.code == "too_many_rows"


def test_limit_itself_is_allowed() -> None:
    data = "".join(f"Artist - Song {i}\n" for i in range(MAX_ROWS)).encode()

    [playlist] = parse_import("many.txt", data)

    assert len(playlist.rows) == MAX_ROWS


def test_limits_are_the_ones_in_the_plan() -> None:
    """`plan/p5-import.md`: 10,000 lines and 10 MiB per file."""
    assert MAX_ROWS == 10_000
    assert MAX_BYTES == 10 * 1024 * 1024


def test_file_without_songs_is_an_error_not_an_empty_playlist() -> None:
    with pytest.raises(ImportFormatError) as error:
        parse_import("empty.m3u", b"#EXTM3U\n\n")

    assert error.value.code == "empty"


def test_large_exportify_parses_quickly() -> None:
    """2000 lines is a common playlist; parsing should not be noticeable next to searching."""
    import time

    rows = [
        exportify_row(f"Song {i}", "Band", "Album", 1000, f"XX{i:010d}")
        for i in range(2000)
    ]
    data = exportify(*rows)

    began = time.monotonic()
    [playlist] = parse_import("big.csv", data)

    assert len(playlist.rows) == 2000
    assert time.monotonic() - began < 1.0
