"""Import API (P5, step 4; R-A47, R-A48): file -> report -> save.

Honest report before saving: what was found, what is doubtful (up to three variants,
the first is selected), what is missing. Saved as a new playlist where unfindable items
remain as dimmed rows in their place, or to "Favorites", where unfindable items are not
placed. Repeated "Save" does not create a second playlist. The report lives for 24 hours
and is visible only to whoever uploaded the file; the server does not store the file itself.

Fixtures: auth and "My Music" — from `test_library.py`, small catalog — from
`test_import_match.py` (Metallica, two Nirvanas with "Lithium", custom list).
"""

# Fixtures `db`/`prepared_db` are taken from test_library.py: import and test
# parameter with the same name — this is how pytest finds the fixture, not an unused import.
# ruff: noqa: F401, F811

from __future__ import annotations

import asyncio
import base64
import io
import json
import logging
import secrets
import time
import uuid
import zipfile
from typing import Any

import asyncpg
import pytest
from fastapi.testclient import TestClient

from app.users import create_user
from test_import_match import LITHIUM, LITHIUM_60S, RECORDINGS, SANDMAN, _seed
from test_library import CONTRACTS, _app, _client, _ids, _shape, db, prepared_db

CSV_HEAD = "Track URI,Track Name,Artist Name(s),Album Name,Track Duration (ms),ISRC\n"
LIKED = CSV_HEAD + (
    "spotify:track:1,Enter Sandman,Metallica,Metallica,331000,\n"
    "spotify:track:2,Lithium,Nirvana,Nevermind,257000,\n"
    "spotify:track:3,No Such Song,Nobody Band,Nothing,200000,\n"
)


def _b64(data: bytes | str) -> str:
    raw = data.encode() if isinstance(data, str) else data
    return base64.b64encode(raw).decode()


@pytest.fixture
def catalog(db: str) -> str:
    asyncio.run(_seed(db))
    # Catalog songs haven't been shown yet: `tracks` only knows about them from import.
    asyncio.run(_sql(db, "DELETE FROM tracks WHERE id = ANY($1::uuid[])", [rec[0] for rec in RECORDINGS]))
    return db


def _create(client: TestClient, name: str | None, data: bytes | str) -> Any:
    return client.post("/v1/imports", json={"name": name, "data": _b64(data)})


def _report(client: TestClient, name: str | None = "Liked_Songs.csv", data: bytes | str = LIKED) -> Any:
    answer = _create(client, name, data)
    assert answer.status_code == 200, answer.text
    return answer.json()


def _save(client: TestClient, report_id: str, **body: Any) -> Any:
    return client.post(f"/v1/imports/{report_id}/save", json={"list": 0, "choices": {}, **body})


def _rows(client: TestClient, playlist_id: str) -> list[dict[str, Any]]:
    answer = client.get(f"/v1/playlists/{playlist_id}")
    assert answer.status_code == 200
    return answer.json()["tracks"]


def _other_client(url: str) -> TestClient:
    """Second user on the same server: own login, own token."""
    username = f"import_{uuid.uuid4().hex}"
    password = secrets.token_urlsafe(32)

    async def add_user() -> None:
        conn = await asyncpg.connect(url)
        try:
            await create_user(conn, username, password)
        finally:
            await conn.close()

    asyncio.run(add_user())
    login = TestClient(_app(url)).post(
        "/v1/auth/login",
        json={"username": username, "password": password, "device_name": "import-test"},
    )
    assert login.status_code == 200
    return TestClient(_app(url), headers={"Authorization": f"Bearer {login.json()['token']}"})


async def _sql(url: str, sql: str, *args: Any) -> Any:
    conn = await asyncpg.connect(url)
    try:
        return await conn.fetchval(sql, *args)
    finally:
        await conn.close()


# --- report ------------------------------------------------------------------


@pytest.mark.real_auth
def test_report_lists_every_row_in_order_and_matches_the_contract(catalog: str) -> None:
    client = _client(catalog)
    report = _report(client)

    contract = json.loads((CONTRACTS / "import-create.response.json").read_text())
    assert _shape(report) == _shape(contract)
    assert uuid.UUID(report["id"])
    [playlist] = report["lists"]
    assert {key: playlist[key] for key in ("index", "name", "favorites_hint")} == {
        "index": 0,
        "name": "Liked Songs",
        "favorites_hint": True,
    }
    assert (playlist["total"], playlist["found"], playlist["doubtful"], playlist["missing"]) == (3, 1, 1, 1)

    found, doubtful, missing = playlist["rows"]
    assert [row["n"] for row in playlist["rows"]] == [0, 1, 2]
    assert (found["artist"], found["title"], found["status"]) == ("Metallica", "Enter Sandman", "found")
    assert found["track"]["id"] == str(SANDMAN)
    assert found["candidates"] == []

    # Two Nirvanas with "Lithium": doubtful, first variant is selected.
    assert doubtful["status"] == "doubtful"
    assert [c["id"] for c in doubtful["candidates"]] == [str(LITHIUM), str(LITHIUM_60S)]
    assert doubtful["track"] == doubtful["candidates"][0]

    assert (missing["artist"], missing["title"]) == ("Nobody Band", "No Such Song")
    assert (missing["status"], missing["track"], missing["candidates"]) == ("missing", None, [])

    # Same report once more — before 24 hours pass.
    again = client.get(f"/v1/imports/{report['id']}")
    assert again.status_code == 200
    assert again.json() == report


@pytest.mark.real_auth
def test_pasted_text_is_a_list_without_a_file_name(catalog: str) -> None:
    client = _client(catalog)
    report = _report(client, None, "Metallica — Enter Sandman\nNobody Band - No Such Song\n")

    [playlist] = report["lists"]
    assert playlist["name"] == "Импорт"
    assert playlist["favorites_hint"] is False
    assert [row["status"] for row in playlist["rows"]] == ["found", "missing"]


@pytest.mark.real_auth
def test_archive_lists_are_saved_by_their_index(catalog: str) -> None:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr("Liked_Songs.csv", LIKED)
        archive.writestr("Road_Trip.csv", CSV_HEAD + "spotify:track:9,Lithium,Nirvana,Nevermind,257000,\n")
    client = _client(catalog)
    report = _report(client, "spotify_playlists.zip", buffer.getvalue())

    assert [(p["index"], p["name"], p["favorites_hint"]) for p in report["lists"]] == [
        (0, "Liked Songs", True),
        (1, "Road Trip", False),
    ]
    saved = _save(client, report["id"], list=1, target="playlist")
    assert saved.status_code == 200
    assert saved.json()["name"] == "Road Trip"
    assert _ids({"tracks": _rows(client, saved.json()["playlist_id"])}) == [str(LITHIUM)]


@pytest.mark.real_auth
def test_refusals_name_the_reason_and_keep_nothing(catalog: str) -> None:
    client = _client(catalog)
    before = asyncio.run(_sql(catalog, "SELECT count(*) FROM imports"))
    cases = [
        (("big.txt", b"a" * (10 * 1024 * 1024 + 1)), 413, "too_large"),
        (("Liked_Songs.csv", "Song,Singer\nLithium,Nirvana\n"), 422, "bad_columns"),
        ((None, " \n\n "), 422, "empty"),
        ((None, "\n".join(f"Band {i} - Song {i}" for i in range(10_001))), 422, "too_many_rows"),
    ]
    for (name, data), status, code in cases:
        answer = _create(client, name, data)
        assert answer.status_code == status, code
        assert answer.json()["status"] == code
        assert isinstance(answer.json()["message"], str) and answer.json()["message"], code

    # `data` is not base64: file cannot be read, this is not an "empty list".
    broken = client.post("/v1/imports", json={"name": "x.csv", "data": "%%% not base64 %%%"})
    assert broken.status_code == 422
    assert broken.json()["status"] == "bad_file"
    assert broken.json()["message"]

    assert asyncio.run(_sql(catalog, "SELECT count(*) FROM imports")) == before


# --- saving ------------------------------------------------------------------


@pytest.mark.real_auth
def test_save_to_playlist_keeps_missing_rows_in_place_and_is_not_repeated(catalog: str) -> None:
    client = _client(catalog)
    report = _report(client)
    body = json.loads((CONTRACTS / "import-save.request.json").read_text())

    saved = client.post(f"/v1/imports/{report['id']}/save", json=body)
    assert saved.status_code == 200
    contract = json.loads((CONTRACTS / "import-save.response.json").read_text())
    assert _shape(saved.json()) == _shape(contract)
    answer = saved.json()
    assert {key: answer[key] for key in ("target", "name", "added", "missing")} == {
        "target": "playlist",
        "name": "Liked Songs",
        "added": 2,
        "missing": 1,
    }

    # Selected second variant of "Lithium"; missing item is a dimmed row in its place.
    rows = _rows(client, answer["playlist_id"])
    assert [row["id"] for row in rows[:2]] == [str(SANDMAN), str(LITHIUM_60S)]
    assert [row["missing"] for row in rows] == [False, False, True]
    assert (rows[2]["artist"], rows[2]["title"], rows[2]["playable"]) == ("Nobody Band", "No Such Song", False)

    # Second click of "Save" (network dropped, user clicked again).
    repeat = client.post(f"/v1/imports/{report['id']}/save", json=body)
    assert repeat.status_code == 200
    assert repeat.json() == answer
    assert [p["name"] for p in client.get("/v1/playlists").json()["playlists"]] == ["Liked Songs"]
    assert len(_rows(client, answer["playlist_id"])) == 3


@pytest.mark.real_auth
def test_doubtful_row_takes_the_first_variant_and_null_means_none(catalog: str) -> None:
    client = _client(catalog)

    first = _save(client, _report(client)["id"], target="playlist")
    assert (first.json()["added"], first.json()["missing"]) == (2, 1)
    assert _rows(client, first.json()["playlist_id"])[1]["id"] == str(LITHIUM)

    # "None of them": row remains dimmed, with original artist and title.
    none = _save(client, _report(client)["id"], target="playlist", choices={"1": None})
    assert (none.json()["added"], none.json()["missing"]) == (1, 2)
    lithium = _rows(client, none.json()["playlist_id"])[1]
    assert (lithium["missing"], lithium["artist"], lithium["title"]) == (True, "Nirvana", "Lithium")


@pytest.mark.real_auth
def test_save_to_favorites_skips_missing_and_songs_still_play_after_restart(catalog: str) -> None:
    client = _client(catalog)
    saved = _save(client, _report(client)["id"], target="favorites")

    assert saved.status_code == 200
    assert saved.json() == {"target": "favorites", "added": 2, "missing": 1}
    assert sorted(_ids(client.get("/v1/favorites").json())) == sorted([str(SANDMAN), str(LITHIUM)])
    assert client.get("/v1/playlists").json() == {"playlists": []}

    restarted = _client(catalog)  # new process: no memory of what was shown
    for track_id in (SANDMAN, LITHIUM):
        # 409 — server knows the song and seeks audio for it; 404 would mean "no such song".
        assert restarted.post("/v1/playback", json={"track_id": str(track_id)}).status_code == 409


@pytest.mark.real_auth
def test_wrong_save_requests_change_nothing(catalog: str) -> None:
    client = _client(catalog)
    report_id = _report(client)["id"]
    for body in (
        {"list": 3, "target": "playlist"},
        {"list": 0, "target": "radio"},
        {"list": 0, "target": "playlist", "choices": {"1": 7}},
    ):
        answer = _save(client, report_id, **body)
        assert answer.status_code == 422, body
        assert answer.json() == {"status": "bad_request"}, body
    assert client.get("/v1/playlists").json() == {"playlists": []}
    assert client.get("/v1/favorites").json() == {"tracks": []}


# --- report ownership and lifetime -------------------------------------------


@pytest.mark.real_auth
def test_report_is_only_for_its_owner_and_lives_one_day(catalog: str) -> None:
    client = _client(catalog)
    report_id = _report(client)["id"]

    stranger = _other_client(catalog)
    assert stranger.get(f"/v1/imports/{report_id}").status_code == 404
    assert _save(stranger, report_id, target="playlist").status_code == 404
    assert stranger.get("/v1/playlists").json() == {"playlists": []}
    assert client.get(f"/v1/imports/{uuid.uuid4()}").status_code == 404
    assert TestClient(_app(catalog)).get(f"/v1/imports/{report_id}").status_code == 401

    asyncio.run(_sql(
        catalog,
        "UPDATE imports SET created_at = now() - interval '25 hours' WHERE id = $1",
        uuid.UUID(report_id),
    ))
    assert client.get(f"/v1/imports/{report_id}").status_code == 404
    assert _save(client, report_id, target="playlist").status_code == 404

    # Expired report does not stay forever: next upload cleans it up.
    _report(client)
    assert asyncio.run(_sql(
        catalog, "SELECT count(*) FROM imports WHERE id = $1", uuid.UUID(report_id)
    )) == 0


@pytest.mark.real_auth
def test_log_names_no_file_and_no_song(catalog: str, caplog: pytest.LogCaptureFixture) -> None:
    caplog.set_level(logging.DEBUG)
    client = _client(catalog)
    report = _report(client, "Secret_Mixtape.csv")
    _save(client, report["id"], target="playlist")
    _create(client, "Secret_Mixtape.csv", "Song,Singer\nLithium,Nirvana\n")

    for private in ("Secret", "Mixtape", "Enter Sandman", "Lithium", "Nobody Band", "No Such Song"):
        assert private not in caplog.text, private


# --- volume ------------------------------------------------------------------


@pytest.mark.real_auth
def test_two_thousand_rows_are_read_and_saved_in_seconds(catalog: str) -> None:
    lines = [f"Band {i} - Song {i}" for i in range(1998)] + ["Metallica - Enter Sandman", "Nirvana - Lithium"]
    client = _client(catalog)

    started = time.perf_counter()
    report = _report(client, "big.txt", "\n".join(lines))
    saved = _save(client, report["id"], target="playlist")
    elapsed = time.perf_counter() - started

    assert saved.status_code == 200
    assert (saved.json()["added"], saved.json()["missing"]) == (2, 1998)
    assert client.get("/v1/playlists").json()["playlists"][0]["tracks"] == 2000
    assert elapsed < 10, elapsed
