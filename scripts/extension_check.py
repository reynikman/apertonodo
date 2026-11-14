#!/usr/bin/env python3
"""Check extension contract against `contracts/extension-api.md` (FT-587).

    python3 scripts/extension_check.py --url http://127.0.0.1:8080 --artist "Slipknot" --title "Duality"

The `--artist/--title` track must exist in the extension. Each rule is a line "ok ..." or "RED ...".
Exit code: 0 — all rules satisfied; 1 — at least one violated; 2 — extension does not respond at all
(this is not a contract violation, but an unstarted service — red of this kind does not count).
Standard library only: check runs anywhere, without server environment; nearby in
`contracts/genres.txt` of the same repository copy are genre words.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

ID = re.compile(r"[A-Za-z0-9._~-]{1,200}")
FORMATS = {"mp3", "flac", "ogg", "opus", "m4a", "wav"}
QUALITIES = {"lossy", "lossless", "hires", "analog"}
GENRES_TXT = Path(__file__).resolve().parents[1] / "contracts" / "genres.txt"
GENRES = {line for line in GENRES_TXT.read_text("utf-8").splitlines() if line and not line.startswith("#")}
NOWHERE = {"artist": "Qzxv Nonexistent Ensemble", "title": "Wvqz Never Recorded Piece"}


class Down(Exception):
    pass


def _call(
    base: str, method: str, path: str, body: Any = None, headers: dict[str, str] | None = None
) -> tuple[int, dict[str, str], bytes]:
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(base.rstrip("/") + path, data=data, method=method, headers=dict(headers or {}))
    if data is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=40) as response:
            return response.status, {k.lower(): v for k, v in response.headers.items()}, response.read()
    except urllib.error.HTTPError as error:
        return error.code, {k.lower(): v for k, v in error.headers.items()}, error.read()
    except (urllib.error.URLError, ConnectionError, TimeoutError) as error:
        raise Down(str(error)) from error


def _json(raw: bytes) -> Any:
    try:
        return json.loads(raw)
    except ValueError:
        return None


def _looks_like_audio(fmt: str, head: bytes) -> bool:
    if fmt == "mp3":
        return head.startswith(b"ID3") or (len(head) > 1 and head[0] == 0xFF and head[1] & 0xE0 == 0xE0)
    if fmt == "flac":
        return head.startswith(b"fLaC")
    if fmt in {"ogg", "opus"}:
        return head.startswith(b"OggS")
    if fmt == "m4a":
        return head[4:8] == b"ftyp"
    if fmt == "wav":
        return head.startswith(b"RIFF")
    return False


def check(base: str, artist: str, title: str) -> list[tuple[bool, str]]:
    results: list[tuple[bool, str]] = []

    def rule(ok: bool, name: str, detail: str = "") -> bool:
        results.append((ok, name + (f": {detail}" if detail and not ok else "")))
        return ok

    status, _, raw = _call(base, "GET", "/v1/info")
    info = _json(raw) or {}
    rule(
        status == 200
        and info.get("api") == 1
        and isinstance(info.get("name"), str)
        and re.fullmatch(r"[a-z][a-z0-9-]{0,31}", info["name"]) is not None
        and info.get("kind") == "music"
        and isinstance(info.get("features"), list),
        "info: api 1, name, kind music, features",
        f"{status} {raw[:200]!r}",
    )
    features = set(info.get("features") or [])

    status, _, raw = _call(base, "GET", "/v1/health")
    rule(status == 200 and (_json(raw) or {}).get("ok") is True, "health: 200 ok", f"{status}")

    track = {"artist": artist, "title": title}
    status, _, raw = _call(base, "POST", "/v1/find", {"track": track, "limit": 4})
    items = (_json(raw) or {}).get("items")
    shape = status == 200 and isinstance(items, list) and 0 < len(items) <= 4
    for item in items or []:
        shape = shape and (
            isinstance(item, dict)
            and isinstance(item.get("id"), str)
            and ID.fullmatch(item["id"]) is not None
            and isinstance(item.get("confidence"), (int, float))
            and 0 <= item["confidence"] <= 1
            and item.get("format") in FORMATS
            and (item.get("size") is None or isinstance(item.get("size"), int))
            and item.get("quality") in QUALITIES
        )
    if not rule(shape, "find: own track found, fields and numbers per contract", f"{status} {raw[:300]!r}"):
        return results
    confidences = [item["confidence"] for item in items]
    rule(confidences == sorted(confidences, reverse=True), "find: best first", f"{confidences}")

    status, _, raw = _call(base, "POST", "/v1/find", {"track": NOWHERE, "limit": 4})
    nowhere = (_json(raw) or {}).get("items")
    rule(
        status == 200 and isinstance(nowhere, list) and all(item.get("confidence", 1) < 0.75 for item in nowhere),
        "find: non-existent track does not get confidence 0.75",
        f"{status} {raw[:200]!r}",
    )

    status, _, _ = _call(base, "POST", "/v1/find", {"limit": 4})
    rule(status in (400, 422), "find: request without track — 400/422", f"{status}")

    best = items[0]
    file_id = best["id"]
    # `preparing` and `failed/unavailable` are "not yet" (FT-879: a busy engine answers so and then prepares the
    # file anyway); `wrong_track` and any other refusal are final.
    started = time.monotonic()
    deadline = started + 180
    state: dict[str, Any] = {}
    while True:
        status, _, raw = _call(base, "POST", "/v1/prepare", {"id": file_id})
        state = _json(raw) or {}
        pending = status == 200 and (
            state.get("state") == "preparing"
            or (state.get("state") == "failed" and state.get("reason") == "unavailable")
        )
        if not pending or time.monotonic() >= deadline:
            break
        time.sleep(0.5)
    waited = time.monotonic() - started
    if not rule(
        status == 200 and state.get("state") == "ready",
        "prepare: best number ready",
        f"last answer {status} {state}, waited {waited:.0f} s of 180",
    ):
        return results
    status, _, raw = _call(base, "POST", "/v1/prepare", {"id": file_id})
    rule(status == 200 and (_json(raw) or {}).get("state") == "ready", "prepare: retry is ready immediately", f"{status}")

    status, _, raw = _call(base, "POST", "/v1/prepare", {"id": "no-such-id-ft587"})
    rule(status == 404, "prepare: foreign number — 404", f"{status}")

    status, headers, first = _call(base, "GET", f"/v1/files/{file_id}", headers={"Range": "bytes=0-1023"})
    total = re.fullmatch(r"bytes 0-1023/(\d+)", headers.get("content-range", ""))
    rule(
        status == 206 and len(first) == 1024 and total is not None and headers.get("accept-ranges") == "bytes",
        "files: Range 0-1023 — 206, Content-Range, exactly 1024 bytes",
        f"{status} {headers.get('content-range')} {len(first)}",
    )
    rule(
        headers.get("content-type", "").startswith("audio/") and _looks_like_audio(best["format"], first[:16]),
        "files: file start — sound of declared format",
        f"{headers.get('content-type')} {first[:8]!r}",
    )
    status, _, second = _call(base, "GET", f"/v1/files/{file_id}", headers={"Range": "bytes=1024-2047"})
    status_full, _, whole = _call(base, "GET", f"/v1/files/{file_id}")
    rule(
        status == 206 and status_full == 200 and whole[:2048] == first + second,
        "files: Range chunks match whole file",
        f"{status} {status_full}",
    )
    size = int(total.group(1)) if total else len(whole)
    status, _, _ = _call(base, "GET", f"/v1/files/{file_id}", headers={"Range": f"bytes={size + 10}-"})
    rule(status == 416, "files: Range past end — 416", f"{status}")
    status, _, _ = _call(base, "GET", "/v1/files/no-such-id-ft587")
    rule(status == 404, "files: foreign number — 404", f"{status}")

    if "pins" in features:
        status, _, _ = _call(base, "POST", "/v1/pins", {"id": file_id, "pinned": True})
        status_off, _, _ = _call(base, "POST", "/v1/pins", {"id": file_id, "pinned": False})
        rule(status == 204 and status_off == 204, "pins: pin and unpin — 204", f"{status} {status_off}")

    if "catalog" in features:
        status, headers, raw = _call(base, "GET", "/v1/catalog")
        lines = [_json(line) for line in raw.decode("utf-8", "replace").splitlines() if line.strip()]
        rule(
            status == 200
            and headers.get("content-type", "").startswith("application/x-ndjson")
            and len(lines) > 0
            and all(
                isinstance(line, dict)
                and isinstance(line.get("artist"), str)
                and isinstance(line.get("title"), str)
                and isinstance(line.get("popularity"), int)
                and line["popularity"] >= 0
                for line in lines
            ),
            "catalog: NDJSON with artist, title, popularity",
            f"{status} {raw[:200]!r}",
        )
        given = {str(line.get("genre")) for line in lines if isinstance(line, dict) and "genre" in line}
        strangers = sorted(given - GENRES)
        rule(status == 200 and not strangers, "catalog: genre from contracts/genres.txt or without genre", ", ".join(strangers[:5]))

    if "has" in features:
        own = {"artist": artist, "title": title}
        # Four pairs interleaved: response sorting or mock [true, false] will not pass the order check.
        status, _, raw = _call(base, "POST", "/v1/has", {"pairs": [own, NOWHERE, own, NOWHERE]})
        body = _json(raw) if status == 200 else None
        hits = body.get("hits") if isinstance(body, dict) else None
        whole = isinstance(hits, list) and len(hits) == 4 and all(isinstance(hit, bool) for hit in hits)
        rule(whole and hits == [True, False, True, False], "has: answer for each pair, in order", f"{status} {raw[:200]!r}")
        rule(whole and hits[0] is True and hits[2] is True, "has: own pair — true", f"{hits}")
        rule(whole and hits[1] is False and hits[3] is False, "has: non-existent pair — false", f"{hits}")
        status, _, _ = _call(base, "POST", "/v1/has", {"pairs": [NOWHERE] * 51})
        status_none, _, _ = _call(base, "POST", "/v1/has", {"pairs": []})
        rule(
            status in (400, 422) and status_none in (400, 422),
            "has: more than 50 pairs — rejection, empty request — rejection",
            f"{status} {status_none}",
        )

    status, _, _ = _call(base, "POST", "/v1/failed", {"id": file_id, "reason": "wrong_track"})
    rule(status == 204, "failed: complaint — 204", f"{status}")
    status, _, raw = _call(base, "POST", "/v1/find", {"track": track, "limit": 4})
    after = {item["id"]: item["confidence"] for item in (_json(raw) or {}).get("items") or []}
    rule(
        file_id not in after or after[file_id] < best["confidence"],
        "failed: after complaint number is lower or gone",
        f"was {best['confidence']}, became {after.get(file_id)}",
    )
    return results


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--url", required=True)
    parser.add_argument("--artist", required=True)
    parser.add_argument("--title", required=True)
    args = parser.parse_args()
    try:
        results = check(args.url, args.artist, args.title)
    except Down as error:
        print(f"extension does not respond: {error}")
        return 2
    for ok, name in results:
        print(("ok       " if ok else "RED      ") + name)
    failed = sum(1 for ok, _ in results if not ok)
    print(f"contract: {len(results) - failed} of {len(results)}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
