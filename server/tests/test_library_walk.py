"""FT-584: library walk on server finds what owner sees by hand.

Owner on 05.10 browsing library: song from "Popular" redirects to search,
song is dimmed ("does not play") although it does play, song shows no duration.
The script `scripts/library_walk.py` walks through all artists via the same API as
the phone and writes each such row into the report. FT-585: a playing album without
a cover is intentionally dimmed without cover and does not go into report as `no_cover`.

Here a fake server is used instead of real server, with pre-planted defects: each
must appear in the report as its exact kind, while healthy items must not appear.

FT-611: fake server returns letters just like real `/v1/letters` —
`{"letter": "A", "artists": 84}`, rather than a plain string. Previous fake returned
strings, and on 06.10 live run walked letter L 51 times instead of all letters.
A song without id that the server claims is playable (`playable: true`) is
a separate kind `no_id_playable`: tapping it leads to search.
"""

from __future__ import annotations

import importlib.util
import json
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

import pytest
from not_in_slice import needs

pytestmark = needs("scripts/library_walk.py")

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "library_walk.py"
KEY = "walk-" + "k" * 40
ALB_OK, ALB_SILENT, ALB_MIXED = "a0000000-0000-4000-8000-000000000001", "a0000000-0000-4000-8000-000000000002", "a0000000-0000-4000-8000-000000000003"
ALB_BARE = "a0000000-0000-4000-8000-000000000004"  # FT-585: plays, but has no cover

ARTISTS = {"A": ["Alpha Band", "Amber"], "B": ["Beta"]}
PAGES: dict[str, dict[str, Any]] = {
    "Alpha Band": {
        "artist": {"id": "x1", "name": "Alpha Band"},
        "albums": [
            {"id": ALB_OK, "title": "Good Album", "playable": True, "cover": f"/v1/covers/{ALB_OK}"},
            {"id": ALB_SILENT, "title": "Pale Album", "playable": False, "cover": None},  # dimmed: deliberately no cover
        ],
        "top_tracks": [
            {"id": "t1", "title": "Fine Song", "duration_ms": 200000},
            {"title": "Goes To Search", "duration_ms": 0},
            {"title": "Says It Plays", "duration_ms": 0, "playable": True},  # FT-611
            {"id": "t3", "title": "No Time", "duration_ms": 0},
        ],
    },
    "Amber": {"artist": {"id": "x2", "name": "Amber"}, "albums": [
        {"id": ALB_MIXED, "title": "Mixed", "playable": True, "cover": f"/v1/covers/{ALB_MIXED}"},
        {"id": ALB_BARE, "title": "Bare Album", "playable": True, "cover": None},
    ], "top_tracks": []},
    "Beta": None,  # server returns 500 — this is also a report line, not a walk crash
}
SONGS = {"Alpha Band": [{"id": "t1", "title": "Fine Song", "duration_ms": 200000}, {"title": "Deep Cut No Id", "duration_ms": 0}]}
ALBUMS = {
    ALB_OK: [{"id": "s1", "title": "Track One", "duration_ms": 180000, "playable": True}],
    ALB_SILENT: [{"id": "s2", "title": "Pale Track", "duration_ms": 0, "playable": False}],
    ALB_BARE: [{"id": "s5", "title": "Bare Track", "duration_ms": 120000, "playable": True}],
    ALB_MIXED: [
        {"id": "s3", "title": "Plays", "duration_ms": 100000, "playable": True},
        {"id": "s4", "title": "Silent But Timed", "duration_ms": 150000, "playable": False},
    ],
}
SEEN: dict[str, Any] = {"keys": set(), "paths": []}


class Fake(BaseHTTPRequestHandler):
    def log_message(self, *_: Any) -> None:
        pass

    def _json(self, code: int, body: Any) -> None:
        raw = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self) -> None:  # noqa: N802
        SEEN["keys"].add(self.headers.get("x-flowtune-key"))
        url = urllib.parse.urlparse(self.path)
        q = {k: v[0] for k, v in urllib.parse.parse_qs(url.query).items()}
        SEEN["paths"].append(url.path)
        if url.path == "/v1/letters":
            # Like real server (`server/app/catalog.py`, `letters`): letter and count of artists.
            return self._json(200, {"letters": [{"letter": k, "artists": len(v)} for k, v in sorted(ARTISTS.items())]})
        if url.path == "/v1/artists":
            names = ARTISTS.get(q.get("letter", ""), [])
            off, lim = int(q.get("offset", 0)), int(q.get("limit", 100))
            # Page of 1 — walk must paginate by total, not just take the first.
            lim = min(lim, 1)
            return self._json(200, {"artists": [{"name": n} for n in names[off:off + lim]], "total": len(names)})
        if url.path == "/v1/artist":
            page = PAGES.get(q.get("name", ""), "missing")
            if page is None:
                return self._json(500, {"status": "error"})
            if page == "missing":
                return self._json(404, {"status": "not_found"})
            return self._json(200, page)
        if url.path == "/v1/artist/songs":
            return self._json(200, {"tracks": SONGS.get(q.get("name", ""), [])})
        if url.path.startswith("/v1/albums/"):
            return self._json(200, {"tracks": ALBUMS[url.path.rsplit("/", 1)[1]]})
        self._json(404, {"status": "not_found"})


@pytest.fixture
def server() -> Any:
    SEEN["keys"], SEEN["paths"] = set(), []
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Fake)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    yield f"http://127.0.0.1:{httpd.server_address[1]}"
    httpd.shutdown()


def _module() -> Any:
    spec = importlib.util.spec_from_file_location("library_walk_under_test", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _rows(path: Path) -> list[dict[str, Any]]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def test_every_planted_problem_is_reported_once_with_its_kind(server: str, tmp_path: Path) -> None:
    out = tmp_path / "walk.jsonl"
    summary = _module().walk(server, KEY, out, albums=True, delay=0.0)
    found = {(r["kind"], r["artist"], r.get("title", "")) for r in _rows(out)}
    expected = {
        ("no_id", "Alpha Band", "Goes To Search"),          # "Popular" leads to search
        ("no_id_playable", "Alpha Band", "Says It Plays"),   # FT-611: "plays", but leads to search
        ("no_id", "Alpha Band", "Deep Cut No Id"),           # "all tracks" — same
        ("no_duration", "Alpha Band", "No Time"),            # duration not visible
        ("album_silent", "Alpha Band", "Pale Album"),        # dimmed album
        ("track_silent", "Amber", "Silent But Timed"),       # dimmed track, although duration exists
        ("error", "Beta", ""),                               # artist page failed to open
        ("no_cover", "Amber", "Bare Album"),                 # FT-585: plays, but has no cover
    }
    assert found == expected
    assert summary == {"no_id": 2, "no_id_playable": 1, "no_duration": 1, "album_silent": 1, "track_silent": 1, "error": 1, "no_cover": 1}
    for row in _rows(out):
        assert row["where"] in {"top", "songs", "album", "artist"}
    bare = [r for r in _rows(out) if r["kind"] == "no_cover"]
    assert bare[0]["where"] == "artist" and bare[0]["album"] == "Bare Album"


def test_walk_pages_through_total_sends_key_and_opens_every_album(server: str, tmp_path: Path) -> None:
    _module().walk(server, KEY, tmp_path / "walk.jsonl", albums=True, delay=0.0)
    assert SEEN["keys"] == {KEY}
    artists_seen = [p for p in SEEN["paths"] if p == "/v1/artist"]
    assert len(artists_seen) == 3  # Alpha Band, Amber — two pages of 1; Beta
    assert {p for p in SEEN["paths"] if p.startswith("/v1/albums/")} == {f"/v1/albums/{a}" for a in (ALB_OK, ALB_SILENT, ALB_MIXED, ALB_BARE)}


def test_without_albums_no_album_pages_and_limit_stops_early(server: str, tmp_path: Path) -> None:
    out = tmp_path / "walk.jsonl"
    _module().walk(server, KEY, out, albums=False, limit=1, delay=0.0)
    assert not [p for p in SEEN["paths"] if p.startswith("/v1/albums/")]
    assert [p for p in SEEN["paths"] if p == "/v1/artist"] == ["/v1/artist"]
    assert {r["artist"] for r in _rows(out)} <= {"Alpha Band"}


def test_every_letter_is_walked_and_the_count_is_said(server: str, tmp_path: Path, capsys: Any) -> None:
    """FT-611: walk covers all letters, each artist exactly once, and verifies count with `/v1/letters`."""
    _module().walk(server, KEY, tmp_path / "walk.jsonl", albums=False, delay=0.0)
    letters_asked = [p for p in SEEN["paths"] if p == "/v1/artists"]
    assert len(letters_asked) == 3, "A — two pages of 1, B — one"
    assert "walked 3 of 3" in capsys.readouterr().out


def test_error_row_names_the_code(server: str, tmp_path: Path) -> None:
    """FT-611: 141 walk errors on 06.10 had no reason. Error row carries HTTP status code (0 — no connection)."""
    out = tmp_path / "walk.jsonl"
    _module().walk(server, KEY, out, albums=False, delay=0.0)
    errors = [r for r in _rows(out) if r["kind"] == "error"]
    assert [(r["artist"], r["code"]) for r in errors] == [("Beta", 500)]
