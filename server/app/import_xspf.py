"""Parse XSPF playlists in memory."""

from __future__ import annotations

import re
from pathlib import PurePosixPath
from urllib.parse import unquote
from xml.etree.ElementTree import TreeBuilder
from xml.parsers import expat

from app.import_formats import (
    ImportFormatError,
    ImportList,
    ImportRow,
    _TRACK_NUMBER,
    _append,
    _song,
)

_NETWORK_SCHEMES = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*://")


def _is_network_url(url: str) -> bool:
    clean = url.strip()
    if clean.lower().startswith("file://"):
        return False
    if clean.startswith("//"):
        return True
    return bool(_NETWORK_SCHEMES.match(clean))


def _tag_name(tag: str) -> str:
    return tag.rsplit(":", 1)[-1].rsplit("}", 1)[-1].strip().lower()


def _reject_entity(*args: object) -> None:
    raise ImportFormatError("bad_file", "Объявления DOCTYPE и сущностей запрещены.")


def _reject_external(*args: object) -> int:
    # For this handler expat expects a number; the call never gets as far as returning.
    raise ImportFormatError("bad_file", "Объявления DOCTYPE и сущностей запрещены.")


def _track_from_location(location: str) -> tuple[str, str]:
    raw = unquote(location).strip()
    path = PurePosixPath(raw.replace("\\", "/"))
    label = _TRACK_NUMBER.sub("", path.stem).strip()
    if not label:
        return "", ""
    return _song(label)


def _parse_duration_ms(val: str | None) -> int | None:
    if not val:
        return None
    try:
        dur = int(val.strip())
        return dur if dur >= 0 else None
    except ValueError:
        return None


def parse_xspf(name: str, data: bytes) -> ImportList:
    builder = TreeBuilder()
    parser = expat.ParserCreate()
    parser.StartDoctypeDeclHandler = _reject_entity
    parser.EntityDeclHandler = _reject_entity
    parser.ExternalEntityRefHandler = _reject_external
    parser.UnparsedEntityDeclHandler = _reject_entity
    parser.StartElementHandler = builder.start
    parser.EndElementHandler = builder.end
    parser.CharacterDataHandler = builder.data

    try:
        parser.Parse(data, True)
        root = builder.close()
    except ImportFormatError:
        raise
    except (expat.ExpatError, Exception):
        raise ImportFormatError("bad_file", "Не удалось разобрать XML.") from None

    if root is None or _tag_name(root.tag) != "playlist":
        raise ImportFormatError("bad_file", "Корневой элемент должен быть playlist.")

    playlist_title = ""
    tracks = []
    for child in root:
        child_tag = _tag_name(child.tag)
        if child_tag == "title" and child.text and not playlist_title:
            t = child.text.strip()
            if t:
                playlist_title = t
        elif child_tag == "tracklist":
            for sub in child:
                if _tag_name(sub.tag) == "track":
                    tracks.append(sub)

    final_name = playlist_title or name
    rows: list[ImportRow] = []

    for track_elem in tracks:
        creator: str | None = None
        title: str | None = None
        album: str = ""
        duration_str: str | None = None
        location: str | None = None

        for elem in track_elem:
            tag = _tag_name(elem.tag)
            text = (elem.text or "").strip()
            if tag == "creator" and text and not creator:
                creator = text
            elif tag == "title" and text and not title:
                title = text
            elif tag == "album" and text and not album:
                album = text
            elif tag == "duration" and text and not duration_str:
                duration_str = text
            elif tag == "location" and text and not location:
                location = text

        duration_ms = _parse_duration_ms(duration_str)

        if title:
            if creator:
                track_artist = creator
                track_title = title
            else:
                track_artist, track_title = _song(title)
        else:
            if not location or _is_network_url(location):
                continue
            loc_artist, loc_title = _track_from_location(location)
            if not loc_title:
                continue
            track_artist = creator or loc_artist
            track_title = loc_title

        if not track_title:
            continue

        _append(
            rows,
            ImportRow(track_artist, track_title, album=album, duration_ms=duration_ms),
        )

    return ImportList(final_name, rows)
