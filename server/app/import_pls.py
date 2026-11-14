"""Parse PLS playlists in memory."""

from __future__ import annotations

import re
from pathlib import PurePosixPath
from urllib.parse import unquote

from app.import_formats import ImportList, ImportRow, _TRACK_NUMBER, _append, _song

_ENTRY_LINE = re.compile(r"^\s*(file|title|length)(\d+)\s*=\s*(.*)$", re.IGNORECASE)
_NETWORK_SCHEMES = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*://")


def _is_network_url(url: str) -> bool:
    clean = url.strip()
    if clean.lower().startswith("file://"):
        return False
    if clean.startswith("//"):
        return True
    return bool(_NETWORK_SCHEMES.match(clean))


def _track_from_file(file_path: str) -> tuple[str, str]:
    raw = unquote(file_path).strip()
    path = PurePosixPath(raw.replace("\\", "/"))
    label = _TRACK_NUMBER.sub("", path.stem).strip()
    if not label:
        return "", ""
    return _song(label)


def _parse_length_seconds(val: str | None) -> int | None:
    if not val:
        return None
    try:
        sec = float(val.strip())
        if sec > 0:
            return int(sec * 1000)
    except (ValueError, OverflowError):
        pass
    return None


def parse_pls(name: str, text: str) -> ImportList:
    entries: dict[int, dict[str, str]] = {}
    for line in text.splitlines():
        match = _ENTRY_LINE.match(line)
        if not match:
            continue
        field = match.group(1).lower()
        idx = int(match.group(2))
        val = match.group(3).strip()
        if idx not in entries:
            entries[idx] = {}
        entries[idx][field] = val

    rows: list[ImportRow] = []
    for idx in sorted(entries.keys()):
        entry = entries[idx]
        title = entry.get("title", "")
        file_path = entry.get("file", "")
        duration_ms = _parse_length_seconds(entry.get("length"))

        if title:
            artist, song_title = _song(title)
        else:
            if not file_path or _is_network_url(file_path):
                continue
            artist, song_title = _track_from_file(file_path)

        if not song_title and not artist:
            continue

        _append(rows, ImportRow(artist, song_title, duration_ms=duration_ms))

    return ImportList(name, rows)
