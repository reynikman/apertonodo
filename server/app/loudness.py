from __future__ import annotations

import asyncio
from collections.abc import Callable, Iterable
import logging
import math
from pathlib import Path
import re
import subprocess
import tempfile

import asyncpg

TARGET_LUFS = -18.0
_STDERR_TAIL = 16_384

logger = logging.getLogger("apertonodo")


class LoudnessFailed(Exception):
    """Exception raised when loudness measurement fails."""


class LoudnessUnavailable(LoudnessFailed):
    """Measurement failed not because of the file: ffmpeg missing, timed out, did not start.

    Such failure is not remembered — otherwise a server deployed without ffmpeg would mark
    all files as "measurement failed" permanently.
    """


def _stamp(path: Path) -> tuple[int, int] | None:
    """File size and modification time; `None` if file does not exist."""
    try:
        if not path.is_file():
            return None
        stat = path.stat()
    except (OSError, ValueError):
        return None
    return stat.st_size, stat.st_mtime_ns


def parse_loudness(text: str) -> float | None:
    """Parse integrated loudness in LUFS from ffmpeg stderr output."""
    if "Summary:" not in text:
        return None
    summary_part = text.split("Summary:")[-1]
    match = re.search(
        r"^\s*I:\s*([+-]?(?:\d+(?:\.\d*)?|\.\d+|inf))\s*LUFS\b",
        summary_part,
        re.MULTILINE,
    )
    if not match:
        return None
    try:
        val = float(match.group(1))
    except ValueError:
        return None
    if val <= -69.0 or not math.isfinite(val):
        return None
    return val


def gain_db(lufs: float) -> float:
    """Calculate volume gain adjustment in dB to reach TARGET_LUFS."""
    diff = TARGET_LUFS - lufs
    clamped = max(-20.0, min(20.0, diff))
    result = round(clamped, 2)
    return 0.0 if result == 0.0 else result


def measure(path: Path, *, timeout_s: float = 120.0) -> float:
    """Measure integrated loudness of audio file using ffmpeg."""
    # Full path: ffmpeg would otherwise read "a:b.flac" as protocol "a".
    try:
        path = Path(path).resolve(strict=True)
        if not path.is_file():
            raise LoudnessFailed("file not found")
    except OSError:
        raise LoudnessFailed("file not found") from None

    if timeout_s <= 0:
        raise LoudnessUnavailable("measurement timed out")

    # ffmpeg writes the summary to the end of stderr; a corrupt file before it could dump
    # megabytes of warnings — only the tail is loaded into memory.
    try:
        with tempfile.TemporaryFile() as stderr:
            proc = subprocess.run(
                [
                    "ffmpeg",
                    "-hide_banner",
                    "-nostats",
                    "-nostdin",
                    "-protocol_whitelist",
                    "file,pipe",
                    "-i",
                    str(path),
                    "-map",
                    "0:a:0",
                    "-af",
                    "ebur128=framelog=quiet",
                    "-f",
                    "null",
                    "-",
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=stderr,
                timeout=timeout_s,
            )
            stderr.seek(max(0, stderr.tell() - _STDERR_TAIL))
            tail = stderr.read(_STDERR_TAIL).decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        raise LoudnessUnavailable("measurement timed out") from None
    except FileNotFoundError:
        raise LoudnessUnavailable("ffmpeg unavailable") from None
    except OSError:
        raise LoudnessUnavailable("measurement failed") from None

    if proc.returncode != 0:
        raise LoudnessFailed("ffmpeg failed")

    lufs = parse_loudness(tail)
    if lufs is None:
        raise LoudnessFailed("silence or invalid audio")
    return lufs


async def remember(
    conn: asyncpg.Connection,
    path: Path,
    lufs: float | None,
    *,
    stamp: tuple[int, int] | None = None,
) -> None:
    """Record file measurement with its size and modification time.

    `stamp` is file size and mtime when measured; if omitted, current ones are taken.
    """
    path = Path(path)
    stamp = stamp or _stamp(path)
    if stamp is None:
        return

    await conn.execute(
        """
        INSERT INTO file_loudness (path, size, mtime_ns, lufs, measured_at)
        VALUES ($1, $2, $3, $4, now())
        ON CONFLICT (path) DO UPDATE SET
            size = EXCLUDED.size,
            mtime_ns = EXCLUDED.mtime_ns,
            lufs = EXCLUDED.lufs,
            measured_at = EXCLUDED.measured_at
        """,
        str(path),
        stamp[0],
        stamp[1],
        lufs,
    )


async def gain_for(conn: asyncpg.Connection, path: Path) -> float | None:
    """Return gain adjustment if file has matching size/mtime and valid lufs."""
    path = Path(path)
    stamp = _stamp(path)
    if stamp is None:
        return None

    row = await conn.fetchrow(
        "SELECT size, mtime_ns, lufs FROM file_loudness WHERE path = $1",
        str(path),
    )
    if row is None:
        return None
    if (row["size"], row["mtime_ns"]) != stamp:
        return None
    if row["lufs"] is None:
        return None
    return gain_db(row["lufs"])


async def forget(conn: asyncpg.Connection, path: Path) -> None:
    """Remove loudness measurement for given path."""
    await conn.execute("DELETE FROM file_loudness WHERE path = $1", str(Path(path)))


async def measure_pending(
    conn: asyncpg.Connection,
    paths: Iterable[Path],
    *,
    measure: Callable[[Path], float] = measure,
) -> int:
    """Measure loudness for files that have not yet been measured with current size/mtime."""
    measured_count = 0
    for raw_path in paths:
        path = Path(raw_path)
        stamp = _stamp(path)
        if stamp is None:
            continue

        row = await conn.fetchrow(
            "SELECT size, mtime_ns FROM file_loudness WHERE path = $1",
            str(path),
        )
        if row is not None and (row["size"], row["mtime_ns"]) == stamp:
            continue

        lufs: float | None
        try:
            lufs = await asyncio.to_thread(measure, path)
        except LoudnessUnavailable:
            logger.info("loudness unavailable")
            continue
        except LoudnessFailed:
            lufs = None

        # File changed while being measured: measurement belongs to old
        # content. Do not store — next run will measure the new one.
        if _stamp(path) != stamp:
            continue
        await remember(conn, path, lufs, stamp=stamp)
        logger.info("loudness failed" if lufs is None else "loudness measured")
        measured_count += 1

    return measured_count
