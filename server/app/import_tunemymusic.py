"""Parse TuneMyMusic CSV export in memory."""

from __future__ import annotations

import csv
import io

from app.import_formats import (
    ImportFormatError,
    ImportList,
    ImportRow,
    _append,
    _clean,
    _song,
)

REQUIRED_COLUMNS = frozenset({"Track name", "Artist name", "Playlist name", "Type"})


def is_tunemymusic(text: str) -> bool:
    """Identify TuneMyMusic CSV export by columns in the first line."""
    if not text:
        return False
    try:
        reader = csv.reader(
            io.StringIO(text.lstrip("\ufeff"), newline=""),
            strict=True,
        )
        row = next(reader, None)
        if not row:
            return False
        columns = {col.lstrip("\ufeff").strip() for col in row if col is not None}
        return REQUIRED_COLUMNS.issubset(columns)
    except Exception:
        return False


def parse_tunemymusic(text: str) -> list[ImportList]:
    """Parse TuneMyMusic CSV export into playlists grouped by playlist name."""
    playlists: dict[str, ImportList] = {}
    try:
        reader = csv.DictReader(
            io.StringIO(text.lstrip("\ufeff"), newline=""),
            strict=True,
            restval="",
        )
        fieldnames = reader.fieldnames
        if not fieldnames:
            raise ImportFormatError(
                "bad_columns",
                "CSV must contain columns Track name, Artist name, Playlist name, and Type.",
            )
        clean_fieldnames = [
            (name.lstrip("\ufeff").strip() if name is not None else None)
            for name in fieldnames
        ]
        if not REQUIRED_COLUMNS.issubset(
            {name for name in clean_fieldnames if name is not None}
        ):
            raise ImportFormatError(
                "bad_columns",
                "CSV must contain columns Track name, Artist name, Playlist name, and Type.",
            )
        reader.fieldnames = clean_fieldnames

        for record in reader:
            row_type = _clean(record.get("Type") or "").lower()
            if row_type in {"album", "artist"}:
                continue

            title = _clean(record.get("Track name") or "")
            artist = _clean(record.get("Artist name") or "")
            if not artist:
                artist, title = _song(title)

            if not title and not artist:
                continue

            playlist_name = _clean(record.get("Playlist name") or "")
            if not playlist_name:
                playlist_name = (
                    "Любимые песни" if row_type == "favorite" else "TuneMyMusic"
                )

            album = _clean(record.get("Album") or "")
            isrc = _clean(record.get("ISRC") or "")

            if playlist_name not in playlists:
                playlists[playlist_name] = ImportList(playlist_name, [])
            _append(
                playlists[playlist_name].rows,
                ImportRow(artist=artist, title=title, album=album, isrc=isrc),
            )
    except csv.Error:
        raise ImportFormatError("bad_file", "Failed to parse CSV.") from None

    return list(playlists.values())
