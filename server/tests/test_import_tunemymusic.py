"""FT-626 (Р-A47, Р-A94): TuneMyMusic CSV import — migration from Yandex, YouTube Music, Deezer, Tidal.

TuneMyMusic ("Export to file → CSV") is an intermediary through which a user exports their music from
a service without its own export capability. A single file carries everything at once: playlists, "Favorites", saved albums and
artist follows; whose list it is — told by `Playlist name` column, what it is — told by `Type` column.

Columns verified against live files (06.10): `Track name,Artist name,Album,Playlist name,Type,ISRC` and a seventh,
service-dependent one (`Spotify - id`, `Apple - id`); from YouTube artist and album are sometimes empty, and
title is "artist - song".

Dedicated module; wired into the shared `parse_import` by the lead during merge (Р-A92).

What tests do not prove: how `Album` and `Artist` rows appear in live files (sample not found) — they
simply do not become playlists.
"""

from __future__ import annotations

import pytest

from app.import_formats import MAX_ROWS, ImportFormatError, ImportRow
from app.import_tunemymusic import is_tunemymusic, parse_tunemymusic

HEADER = "Track name,Artist name,Album,Playlist name,Type,ISRC"


def csv_text(*lines: str, header: str = HEADER) -> str:
    return "\r\n".join([header, *lines]) + "\r\n"


def test_one_file_becomes_several_playlists_in_file_order() -> None:
    text = csv_text(
        "Numb,Linkin Park,Meteora,Дорога,Playlist,USWB10300477",
        "Lithium,Nirvana,Nevermind,Спорт,Playlist,",
        "Группа крови,Кино,Группа крови,Дорога,Playlist,",
        '"Hello, Goodbye",The Beatles,Magical Mystery Tour,Спорт,Playlist,GBAYE0601649',
    )

    playlists = parse_tunemymusic(text)

    assert [p.name for p in playlists] == ["Дорога", "Спорт"], (
        "order is by first encounter"
    )
    assert playlists[0].rows == [
        ImportRow("Linkin Park", "Numb", album="Meteora", isrc="USWB10300477"),
        ImportRow("Кино", "Группа крови", album="Группа крови"),
    ]
    assert playlists[1].rows == [
        ImportRow("Nirvana", "Lithium", album="Nevermind"),
        ImportRow(
            "The Beatles",
            "Hello, Goodbye",
            album="Magical Mystery Tour",
            isrc="GBAYE0601649",
        ),
    ]


def test_service_id_column_and_quoted_everything() -> None:
    text = csv_text(
        '"kawAIi (feat. Srezcat)","Kobaryo","kawAIi - Single","Favorite Songs","Playlist","TCJPU2369958","1669086251"',
        '"怪獣","Kry.exe & Nmy","怪獣 - Single","Favorite Songs","Playlist","",""',
        header='"Track name","Artist name","Album","Playlist name","Type","ISRC","Apple - id"',
    )

    [playlist] = parse_tunemymusic(text)

    assert playlist.name == "Favorite Songs"
    assert playlist.rows == [
        ImportRow(
            "Kobaryo",
            "kawAIi (feat. Srezcat)",
            album="kawAIi - Single",
            isrc="TCJPU2369958",
        ),
        ImportRow("Kry.exe & Nmy", "怪獣", album="怪獣 - Single"),
    ]


def test_youtube_rows_without_artist_split_the_title() -> None:
    text = csv_text(
        '"P*Light ft. Yukacco - Stargazer (Dj Shimamura Remix)","","","vibe","Playlist",""',
        '"Rude Buster (Camellia Remix) [Deltarune Battle Theme]","","","vibe","Playlist",""',
        '"Daft Punk - One More Time","Daft Punk","Discovery","vibe","Playlist",""',
    )

    [playlist] = parse_tunemymusic(text)

    assert playlist.rows == [
        ImportRow("P*Light ft. Yukacco", "Stargazer (Dj Shimamura Remix)"),
        ImportRow("", "Rude Buster (Camellia Remix) [Deltarune Battle Theme]"),
        ImportRow("Daft Punk", "Daft Punk - One More Time", album="Discovery"),
    ], (
        "title splits only when artist is missing; if artist is present — keep title intact"
    )


def test_favorites_are_a_list_albums_and_artists_are_not() -> None:
    text = csv_text(
        "Numb,Linkin Park,Meteora,,Favorite,",
        "Lithium,Nirvana,Nevermind,Liked Songs,favorite,",
        ",Radiohead,OK Computer,,Album,",
        "Paranoid Android,Radiohead,OK Computer,OK Computer,Album,",
        ",Muse,,,Artist,",
        "One,Metallica,,Рок,Playlist,",
    )

    playlists = parse_tunemymusic(text)

    assert [p.name for p in playlists] == ["Любимые песни", "Liked Songs", "Рок"]
    assert playlists[0].rows == [ImportRow("Linkin Park", "Numb", album="Meteora")]
    assert playlists[1].rows == [ImportRow("Nirvana", "Lithium", album="Nevermind")]
    assert playlists[2].rows == [ImportRow("Metallica", "One")]


def test_playlist_without_name_and_blank_rows() -> None:
    text = csv_text(
        "One,Metallica,,,Playlist,",
        ",,,,Playlist,",
        "  ,  ,,Рок,Playlist,",
        "Two,Metallica,,  ,Playlist,",
    )

    [playlist] = parse_tunemymusic(text)

    assert playlist.name == "TuneMyMusic"
    assert [row.title for row in playlist.rows] == ["One", "Two"]


def test_bom_columns_in_any_order_and_newline_inside_a_cell() -> None:
    text = (
        "﻿Type,ISRC,Playlist name,Artist name,Track name,Album\n"
        'Playlist,,Рок,Metallica,"Nothing\nElse Matters",Metallica\n'
    )

    [playlist] = parse_tunemymusic(text)

    assert playlist.rows == [
        ImportRow("Metallica", "Nothing Else Matters", album="Metallica")
    ]


def test_is_tunemymusic_tells_it_from_exportify() -> None:
    assert is_tunemymusic(csv_text("a,b,c,d,Playlist,"))
    assert is_tunemymusic(
        '﻿"Track name","Artist name","Album","Playlist name","Type","ISRC","Spotify - id"\n'
    )
    assert not is_tunemymusic(
        '"Track URI","Track Name","Artist URI(s)","Artist Name(s)","Album Name"\n'
    )
    assert not is_tunemymusic("Linkin Park — Numb\nNirvana - Lithium\n")
    assert not is_tunemymusic("")


def test_foreign_csv_is_refused_with_bad_columns() -> None:
    with pytest.raises(ImportFormatError) as error:
        parse_tunemymusic("Track name,Artist name\nNumb,Linkin Park\n")
    assert error.value.code == "bad_columns"


def test_broken_csv_is_bad_file() -> None:
    with pytest.raises(ImportFormatError) as error:
        parse_tunemymusic(
            csv_text('Numb,"Linkin Park,Meteora,Дорога,Playlist,\nx,"y"z,,,Playlist,')
        )
    assert error.value.code == "bad_file"


def test_only_albums_and_artists_gives_no_lists() -> None:
    assert (
        parse_tunemymusic(csv_text(",Muse,,,Artist,", ",Radiohead,OK Computer,,Album,"))
        == []
    )


def test_row_limit_per_list() -> None:
    lines = [f"T{i},A,,Большой,Playlist," for i in range(MAX_ROWS + 1)]

    with pytest.raises(ImportFormatError) as error:
        parse_tunemymusic(csv_text(*lines))
    assert error.value.code == "too_many_rows"


def test_module_does_not_touch_files_network_or_logs() -> None:
    from pathlib import Path

    source = (
        Path(__file__).resolve().parents[1] / "app" / "import_tunemymusic.py"
    ).read_text()
    for word in ("open(", "logging", "logger", "httpx", "urlopen", "socket", "print("):
        assert word not in source, word
