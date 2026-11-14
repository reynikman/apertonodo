"""Stage timing for each Play (FT-786): a single line with numbers and outcome, without user or names."""

import logging
import time
from datetime import timedelta
from typing import Any, Callable

logger = logging.getLogger("apertonodo")

STAGES = ("find", "prepare", "token", "first_byte", "first_256k")
OUTCOMES = ("waiting", "played", "no_source", "low_confidence", "not_ready", "stalled", "error")
PLAY_TIMING_KEEP_DAYS = 30
SWARM_LIMITS = {"peers": 100_000, "speed_bps": 2_000_000_000, "have_pct": 100}
VIA = ("link", "file", "cache")


class Timer:
    def __init__(self, track_id: str, prepared: bool, clock: Callable[[], float] = time.monotonic) -> None:
        self.track_id = track_id
        self.prepared = prepared
        self.source: str | None = None
        self._clock = clock
        self._began = clock()
        self._ms: dict[str, int] = {}
        self._swarm: dict[str, Any] = {}

    def mark(self, stage: str) -> None:
        if stage not in STAGES:
            raise ValueError(stage)
        self._ms.setdefault(stage, round((self._clock() - self._began) * 1000))

    def swarm(self, stats: Any) -> None:
        """Swarm stats from `ready` response: only valid entries taken — integers within bounds and one of three words."""
        if not isinstance(stats, dict):
            return
        self._swarm = {
            key: value
            for key, high in SWARM_LIMITS.items()
            if (value := stats.get(key)) is not None
            and type(value) is int
            and 0 <= value <= high
        }
        if stats.get("via") in VIA:
            self._swarm["via"] = stats["via"]

    def get(self, stage: str) -> int | None:
        return self._ms.get(stage)

    def row(self, outcome: str) -> dict[str, Any]:
        if outcome not in OUTCOMES:
            raise ValueError(outcome)
        return {
            "track_id": self.track_id,
            "source": self.source,
            "prepared": self.prepared,
            **{f"{stage}_ms": self._ms.get(stage) for stage in STAGES},
            "outcome": outcome,
            **{key: self._swarm.get(key) for key in (*SWARM_LIMITS, "via")},
        }


async def write(database_url: str | None, row: dict[str, Any]) -> int | None:
    if not database_url:
        return None
    import asyncpg
    try:
        conn = await asyncpg.connect(database_url, timeout=3)
        try:
            return await conn.fetchval(
                """INSERT INTO play_timing (track_id, source, prepared, find_ms, prepare_ms, token_ms,
                                            first_byte_ms, first_256k_ms, outcome, peers, speed_bps, have_pct, via)
                   VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13) RETURNING id""",
                row["track_id"], row["source"], row["prepared"], row["find_ms"], row["prepare_ms"],
                row["token_ms"], row["first_byte_ms"], row["first_256k_ms"], row["outcome"],
                row["peers"], row["speed_bps"], row["have_pct"], row["via"],
            )
        finally:
            await conn.close()
    except Exception as exc:
        logger.warning("play timing failed: %s", type(exc).__name__)
        return None


async def stream_done(
    database_url: str | None, row_id: int | None, *,
    first_byte_ms: int | None, first_256k_ms: int | None, outcome: str,
) -> None:
    if not database_url or row_id is None:
        return
    import asyncpg
    try:
        conn = await asyncpg.connect(database_url, timeout=3)
        try:
            await conn.execute(
                """UPDATE play_timing SET first_byte_ms = $2, first_256k_ms = $3, outcome = $4
                   WHERE id = $1 AND outcome = 'waiting'""",
                row_id, first_byte_ms, first_256k_ms, outcome,
            )
        finally:
            await conn.close()
    except Exception as exc:
        logger.warning("play timing failed: %s", type(exc).__name__)


async def purge(conn: Any, older_than: timedelta) -> int:
    done = await conn.execute("DELETE FROM play_timing WHERE at < now() - $1::interval", older_than)
    return int(done.rsplit(" ", 1)[-1])
