"""Response type matches the actual file format (FT-524, Р-A60).

Previously the server named everything `audio/mpeg`, even FLAC. Ready Opus for metered
network and original without `prefer` are tested on the extension file in
`test_extension_asset.py`; here is the type header itself.
"""

from __future__ import annotations

from pathlib import Path

from app.media import audio_response


def test_local_files_say_what_they_are(tmp_path: Path) -> None:
    for suffix, kind in ((".mp3", "audio/mpeg"), (".flac", "audio/flac"), (".opus", "audio/ogg")):
        path = tmp_path / f"a{suffix}"
        path.write_bytes(b"\0" * 16)
        assert audio_response(path).media_type == kind, suffix
