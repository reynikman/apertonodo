"""English translations for import refusal messages and default playlist names."""

from __future__ import annotations

MESSAGES: dict[str, str] = {
    "CSV должен содержать столбцы Track Name и Artist Name(s).": (
        "CSV must contain Track Name and Artist Name(s) columns."
    ),
    "В одном списке больше 10 000 песен.": (
        "A single playlist has more than 10 000 songs."
    ),
    "В файле нет Tracks медиатеки Apple Music.": (
        "The file has no Apple Music library Tracks."
    ),
    "В файле нет песен.": "The file has no songs.",
    "Корневой элемент должен быть playlist.": (
        "Root element must be playlist."
    ),
    "Не удалось прочитать ZIP-архив.": "Could not read ZIP archive.",
    "Не удалось прочитать base64 файла.": "Could not read file base64.",
    "Не удалось прочитать кодировку файла.": (
        "Could not read file encoding."
    ),
    "Не удалось прочитать файл.": "Could not read the file.",
    "Не удалось разобрать CSV.": "Could not parse CSV.",
    "Не удалось разобрать XML.": "Could not parse XML.",
    "Не удалось разобрать медиатеку Apple Music.": (
        "Could not parse Apple Music library."
    ),
    "Неверная ссылка на песню Apple Music.": (
        "Invalid Apple Music song reference."
    ),
    "Неверная строка EXTINF в M3U.": "Invalid EXTINF line in M3U.",
    "Неверный формат песен Apple Music.": (
        "Invalid Apple Music songs format."
    ),
    "Неверный формат песни Apple Music.": (
        "Invalid Apple Music song format."
    ),
    "Неверный формат плейлиста Apple Music.": (
        "Invalid Apple Music playlist format."
    ),
    "Неверный формат плейлистов Apple Music.": (
        "Invalid Apple Music playlists format."
    ),
    "Неверный формат текстового поля.": "Invalid text field format.",
    "Объявления DOCTYPE и сущностей запрещены.": (
        "DOCTYPE and entity declarations are forbidden."
    ),
    "Распакованный архив больше 50 МиБ.": (
        "Unpacked archive is larger than 50 MiB."
    ),
    "Файл больше 10 МиБ.": "The file is larger than 10 MiB.",
    "Импорт": "Import",
    "Медиатека Apple Music": "Apple Music library",
}


def _is_russian(accept_language: str | None) -> bool:
    if not accept_language or not accept_language.strip():
        return True
    first = accept_language.split(",")[0].strip()
    tag = first.split(";")[0].strip()
    primary = tag.split("-")[0].split("_")[0].strip().lower()
    return primary == "ru"


def localized(text: str, accept_language: str | None) -> str:
    """Return Russian text if accept-language is absent or ru, else English."""
    if _is_russian(accept_language):
        return text
    return MESSAGES.get(text, text)
