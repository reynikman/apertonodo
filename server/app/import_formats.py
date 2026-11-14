"""Parse imported playlists in memory, without file access, network or logging."""

from __future__ import annotations

import csv
import io
import plistlib
import re
import zipfile
import zlib
from dataclasses import dataclass
from pathlib import PurePosixPath
from xml.parsers.expat import ExpatError

from app.import_messages import localized

MAX_BYTES = 10 * 1024 * 1024
MAX_ROWS = 10_000

_SPACED_DASH = re.compile(r"(?<=\s)[—–-](?=\s)")
_TEXT_NUMBER = re.compile(r"^(?:[0-9]+[.)]\s+|0[0-9]+\s+)")
_TRACK_NUMBER = re.compile(r"^[0-9]+(?:\s*[-.)]\s*|\s+)")


@dataclass(frozen=True)
class ImportRow:
    artist: str
    title: str
    album: str = ""
    duration_ms: int | None = None
    isrc: str = ""


@dataclass
class ImportList:
    name: str
    rows: list[ImportRow]


class ImportFormatError(ValueError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


def _decode(data: bytes) -> str:
    try:
        if data.startswith((b"\xff\xfe", b"\xfe\xff")):
            return data.decode("utf-16")
        try:
            return data.decode("utf-8-sig")
        except UnicodeDecodeError:
            return data.decode("cp1251")
    except UnicodeError:
        raise ImportFormatError("bad_file", "Не удалось прочитать кодировку файла.") from None


def _file_name(file_name: str | None, accept_language: str | None = None) -> str:
    default_name = localized("Импорт", accept_language)
    if not file_name:
        return default_name
    return PurePosixPath(file_name.replace("\\", "/")).stem.replace("_", " ").strip() or default_name


def _clean(value: object) -> str:
    if not isinstance(value, str):
        raise ImportFormatError("bad_file", "Неверный формат текстового поля.")
    return value.replace("\r\n", " ").replace("\r", " ").replace("\n", " ").strip()


def _song(label: str) -> tuple[str, str]:
    parts = _SPACED_DASH.split(label.strip(), maxsplit=1)
    if len(parts) == 2:
        return parts[0].strip(), parts[1].strip()
    return "", parts[0]


def _milliseconds(value: object) -> int | None:
    if isinstance(value, bool) or not isinstance(value, (str, int)):
        return None
    try:
        duration = int(value)
    except ValueError:
        return None
    return duration if duration >= 0 else None


def _append(rows: list[ImportRow], row: ImportRow) -> None:
    if len(rows) >= MAX_ROWS:
        raise ImportFormatError("too_many_rows", "В одном списке больше 10 000 песен.")
    rows.append(row)


def _text(name: str, text: str) -> ImportList:
    rows: list[ImportRow] = []
    for line in text.splitlines():
        label = _TEXT_NUMBER.sub("", line.strip()).strip()
        if label:
            artist, title = _song(label)
            _append(rows, ImportRow(artist, title))
    return ImportList(name, rows)


def _m3u(name: str, text: str) -> ImportList:
    rows: list[ImportRow] = []
    skip_path = False
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("#PLAYLIST:"):
            name = line.partition(":")[2].strip() or name
        elif line.startswith("#EXTINF:"):
            seconds, comma, label = line[len("#EXTINF:"):].partition(",")
            if not comma:
                raise ImportFormatError("bad_file", "Неверная строка EXTINF в M3U.")
            try:
                duration = int(float(seconds) * 1000)
            except (ValueError, OverflowError):
                duration = -1
            artist, title = _song(label)
            _append(rows, ImportRow(artist, title, duration_ms=_milliseconds(duration)))
            skip_path = True
        elif line.startswith("#"):
            continue
        elif skip_path:
            skip_path = False
        else:
            # Pure paths handle both separator styles without touching the filesystem.
            path = PurePosixPath(line.replace("\\", "/"))
            label = _TRACK_NUMBER.sub("", path.stem).strip()
            if not label:
                continue
            artist, title = _song(label)
            if not artist and len(path.parts) >= 3:
                folder = path.parts[-3]
                if folder != "/" and not folder.endswith(":"):
                    artist = folder
            _append(rows, ImportRow(artist, title))
    return ImportList(name, rows)


def _csv(name: str, text: str) -> ImportList:
    rows: list[ImportRow] = []
    try:
        reader = csv.DictReader(io.StringIO(text, newline=""), strict=True)
        required = {"Track Name", "Artist Name(s)"}
        if not required.issubset(reader.fieldnames or []):
            raise ImportFormatError(
                "bad_columns", "CSV должен содержать столбцы Track Name и Artist Name(s)."
            )
        for record in reader:
            title = _clean(record["Track Name"])
            artist = _clean(record["Artist Name(s)"]).partition(",")[0].strip()
            if not title and not artist:
                continue
            _append(rows, ImportRow(
                artist=artist,
                title=title,
                album=_clean(record.get("Album Name", "")),
                duration_ms=_milliseconds(record.get("Track Duration (ms)")),
                isrc=_clean(record.get("ISRC", "")),
            ))
    except csv.Error:
        raise ImportFormatError("bad_file", "Не удалось разобрать CSV.") from None
    return ImportList(name, rows)


def _zip(data: bytes, accept_language: str | None = None) -> list[ImportList]:
    playlists: list[ImportList] = []
    remaining = 5 * MAX_BYTES
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            entries = archive.infolist()
            # Count even ignored files: they must not hide an oversized archive.
            if sum(entry.file_size for entry in entries) > remaining:
                raise ImportFormatError("too_large", "Распакованный архив больше 50 МиБ.")
            for entry in sorted(entries, key=lambda item: item.filename):
                if entry.is_dir() or not entry.filename.lower().endswith(".csv"):
                    continue
                buffer = io.BytesIO()
                with archive.open(entry) as source:
                    # Bound actual reads as well as the untrusted ZIP size metadata.
                    while chunk := source.read(min(64 * 1024, remaining + 1)):
                        remaining -= len(chunk)
                        if remaining < 0:
                            raise ImportFormatError("too_large", "Распакованный архив больше 50 МиБ.")
                        buffer.write(chunk)
                playlists.append(_csv(_file_name(entry.filename, accept_language), _decode(buffer.getvalue())))
    except (zipfile.BadZipFile, zipfile.LargeZipFile, RuntimeError,
            NotImplementedError, OSError, EOFError, zlib.error):
        raise ImportFormatError("bad_file", "Не удалось прочитать ZIP-архив.") from None
    return playlists


def _apple(name: str, data: bytes, accept_language: str | None = None) -> list[ImportList]:
    try:
        # plistlib rejects entity declarations; it does not fetch the Apple DTD.
        library = plistlib.loads(data, fmt=plistlib.FMT_XML)
    except (plistlib.InvalidFileException, ExpatError, ValueError, TypeError,
            OverflowError, AttributeError, IndexError):
        raise ImportFormatError("bad_file", "Не удалось разобрать медиатеку Apple Music.") from None
    if not isinstance(library, dict) or not isinstance(library.get("Tracks"), dict):
        raise ImportFormatError("bad_file", "В файле нет Tracks медиатеки Apple Music.")
    tracks = library["Tracks"]
    entries = library.get("Playlists", [])
    if not isinstance(entries, list):
        raise ImportFormatError("bad_file", "Неверный формат плейлистов Apple Music.")
    playlists: list[ImportList] = []
    for entry in entries:
        if not isinstance(entry, dict):
            raise ImportFormatError("bad_file", "Неверный формат плейлиста Apple Music.")
        if entry.get("Master"):
            playlist_name = localized("Медиатека Apple Music", accept_language)
        elif "Distinguished Kind" in entry:
            continue
        else:
            playlist_name = _clean(entry.get("Name", name)) or name
        items = entry.get("Playlist Items", [])
        if not isinstance(items, list):
            raise ImportFormatError("bad_file", "Неверный формат песен Apple Music.")
        rows: list[ImportRow] = []
        for item in items:
            if not isinstance(item, dict):
                raise ImportFormatError("bad_file", "Неверная ссылка на песню Apple Music.")
            track = tracks.get(str(item.get("Track ID")))
            if track is None:
                continue
            if not isinstance(track, dict):
                raise ImportFormatError("bad_file", "Неверный формат песни Apple Music.")
            _append(rows, ImportRow(
                artist=_clean(track.get("Artist", "")),
                title=_clean(track.get("Name", "")),
                album=_clean(track.get("Album", "")),
                duration_ms=_milliseconds(track.get("Total Time")),
                isrc=_clean(track.get("ISRC", "")),
            ))
        playlists.append(ImportList(playlist_name, rows))
    return playlists


def parse_import(
    file_name: str | None, data: bytes, accept_language: str | None = None,
) -> list[ImportList]:
    """Identify the format by content first, then extension; enforce import limits."""
    if len(data) > MAX_BYTES:
        raise ImportFormatError("too_large", "Файл больше 10 МиБ.")
    if data.startswith(b"PK"):
        playlists = _zip(data, accept_language=accept_language)
    else:
        text = _decode(data)
        name = _file_name(file_name, accept_language=accept_language)
        suffix = PurePosixPath((file_name or "").replace("\\", "/")).suffix.lower()
        if text.lstrip().startswith("<"):
            playlists = _apple(name, data, accept_language=accept_language)
        elif text.lstrip().startswith(("#EXTM3U", "#EXTINF")) or suffix in {".m3u", ".m3u8"}:
            playlists = [_m3u(name, text)]
        elif suffix == ".csv":
            playlists = [_csv(name, text)]
        else:
            playlists = [_text(name, text)]
    if not any(playlist.rows for playlist in playlists):
        raise ImportFormatError("empty", "В файле нет песен.")
    return playlists
