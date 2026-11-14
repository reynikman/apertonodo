"""FT-872: the daily digest — one page a day from what the server already records.

`python -m app.daily_digest [--day YYYY-MM-DD]` reads the day (Moscow time, default yesterday) from
play_timing, play_failures, problem_reports and listens, and prints a Markdown page to stdout.
`build` and `render` are pure. Read-only; the page holds artist names and report texts, so it is
printed and never logged (AGENTS.md).
"""

from __future__ import annotations

import argparse
import asyncio
import math
import os
import sys
from collections import Counter
from datetime import date, datetime, timedelta, timezone

import asyncpg

from app.store import load_track

MOSCOW = timezone(timedelta(hours=3))
SLOWEST = 10
TOP_ARTISTS = 10

_TABLES = (
    ("timing", "play_timing", "at"),
    ("failures", "play_failures", "at"),
    ("reports", "problem_reports", "created_at"),
    ("listens", "listens", "played_at"),
)


def _median(values: list[int]) -> int | None:
    if not values:
        return None
    s = sorted(values)
    mid = len(s) // 2
    return s[mid] if len(s) % 2 else (s[mid - 1] + s[mid]) // 2


def _p90(values: list[int]) -> int | None:
    if not values:
        return None
    s = sorted(values)
    return s[max(math.ceil(0.9 * len(s)) - 1, 0)]


def _group(rows: list[dict]) -> dict:
    first = [r["first_byte_ms"] for r in rows if r.get("first_byte_ms") is not None]
    return {
        "count": len(rows),
        "first_byte_median_ms": _median(first),
        "first_byte_p90_ms": _p90(first),
        "first_byte_max_ms": max(first) if first else None,
    }


def build(data: dict) -> dict:
    timing = data["timing"]
    played = [r for r in timing if r["outcome"] == "played"]
    slowest = sorted(
        (r for r in played if r.get("first_byte_ms") is not None),
        key=lambda r: r["first_byte_ms"],
        reverse=True,
    )[:SLOWEST]
    failures = data["failures"]
    return {
        "day": data["day"],
        "plays": {
            "total": len(timing),
            "played": len(played),
            "by_outcome": dict(Counter(r["outcome"] for r in timing).most_common()),
            # Cache is judged by where the bytes came from (via). `prepared` means "the app prepares
            # the next song in advance", not "from cache": by it the 14.10 digest gave the cache 3 s instead of 0.6.
            "cache": _group([r for r in played if r.get("via") == "cache"]),
            "new": _group([r for r in played if r.get("via") != "cache"]),
            "slowest": [
                {
                    k: r.get(k)
                    for k in (
                        "track_id",
                        "source",
                        "via",
                        "first_byte_ms",
                        "peers",
                        "speed_bps",
                    )
                }
                for r in slowest
            ],
        },
        "failures": {
            "total": len(failures),
            "by_kind": dict(Counter(r["kind"] for r in failures).most_common()),
            "artists": Counter(r["artist"] or "?" for r in failures).most_common(
                TOP_ARTISTS
            ),
        },
        "reports": list(data["reports"]),
        "listens": {
            "total": len(data["listens"]),
            "people": len({r["user_id"] for r in data["listens"]}),
        },
    }


def _ms(value: int | None) -> str:
    return "—" if value is None else f"{value} мс"


def _group_line(title: str, g: dict) -> str:
    return (
        f"- {title}: {g['count']}; первый байт: медиана {_ms(g['first_byte_median_ms'])}, "
        f"p90 {_ms(g['first_byte_p90_ms'])}, максимум {_ms(g['first_byte_max_ms'])}"
    )


def render(digest: dict) -> str:
    p, f, listens = digest["plays"], digest["failures"], digest["listens"]
    out = [f"# Сводка сервера за {digest['day']}", "", "## Play", ""]
    out.append(f"- Всего: {p['total']}, сыграло: {p['played']}")
    for outcome, n in p["by_outcome"].items():
        out.append(f"  - {outcome}: {n}")
    out.append(_group_line("Из кэша", p["cache"]))
    out.append(_group_line("Новые песни", p["new"]))
    out += ["", f"### {SLOWEST} самых медленных", ""]
    if p["slowest"]:
        for r in p["slowest"]:
            kind = "кэш" if r.get("via") == "cache" else "новая"
            track = r.get("name") or f"трек {r['track_id']}"
            out.append(
                f"- {_ms(r['first_byte_ms'])} — {kind}, {r['source']}, {track}, соединений {'—' if r['peers'] is None else r['peers']}"
            )
    else:
        out.append("- нет")
    out += ["", "## Отказы", "", f"- Всего: {f['total']}"]
    for kind, n in f["by_kind"].items():
        out.append(f"  - {kind}: {n}")
    out += ["", f"### Исполнители с отказами (до {TOP_ARTISTS})", ""]
    out += [f"- {a}: {n}" for a, n in f["artists"]] or ["- нет"]
    out += ["", "## Жалобы", ""]
    for r in digest["reports"]:
        out.append(f"- {r['reason']} ({r['place']}), {r['artist'] or '—'}: {r['text']}")
    if not digest["reports"]:
        out.append("- нет")
    out += [
        "",
        "## Прослушивания",
        "",
        f"- Всего: {listens['total']}, людей: {listens['people']}",
        "",
    ]
    return "\n".join(out)


def _bounds(day: date) -> tuple[datetime, datetime]:
    start = datetime(day.year, day.month, day.day, tzinfo=MOSCOW)
    return start, start + timedelta(days=1)


async def fetch(url: str, day: date) -> dict:
    start, end = _bounds(day)
    conn = await asyncpg.connect(url)
    try:
        data: dict = {"day": day}
        for key, table, column in _TABLES:
            rows = await conn.fetch(
                f"SELECT * FROM {table} WHERE {column} >= $1 AND {column} < $2",
                start,
                end,
            )
            data[key] = [dict(r) for r in rows]
        return data
    finally:
        await conn.close()


async def name_slowest(url: str, digest: dict) -> None:
    """Put "Artist — Title" on the slow rows the catalog knows; the rest keep their number."""
    for row in digest["plays"]["slowest"]:
        try:
            track = await load_track(url, row["track_id"])
        except (ValueError, asyncpg.PostgresError):
            track = None
        if track:
            row["name"] = f"{track['artist']} — {track['title']}"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="app.daily_digest")
    parser.add_argument(
        "--day",
        type=date.fromisoformat,
        help="YYYY-MM-DD, Moscow time; default yesterday",
    )
    args = parser.parse_args(argv)
    url = os.environ.get("DATABASE_URL")
    if not url:
        print("DATABASE_URL не задан", file=sys.stderr)
        return 2
    day = args.day or (datetime.now(MOSCOW) - timedelta(days=1)).date()
    digest = build(asyncio.run(fetch(url, day)))
    asyncio.run(name_slowest(url, digest))
    print(render(digest))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
