from __future__ import annotations

from pathlib import Path

from fastapi.responses import FileResponse, Response


class StreamAborted(Exception):
    """Stream dropped midway through the response, and the cause is already recorded in a log line.

    Headers have already been sent by this point, so finishing the response cleanly
    is impossible: the phone would mistake a truncated song for a complete one. The only
    option is to tear down the connection, and uvicorn only drops it when the application
    raises an exception — printing a Traceback in the process. For this exception,
    `log_config` hides the Traceback: the reason is already in the `stream …` line, and
    `soak_report.sh` counts every Traceback as a server crash.
    """


# Response content-type based on file extension. Previously everything was called audio/mpeg,
# and cached files on the phone would get the wrong extension (FT-524).
_AUDIO_TYPES = {
    ".mp3": "audio/mpeg",
    ".flac": "audio/flac",
    ".opus": "audio/ogg",
    ".ogg": "audio/ogg",
    ".m4a": "audio/mp4",
    ".mp4": "audio/mp4",
    ".aac": "audio/mp4",
}


def audio_type(name: str) -> str:
    return _AUDIO_TYPES.get(Path(name).suffix.lower(), "audio/mpeg")


def audio_response(path: Path, range_header: str | None = None) -> Response:
    del range_header
    headers = {
        "Accept-Ranges": "bytes",
        "Cache-Control": "no-store",
    }
    return FileResponse(path, media_type=audio_type(path.name), headers=headers)
