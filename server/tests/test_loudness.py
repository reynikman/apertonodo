"""FT-635 (Р-A94, contract D2): server measures loudness of the ready file.

To prevent a quiet 1970s recording and a loud remaster from forcing the user to reach for the volume knob, the server
measures file loudness once (`ffmpeg`, `ebur128`) and tells the app by how many decibels to adjust it so that
the song matches the common target of -18 LUFS. The number applies to the specific file, not to the song: FLAC and
its Opus copy have their own measurements.

Guarded:
- the summary for the whole file is taken from ffmpeg output, not an intermediate line;
- silence and audio-less file produce no adjustment at all, rather than "boost by 52 dB";
- adjustment is a signed number: negative means make quieter; stays within ±20 dB;
- measurement is tied to content: if the file at the same path changed, the old measurement is not returned;
- failed measurement is remembered and not retried on every pass;
- log contains neither path nor file name (file name reveals the song).

What tests do not prove: that the server calls measurement after file download and returns `audio.gain_db` in Play
response — that is lead connection (B8); that the app applies the gain (P8); that it sounds more even by ear.
"""

from __future__ import annotations

import asyncio
import logging
import os
import subprocess
from pathlib import Path
from typing import Any

import asyncpg
import pytest

from app.loudness import (
    TARGET_LUFS,
    LoudnessFailed,
    LoudnessUnavailable,
    forget,
    gain_db,
    gain_for,
    measure,
    measure_pending,
    parse_loudness,
    remember,
)
from app.migrate import apply

SUMMARY = """\
[Parsed_ebur128_0 @ 0x600001] t: 0.0999773  TARGET:-23 LUFS    M:-120.7 S:-120.7     I: -70.0 LUFS       LRA:   0.0 LU
[Parsed_ebur128_0 @ 0x600001] t: 2.99998    TARGET:-23 LUFS    M:  -9.1 S:  -9.3     I:  -9.4 LUFS       LRA:   0.0 LU
[Parsed_ebur128_0 @ 0x600001] Summary:

  Integrated loudness:
    I:         -14.3 LUFS
    Threshold: -24.3 LUFS

  Loudness range:
    LRA:         5.1 LU
    Threshold: -34.3 LUFS
    LRA low:   -17.0 LUFS
    LRA high:  -11.9 LUFS
"""


def _tone(path: Path, volume: float, seconds: int = 4) -> Path:
    subprocess.run(
        [
            "ffmpeg", "-v", "error", "-y", "-nostdin", "-f", "lavfi",
            "-i", f"sine=frequency=1000:duration={seconds}",
            "-af", f"volume={volume}", "-c:a", "flac", str(path),
        ],
        check=True,
    )  # fmt: skip
    return path


def _run(url: str, work: Any) -> Any:
    async def go() -> Any:
        conn = await asyncpg.connect(url)
        try:
            return await work(conn)
        finally:
            await conn.close()

    return asyncio.run(go())


@pytest.fixture
def base(postgres_url: str) -> str:
    asyncio.run(apply(postgres_url))
    _run(postgres_url, lambda conn: conn.execute("TRUNCATE file_loudness"))
    return postgres_url


# --- ffmpeg output parsing ---------------------------------------------------


def test_parse_takes_the_summary_not_a_running_line() -> None:
    assert parse_loudness(SUMMARY) == pytest.approx(-14.3)


def test_parse_without_summary_is_nothing() -> None:
    running = "\n".join(SUMMARY.splitlines()[:2])
    assert parse_loudness(running) is None
    assert parse_loudness("") is None


def test_parse_silence_is_nothing() -> None:
    assert (
        parse_loudness(
            SUMMARY.replace("I:         -14.3 LUFS", "I:         -70.0 LUFS")
        )
        is None
    )


def test_parse_ignores_the_range_threshold_lines() -> None:
    # "Threshold: -24.3 LUFS" and "LRA low: -17.0 LUFS" are not file loudness.
    text = SUMMARY.replace("I:         -14.3 LUFS", "I:          -9.8 LUFS")
    assert parse_loudness(text) == pytest.approx(-9.8)


# --- gain adjustment --------------------------------------------------------


def test_target_is_minus_eighteen() -> None:
    assert TARGET_LUFS == -18.0


@pytest.mark.parametrize(
    ("lufs", "gain"),
    [
        (-18.0, 0.0),
        (-8.0, -10.0),
        (-30.0, 12.0),
        (-14.34, -3.66),
        (5.0, -20.0),
        (-60.0, 20.0),
    ],
)
def test_gain_is_signed_and_bounded(lufs: float, gain: float) -> None:
    assert gain_db(lufs) == pytest.approx(gain)


def test_gain_is_rounded_to_hundredths() -> None:
    assert gain_db(-14.333333) == 3.67 * -1


# --- real ffmpeg ------------------------------------------------------------


def test_measure_hears_that_half_volume_is_six_decibels_quieter(tmp_path: Path) -> None:
    loud = measure(_tone(tmp_path / "a.flac", 1.0))
    quiet = measure(_tone(tmp_path / "b.flac", 0.5))
    assert -30.0 < loud < 0.0
    assert loud - quiet == pytest.approx(6.02, abs=0.3)


def test_measure_refuses_what_is_not_audio(tmp_path: Path) -> None:
    text = tmp_path / "Paper Lanterns.flac"
    text.write_bytes(b"not audio at all" * 100)
    with pytest.raises(LoudnessFailed) as failed:
        measure(text)
    assert "Paper" not in str(failed.value)
    with pytest.raises(LoudnessFailed) as missing:
        measure(tmp_path / "Glass Harbor.flac")
    assert "Glass" not in str(missing.value)


def test_measure_of_silence_fails_instead_of_inventing_a_number(tmp_path: Path) -> None:
    with pytest.raises(LoudnessFailed):
        measure(_tone(tmp_path / "s.flac", 0.0))


def test_measure_does_not_hang_past_its_timeout(tmp_path: Path) -> None:
    with pytest.raises(LoudnessFailed):
        measure(_tone(tmp_path / "long.flac", 1.0, seconds=600), timeout_s=0.01)


# --- measurement storage ----------------------------------------------------


def test_gain_is_returned_for_the_measured_file(base: str, tmp_path: Path) -> None:
    song = tmp_path / "song.flac"
    song.write_bytes(b"x" * 1000)

    async def work(conn: asyncpg.Connection) -> Any:
        assert await gain_for(conn, song) is None
        await remember(conn, song, -8.0)
        return await gain_for(conn, song)

    assert _run(base, work) == pytest.approx(-10.0)


def test_changed_file_does_not_get_the_old_measurement(
    base: str, tmp_path: Path
) -> None:
    song = tmp_path / "song.flac"
    song.write_bytes(b"x" * 1000)

    async def work(conn: asyncpg.Connection) -> Any:
        await remember(conn, song, -8.0)
        song.write_bytes(b"y" * 1001)
        other_size = await gain_for(conn, song)
        await remember(conn, song, -8.0)
        stat = song.stat()
        song.write_bytes(b"z" * 1001)
        os.utime(song, ns=(stat.st_atime_ns, stat.st_mtime_ns + 5_000_000_000))
        other_time = await gain_for(conn, song)
        await remember(conn, song, -8.0)
        song.unlink()
        return other_size, other_time, await gain_for(conn, song)

    assert _run(base, work) == (None, None, None)


def test_remember_replaces_and_forget_removes(base: str, tmp_path: Path) -> None:
    song = tmp_path / "song.flac"
    song.write_bytes(b"x" * 1000)

    async def work(conn: asyncpg.Connection) -> Any:
        await remember(conn, song, -8.0)
        await remember(conn, song, -20.0)
        second = await gain_for(conn, song)
        rows = await conn.fetchval("SELECT count(*) FROM file_loudness")
        await forget(conn, song)
        return (
            second,
            rows,
            await gain_for(conn, song),
            await conn.fetchval("SELECT count(*) FROM file_loudness"),
        )

    second, rows, after, left = _run(base, work)
    assert second == pytest.approx(2.0)
    assert (rows, after, left) == (1, None, 0)


def test_failed_measurement_gives_no_gain(base: str, tmp_path: Path) -> None:
    song = tmp_path / "song.flac"
    song.write_bytes(b"x" * 1000)

    async def work(conn: asyncpg.Connection) -> Any:
        await remember(conn, song, None)
        return await gain_for(conn, song)

    assert _run(base, work) is None


# --- file pass --------------------------------------------------------------


def test_pending_measures_each_file_once(base: str, tmp_path: Path) -> None:
    a, b = tmp_path / "a.flac", tmp_path / "b.flac"
    a.write_bytes(b"a" * 10)
    b.write_bytes(b"b" * 20)
    seen: list[str] = []

    def fake(path: Path) -> float:
        seen.append(path.name)
        return -8.0 if path.name == "a.flac" else -28.0

    async def work(conn: asyncpg.Connection) -> Any:
        first = await measure_pending(conn, [a, b], measure=fake)
        second = await measure_pending(conn, [a, b], measure=fake)
        return first, second, await gain_for(conn, a), await gain_for(conn, b)

    first, second, gain_a, gain_b = _run(base, work)
    assert (first, second) == (2, 0)
    assert sorted(seen) == ["a.flac", "b.flac"]
    assert (gain_a, gain_b) == (pytest.approx(-10.0), pytest.approx(10.0))


def test_pending_remembers_a_failure_and_does_not_retry(
    base: str, tmp_path: Path
) -> None:
    bad, good = tmp_path / "bad.flac", tmp_path / "good.flac"
    bad.write_bytes(b"a" * 10)
    good.write_bytes(b"b" * 20)
    calls: list[str] = []

    def fake(path: Path) -> float:
        calls.append(path.name)
        if path.name == "bad.flac":
            raise LoudnessFailed("no audio")
        return -18.0

    async def work(conn: asyncpg.Connection) -> Any:
        await measure_pending(conn, [bad, good], measure=fake)
        await measure_pending(conn, [bad, good], measure=fake)
        return await gain_for(conn, bad), await gain_for(conn, good)

    assert _run(base, work) == (None, pytest.approx(0.0))
    assert sorted(calls) == ["bad.flac", "good.flac"], (
        "failure was remembered, and the good file was measured despite neighbor failure"
    )


def test_pending_measures_again_when_the_file_changed(
    base: str, tmp_path: Path
) -> None:
    song = tmp_path / "song.flac"
    song.write_bytes(b"a" * 10)
    answers = iter([-8.0, -28.0])

    async def work(conn: asyncpg.Connection) -> Any:
        await measure_pending(conn, [song], measure=lambda _: next(answers))
        song.write_bytes(b"b" * 2000)
        again = await measure_pending(conn, [song], measure=lambda _: next(answers))
        return again, await gain_for(conn, song)

    assert _run(base, work) == (1, pytest.approx(10.0))


def test_pending_skips_a_file_that_is_gone(base: str, tmp_path: Path) -> None:
    def fake(path: Path) -> float:
        raise AssertionError("a vanished file is not measured")

    async def work(conn: asyncpg.Connection) -> Any:
        count = await measure_pending(conn, [tmp_path / "gone.flac"], measure=fake)
        return count, await conn.fetchval("SELECT count(*) FROM file_loudness")

    assert _run(base, work) == (0, 0)


def test_pending_does_not_block_the_server_while_ffmpeg_runs(
    base: str, tmp_path: Path
) -> None:
    song = tmp_path / "song.flac"
    song.write_bytes(b"a" * 10)
    ticks = 0

    def slow(path: Path) -> float:
        import time

        time.sleep(0.3)
        return -18.0

    async def work(conn: asyncpg.Connection) -> Any:
        nonlocal ticks

        async def heartbeat() -> None:
            nonlocal ticks
            while True:
                await asyncio.sleep(0.02)
                ticks += 1

        beat = asyncio.create_task(heartbeat())
        await measure_pending(conn, [song], measure=slow)
        beat.cancel()

    _run(base, work)
    assert ticks >= 5, "measurement runs in a separate thread, server responds during this time"


def test_file_replaced_during_measurement_is_not_remembered(
    base: str, tmp_path: Path
) -> None:
    song = tmp_path / "song.flac"
    song.write_bytes(b"a" * 10)
    answers = iter([-8.0, -28.0])

    def fake(path: Path) -> float:
        value = next(answers)
        if value == -8.0:
            # While ffmpeg was reading the old file, a new one replaced it.
            song.write_bytes(b"b" * 3000)
        return value

    async def work(conn: asyncpg.Connection) -> Any:
        first = await measure_pending(conn, [song], measure=fake)
        between = await gain_for(conn, song)
        rows = await conn.fetchval("SELECT count(*) FROM file_loudness")
        second = await measure_pending(conn, [song], measure=fake)
        return first, between, rows, second, await gain_for(conn, song)

    assert _run(base, work) == (0, None, 0, 1, pytest.approx(10.0)), (
        "loudness of the old file was not assigned to the new one"
    )


def test_failure_on_a_file_replaced_meanwhile_is_not_remembered(
    base: str, tmp_path: Path
) -> None:
    song = tmp_path / "song.flac"
    song.write_bytes(b"a" * 10)
    calls = 0

    def fake(path: Path) -> float:
        nonlocal calls
        calls += 1
        if calls == 1:
            # File was still being written: ffmpeg stumbled on partial content.
            song.write_bytes(b"b" * 3000)
            raise LoudnessFailed("no audio")
        return -18.0

    async def work(conn: asyncpg.Connection) -> Any:
        await measure_pending(conn, [song], measure=fake)
        await measure_pending(conn, [song], measure=fake)
        return await gain_for(conn, song)

    assert _run(base, work) == pytest.approx(0.0)
    assert calls == 2


def test_outage_is_not_remembered_as_a_bad_file(base: str, tmp_path: Path) -> None:
    song = tmp_path / "song.flac"
    song.write_bytes(b"a" * 10)
    calls = 0

    def fake(path: Path) -> float:
        nonlocal calls
        calls += 1
        if calls == 1:
            raise LoudnessUnavailable("ffmpeg unavailable")
        return -8.0

    async def work(conn: asyncpg.Connection) -> Any:
        first = await measure_pending(conn, [song], measure=fake)
        rows = await conn.fetchval("SELECT count(*) FROM file_loudness")
        second = await measure_pending(conn, [song], measure=fake)
        return first, rows, second, await gain_for(conn, song)

    assert _run(base, work) == (0, 0, 1, pytest.approx(-10.0)), (
        "server without ffmpeg does not mark all files as bad forever"
    )


def test_no_ffmpeg_and_timeout_are_outages_not_bad_files(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    song = _tone(tmp_path / "a.flac", 1.0, seconds=600)
    with pytest.raises(LoudnessUnavailable):
        measure(song, timeout_s=0.01)
    monkeypatch.setenv("PATH", str(tmp_path))
    with pytest.raises(LoudnessUnavailable):
        measure(song)


def test_not_audio_is_a_bad_file_not_an_outage(tmp_path: Path) -> None:
    text = tmp_path / "x.flac"
    text.write_bytes(b"not audio at all" * 100)
    with pytest.raises(LoudnessFailed) as failed:
        measure(text)
    assert not isinstance(failed.value, LoudnessUnavailable)


def test_measure_reads_a_relative_name_with_a_colon(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _tone(tmp_path / "a:b.flac", 1.0)
    monkeypatch.chdir(tmp_path)
    assert -30.0 < measure(Path("a:b.flac")) < 0.0


def test_measure_survives_megabytes_of_ffmpeg_noise(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    fake = tmp_path / "ffmpeg"
    fake.write_text(
        "#!/bin/sh\n"
        "i=0; while [ $i -lt 20000 ]; do echo '[mp3 @ 0x1] Header missing, this line is noise and it is long enough' >&2; i=$((i+1)); done\n"
        "printf '[Parsed_ebur128_0 @ 0x1] Summary:\\n\\n  Integrated loudness:\\n    I:         -11.5 LUFS\\n    Threshold: -21.5 LUFS\\n' >&2\n"
    )
    fake.chmod(0o755)
    song = tmp_path / "song.flac"
    song.write_bytes(b"x" * 10)
    monkeypatch.setenv("PATH", f"{tmp_path}:/bin:/usr/bin")
    assert measure(song) == pytest.approx(-11.5)


# --- log --------------------------------------------------------------------


def test_log_names_neither_path_nor_file(
    base: str, tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    folder = tmp_path / "Glass Harbor"
    folder.mkdir()
    good = folder / "Paper Lanterns.flac"
    good.write_bytes(b"a" * 10)
    bad = folder / "Cold Morning.flac"
    bad.write_bytes(b"b" * 20)

    def fake(path: Path) -> float:
        if path == bad:
            raise LoudnessFailed(f"cannot read {path}")
        return -18.0

    with caplog.at_level(logging.DEBUG):
        _run(base, lambda conn: measure_pending(conn, [good, bad], measure=fake))
    text = caplog.text
    assert "loudness" in text
    for word in (
        "Glass",
        "Harbor",
        "Paper",
        "Lanterns",
        "Cold",
        "Morning",
        str(tmp_path),
    ):
        assert word not in text


def test_migration_is_numbered_and_repeatable(base: str) -> None:
    name = Path(__file__).resolve().parents[1] / "migrations" / "050_loudness.sql"
    assert name.exists()
    asyncio.run(apply(base))
    columns = _run(
        base,
        lambda conn: conn.fetch(
            "SELECT column_name FROM information_schema.columns WHERE table_name = 'file_loudness'"
        ),
    )
    assert "user_id" not in {row["column_name"] for row in columns}, (
        "measurement is about the file, not about the user"
    )
