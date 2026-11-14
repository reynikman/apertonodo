"""Nightly live check (Р-A12, FT-450): catches what the owner previously found.

`scripts/nightly_check.py` calls the API like the app: genres, letters,
artists, albums, search — and a persistent core of owner findings
(`scripts/nightly_core.tsv`). Here it runs against a fake server
with a small catalog: green on healthy, red with a reason tag on
each injected failure. Otherwise a green night proves nothing.
"""

from __future__ import annotations

import copy
import json
import os
import subprocess
import sys
import threading
import time
from collections.abc import Callable, Iterator
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, unquote, urlsplit

import pytest
import yaml
from not_in_slice import needs

pytestmark = needs("scripts/nightly_check.py", "scripts/nightly_core.tsv", ".gitlab-ci.yml")

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "nightly_check.py"
KEY = "nightly-test-key"


def _album(artist: str, n: int) -> dict[str, Any]:
    return {
        "album": {
            "id": f"{artist}-al{n}",
            "title": f"{artist} Album {n}",
            "artist": artist,
            "playable": True,
        },
        "tracks": [
            {
                "id": f"{artist}-al{n}-t{i}",
                "title": f"{artist} Song {i}",
                "artist": artist,
                "duration_ms": 200000 + i,
                "position": i,
                "playable": True,
            }
            for i in (1, 2)
        ],
    }


def _catalog() -> dict[str, Any]:
    genres = {
        "rock": ["Alpha", "Beta", "Gamma"],
        "electronic": [f"E{n}" for n in range(10)],
        "worldwide": ["Кино"],
    }
    letters = {"A": ["Alpha"], "К": ["Кино"], "あ": ["あいみょん"]}
    names = sorted(
        {n for group in (*genres.values(), *letters.values()) for n in group}
    )
    albums = {name: [_album(name, 1), _album(name, 2)] for name in names}
    return {
        "genres": genres,
        "letters": letters,
        "albums": albums,
        "slow_search_s": 0.0,
        "search_override": {},
        "status": {},
    }


class _Api(BaseHTTPRequestHandler):
    cat: dict[str, Any]

    def log_message(self, *args: Any) -> None:
        pass

    def _send(self, code: int, body: Any) -> None:
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:  # noqa: N802
        cat = self.cat
        if self.headers.get("x-flowtune-key") != KEY:
            return self._send(401, {"status": "unauthorized"})
        url = urlsplit(self.path)
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        if url.path in cat["status"]:
            return self._send(cat["status"][url.path], {"status": "error"})
        if url.path == "/v1/genres":
            return self._send(
                200,
                {
                    "genres": [
                        {"id": g, "name": g, "artists": len(a)}
                        for g, a in cat["genres"].items()
                    ]
                },
            )
        if url.path == "/v1/letters":
            return self._send(
                200,
                {
                    "letters": [
                        {"letter": k, "artists": len(v)}
                        for k, v in cat["letters"].items()
                    ]
                },
            )
        if url.path == "/v1/artists":
            pool = cat["genres"].get(q.get("genre", ""), []) or cat["letters"].get(
                q.get("letter", ""), []
            )
            offset, limit = int(q.get("offset", 0)), int(q.get("limit", 100))
            return self._send(
                200,
                {
                    "artists": [
                        {"name": n, "photo": None}
                        for n in pool[offset : offset + limit]
                    ],
                    "total": len(pool),
                },
            )
        if url.path == "/v1/artist":
            name = q.get("name", "")
            if name not in cat["albums"]:
                return self._send(404, {"status": "not_found"})
            return self._send(
                200,
                {
                    "artist": {"id": f"id-{name}", "name": name, "aliases": []},
                    "albums": [a["album"] for a in cat["albums"][name]],
                },
            )
        if url.path.startswith("/v1/albums/"):
            album_id = unquote(url.path.rsplit("/", 1)[1])
            for albums in cat["albums"].values():
                for a in albums:
                    if a["album"]["id"] == album_id:
                        return self._send(200, a)
            return self._send(404, {"status": "not_found"})
        if url.path == "/v1/search":
            time.sleep(cat["slow_search_s"])
            text = q.get("q", "")
            if text in cat["search_override"]:
                return self._send(200, cat["search_override"][text])
            artists = [n for n in cat["albums"] if n.casefold() in text.casefold()]
            tracks = [
                t
                for n in artists
                for a in cat["albums"][n]
                for t in a["tracks"]
                if t["title"].casefold() in text.casefold()
                or text.casefold() == n.casefold()
            ]
            return self._send(
                200, {"artists": [{"name": n} for n in artists], "tracks": tracks[:20]}
            )
        return self._send(404, {"status": "not_found"})


@pytest.fixture
def api() -> Iterator[tuple[str, dict[str, Any]]]:
    cat = _catalog()
    handler = type("Api", (_Api,), {"cat": cat})
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_address[1]}", cat
    finally:
        server.shutdown()
        server.server_close()


CORE = "query\tartist\ttrack\nbeta\tBeta\t\nalpha song 2\tAlpha\tAlpha Song 2\n"


def _run(base: str, tmp: Path, **env: str) -> subprocess.CompletedProcess[str]:
    core = tmp / "core.tsv"
    if not core.exists():
        core.write_text(CORE)
    full = {
        "PATH": os.environ.get("PATH", ""),
        "MUSIC_API_BASE_URL": base,
        "MUSIC_API_KEY": KEY,
        "NIGHTLY_SEED": "2026-10-01",
        "NIGHTLY_CORE": str(core),
        "NIGHTLY_SUMMARY": str(tmp / "summary.txt"),
        "NIGHTLY_PER_GENRE": "3",
        **env,
    }
    return subprocess.run(
        [sys.executable, str(SCRIPT)],
        capture_output=True,
        text=True,
        env=full,
        timeout=120,
    )


def _checked(out: str) -> set[str]:
    return {
        line[len("ARTIST ") :].strip()
        for line in out.splitlines()
        if line.startswith("ARTIST ")
    }


def test_healthy_catalog_is_green(
    api: tuple[str, dict[str, Any]], tmp_path: Path
) -> None:
    base, _ = api
    out = _run(base, tmp_path)
    assert out.returncode == 0, out.stdout + out.stderr
    checked = _checked(out.stdout)
    # At least one artist per genre and per letters of other scripts.
    assert {"Alpha", "Beta", "Gamma"} & checked, checked
    assert any(name.startswith("E") for name in checked), checked
    assert {"Кино", "あいみょん"} <= checked, checked
    assert "FAIL" not in out.stdout
    summary = (tmp_path / "summary.txt").read_text()
    assert "nightly:" in summary and "0 fail" in summary, summary


def test_rotation_changes_the_sample_but_a_night_is_repeatable(
    api: tuple[str, dict[str, Any]], tmp_path: Path
) -> None:
    base, _ = api
    nights = [f"2026-10-0{d}" for d in range(1, 6)]
    samples = [
        frozenset(
            n
            for n in _checked(
                _run(base, tmp_path, NIGHTLY_SEED=s, NIGHTLY_PER_GENRE="2").stdout
            )
            if n[0] == "E"
        )
        for s in nights
    ]
    assert len(set(samples)) >= 2, (
        f"same artists five nights in a row: {samples}"
    )
    again = _run(base, tmp_path, NIGHTLY_SEED=nights[0], NIGHTLY_PER_GENRE="2").stdout
    assert samples[0] == frozenset(n for n in _checked(again) if n[0] == "E"), (
        "single night produced two different sets"
    )


def _set(cat: dict[str, Any], path: list[Any], value: Any) -> None:
    node = cat
    for key in path[:-1]:
        node = node[key]
    node[path[-1]] = value


BROKEN: dict[str, tuple[Callable[[dict[str, Any]], None], str, dict[str, str]]] = {
    "empty-genre": (lambda c: _set(c, ["genres", "rock"], []), "[genre-empty]", {}),
    "worldwide-over-30": (
        lambda c: _set(c, ["genres", "worldwide"], ["Кино"] * 10),
        "[worldwide-share]",
        {},
    ),
    "artist-page-404": (lambda c: c["albums"].pop("Beta"), "[artist]", {}),
    "artist-without-albums": (
        lambda c: _set(c, ["albums", "Alpha"], []),
        "[artist]",
        {},
    ),
    # Owner finding 01.10: Metallica has two "2003 · St. Anger".
    "album-duplicate": (
        lambda c: c["albums"]["Alpha"][1]["album"].update(title="ALPHA album 1"),
        "[album-duplicate]",
        {},
    ),
    "track-without-duration": (
        lambda c: [
            t.update(duration_ms=None)
            for a in c["albums"]["Gamma"]
            for t in a["tracks"]
        ],
        "[album]",
        {},
    ),
    "album-without-tracks": (
        lambda c: [a.update(tracks=[]) for a in c["albums"]["Кино"]],
        "[album]",
        {},
    ),
    "slow-search": (
        lambda c: _set(c, ["slow_search_s"], 0.3),
        "[search-slow]",
        {"NIGHTLY_SEARCH_LIMIT_S": "0.2"},
    ),
    "search-misses-artist": (
        lambda c: _set(
            c,
            ["search_override", "Gamma"],
            {"artists": [{"name": "Gamma Ray"}], "tracks": []},
        ),
        "[search-miss]",
        {},
    ),
    "core-finding-regressed": (
        lambda c: _set(
            c,
            ["search_override", "alpha song 2"],
            {
                "artists": [],
                "tracks": [
                    {
                        "id": "x",
                        "title": "Alpha Song 2",
                        "artist": "Cover Band",
                        "duration_ms": 1,
                    }
                ],
            },
        ),
        "[core]",
        {},
    ),
    "server-error": (lambda c: _set(c, ["status", "/v1/genres"], 500), "[http]", {}),
}


@pytest.mark.parametrize("case", sorted(BROKEN))
def test_broken_catalog_is_red(
    case: str, api: tuple[str, dict[str, Any]], tmp_path: Path
) -> None:
    base, cat = api
    breaker, tag, env = BROKEN[case]
    before = copy.deepcopy(cat)
    breaker(cat)
    assert cat != before, f"{case}: mutation made no difference — test is stale"
    out = _run(base, tmp_path, **env)
    assert out.returncode == 1, (
        f"{case}: nightly is green on mutation\n{out.stdout}{out.stderr}"
    )
    assert tag in out.stdout, f"{case}: missing tag {tag}\n{out.stdout}"
    summary = (tmp_path / "summary.txt").read_text()
    assert tag in summary, f"{case}: reason did not reach ntfy summary\n{summary}"


def test_without_key_it_refuses(
    api: tuple[str, dict[str, Any]], tmp_path: Path
) -> None:
    base, _ = api
    out = _run(base, tmp_path, MUSIC_API_KEY="")
    assert out.returncode != 0


def test_core_holds_owner_findings() -> None:
    rows = [
        line.split("\t")
        for line in (ROOT / "scripts" / "nightly_core.tsv").read_text().splitlines()[1:]
        if line.strip() and not line.startswith("#")
    ]
    queries = {row[0] for row in rows}
    for finding in (
        "madonna",
        "blur",
        "sade smooth operator",
        "metallica",
        "pantera",
        "stumblin in",
    ):
        assert finding in queries, f"core is missing owner finding '{finding}'"


def test_ci_runs_it_nightly_and_reports_to_ntfy() -> None:
    jobs = yaml.safe_load((ROOT / ".gitlab-ci.yml").read_text())
    job = jobs.get("nightly-live")
    assert job, "no nightly-live job in .gitlab-ci.yml"
    text = json.dumps(job)
    assert "nightly_check.py" in text
    assert "schedule" in text, "nightly-live must run on schedule"
    assert "NTFY" in text, "nightly result must be sent to ntfy"


SCHEDULE = '$CI_PIPELINE_SOURCE == "schedule"'


def test_night_pipeline_runs_nothing_but_the_check() -> None:
    """Scheduled pipeline runs on main — without prevention it would deploy server."""
    ci = yaml.safe_load((ROOT / ".gitlab-ci.yml").read_text())
    assert any(
        SCHEDULE in str(rule.get("if", "")) for rule in ci["workflow"]["rules"]
    ), "workflow does not allow scheduled pipeline — nightly will not run"
    for name, job in ci.items():
        if name.startswith(".") or not isinstance(job, dict) or "script" not in job:
            continue
        rules = job.get("rules") or []
        if name == "nightly-live":
            assert rules and all(
                SCHEDULE in str(rule.get("if", "")) for rule in rules
            ), "nightly-live runs only on schedule"
            continue
        assert rules[:1] == [{"if": SCHEDULE, "when": "never"}], (
            f"{name}: first rule must be prevention on schedule"
        )
        # Without the second rule, the job would disappear from MR and main completely.
        assert len(rules) >= 2, (
            f"{name}: no rules after prevention — job will disappear from MR and main"
        )
