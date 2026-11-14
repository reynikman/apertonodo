"""Server-side download queue (FT-525, R-A60, rules 2, 3, 8).

The phone requests "download" with a list of songs, then polls the progress
of all downloads in a single query. The server itself locates the file via an extension (like Play),
waits for it completely, transcodes FLAC to Opus, and serves the finished file with Range and ETag — allowing
the phone to resume broken downloads. Extension pinning — `test_extension_asset.py`.

The queue persists in the database: server restarts in the middle of an album do not lose it. Another
account cannot see foreign downloads. A failure is recorded in the failure list (R-A55), while the
log contains only `download <number>`, without titles or source hashes.

Auth and database are fixtures from `test_library.py`; file and extension — `Disk` from
`test_extension_asset.py`.
"""

# Fixtures `db`/`prepared_db` are imported from test_library.py: import and test parameter
# of the same name — this is how pytest discovers the fixture; it is not a redundant import.
# ruff: noqa: F401, F811

from __future__ import annotations

import asyncio
import json
import logging
import secrets
import uuid
from pathlib import Path
from typing import Any

import asyncpg
import pytest
from fastapi.testclient import TestClient
from fake_extension import running_extension
from test_extension_asset import Disk, _forget_disk, _song, _tone
from test_library import _AUTH_HEADER, CONTRACTS, FORBIDDEN, _shape, db, prepared_db
from test_opus_variant import _wait

from app.main import create_app
from app.users import create_user
from app.variants import asset_variant_path

pytestmark = pytest.mark.real_auth


class Setup:
    """Server with one song and an extension that has a file on disk."""

    def __init__(self, url: str, tmp_path: Path, suffix: str, *, found: bool = True) -> None:
        self.url = url
        self.tmp_path = tmp_path
        self.song = _song()
        self.path = _tone(tmp_path / "disk" / f"01{suffix}", self.song)
        self.disk = Disk(self.path)
        self.found = found
        _forget_disk(url)
        self._ext = running_extension(self.disk.app())
        self.extension_url = self._ext.__enter__()

    def close(self) -> None:
        self._ext.__exit__(None, None, None)

    def app(self) -> Any:
        return create_app(
            database_url=self.url,
            catalog=[self.song],
            extensions={"disk": self.extension_url} if self.found else {},
            variant_dir=self.tmp_path / "variants",
            download_poll_s=0.05,
        )

    def client(self, headers: dict[str, str] | None = None) -> TestClient:
        return TestClient(self.app(), headers=headers or _AUTH_HEADER.get())


@pytest.fixture(autouse=True)
def _closing() -> Any:
    yield
    for setup in _OPEN:
        setup.close()
    _OPEN.clear()


_OPEN: list[Setup] = []


def _setup(*args: Any, **kwargs: Any) -> Setup:
    setup = Setup(*args, **kwargs)
    _OPEN.append(setup)
    return setup


def _items(client: TestClient) -> dict[str, dict[str, Any]]:
    answer = client.get("/v1/downloads")
    assert answer.status_code == 200, answer.text
    return {item["track_id"]: item for item in answer.json()["items"]}


def _state(client: TestClient, track_id: str) -> str | None:
    item = _items(client).get(track_id)
    return item["state"] if item else None


def _ask(client: TestClient, *track_ids: str) -> Any:
    return client.post("/v1/downloads", json={"track_ids": list(track_ids)})


def _remove(client: TestClient, *track_ids: str) -> Any:
    # POST rather than DELETE: owner's NPM does not pass DELETE (docs/reverse-proxy.md, item 4).
    return client.post("/v1/downloads/remove", json={"track_ids": list(track_ids)})


def _until(client: TestClient, track_id: str, state: str) -> None:
    assert _wait(lambda: _state(client, track_id) == state), (
        f"did not wait for {state}: {_items(client).get(track_id)}"
    )


def _sql(url: str, sql: str, *args: Any) -> Any:
    async def run() -> Any:
        conn = await asyncpg.connect(url)
        try:
            return await conn.fetchval(sql, *args)
        finally:
            await conn.close()

    return asyncio.run(run())


def _stranger(url: str, setup: Setup) -> TestClient:
    username = f"dl_{uuid.uuid4().hex}"
    password = secrets.token_urlsafe(32)

    async def add_user() -> None:
        conn = await asyncpg.connect(url)
        try:
            await create_user(conn, username, password)
        finally:
            await conn.close()

    asyncio.run(add_user())
    login = TestClient(setup.app()).post(
        "/v1/auth/login",
        json={"username": username, "password": password, "device_name": "downloads-test"},
    )
    assert login.status_code == 200
    return setup.client({"Authorization": f"Bearer {login.json()['token']}"})


# ------------------------------------------------------------ contract


def test_request_and_answer_match_the_contract(db: str, tmp_path: Path) -> None:
    setup = _setup(db, tmp_path, ".mp3")
    request = json.loads((CONTRACTS / "downloads.request.json").read_text())
    contract = json.loads((CONTRACTS / "downloads.response.json").read_text())
    assert set(request) == {"track_ids"}
    with setup.client() as client:
        asked = _ask(client, setup.song["id"])
        assert asked.status_code == 202, asked.text
        assert [item["track_id"] for item in asked.json()["items"]] == [setup.song["id"]]
        _until(client, setup.song["id"], "ready")
        answer = client.get("/v1/downloads").json()
        assert _shape(answer) == _shape(contract)
        text = json.dumps(answer).casefold()
        for word in FORBIDDEN:
            assert word not in text, word
        assert "disk:" not in text


def test_states_are_the_four_from_the_contract(db: str, tmp_path: Path) -> None:
    states = json.loads((CONTRACTS / "downloads.states.json").read_text())
    assert states == ["queued", "preparing", "ready", "failed"]


# ------------------------------------------------------------ file


def test_mp3_comes_as_it_is_with_range_and_etag(db: str, tmp_path: Path) -> None:
    setup = _setup(db, tmp_path, ".mp3")
    track_id = setup.song["id"]
    with setup.client() as client:
        _ask(client, track_id)
        _until(client, track_id, "ready")
        item = _items(client)[track_id]
        body = setup.path.read_bytes()
        assert (item["format"], item["bytes"]) == ("mp3", len(body))

        url = f"/v1/downloads/{track_id}/file"
        whole = client.get(url)
        assert whole.status_code == 200
        assert whole.content == body
        assert whole.headers["content-type"].startswith("audio/mpeg")
        assert int(whole.headers["content-length"]) == len(body), "length is always known"
        etag = whole.headers["etag"]

        part = client.get(url, headers={"range": "bytes=100-199", "if-range": etag})
        assert part.status_code == 206, "interrupted download can be resumed"
        assert part.content == body[100:200]

        head = client.head(url)
        assert head.status_code == 200
        assert head.headers["etag"] == etag
        assert head.content == b""


def test_flac_is_handed_over_as_opus(db: str, tmp_path: Path) -> None:
    setup = _setup(db, tmp_path, ".flac")
    track_id = setup.song["id"]
    with setup.client() as client:
        _ask(client, track_id)
        _until(client, track_id, "ready")
        copy = asset_variant_path(tmp_path / "variants", "disk:one")
        assert copy.is_file(), "compressed copy is located in the same place as for Play (FT-521)"
        item = _items(client)[track_id]
        assert (item["format"], item["bytes"]) == ("opus", copy.stat().st_size)

        got = client.get(f"/v1/downloads/{track_id}/file")
        assert got.status_code == 200
        assert got.headers["content-type"].startswith("audio/ogg")
        assert got.content == copy.read_bytes(), "downloaded content is Opus, not FLAC (rule 2)"


# ------------------------------------------------------------ queue


def test_asking_twice_keeps_one_download(db: str, tmp_path: Path) -> None:
    setup = _setup(db, tmp_path, ".mp3")
    track_id = setup.song["id"]
    with setup.client() as client:
        assert _ask(client, track_id).status_code == 202
        assert _ask(client, track_id, track_id).status_code == 202
        _until(client, track_id, "ready")
        assert list(_items(client)) == [track_id]


def test_unknown_song_fails_without_breaking_the_rest(db: str, tmp_path: Path) -> None:
    setup = _setup(db, tmp_path, ".mp3")
    ghost = str(uuid.uuid4())
    with setup.client() as client:
        assert _ask(client, ghost, setup.song["id"]).status_code == 202
        _until(client, setup.song["id"], "ready")
        _until(client, ghost, "failed")


def test_bad_requests_are_refused(db: str, tmp_path: Path) -> None:
    setup = _setup(db, tmp_path, ".mp3")
    with setup.client() as client:
        assert client.post("/v1/downloads", json={"track_ids": ["not-a-uuid"]}).status_code == 422
        assert client.post("/v1/downloads", json={"track_ids": []}).status_code == 422
        many = [str(uuid.uuid4()) for _ in range(501)]
        assert client.post("/v1/downloads", json={"track_ids": many}).status_code == 422
        never = str(uuid.uuid4())
        assert client.get(f"/v1/downloads/{never}/file").status_code == 404
        assert _remove(client, never).status_code == 204, "nothing to remove is not an error"
        assert client.post("/v1/downloads/remove", json={"track_ids": []}).status_code == 422


def test_someone_else_sees_nothing(db: str, tmp_path: Path) -> None:
    setup = _setup(db, tmp_path, ".mp3")
    track_id = setup.song["id"]
    with setup.client() as client:
        _ask(client, track_id)
        _until(client, track_id, "ready")
    with _stranger(db, setup) as other:
        assert _items(other) == {}
        assert other.get(f"/v1/downloads/{track_id}/file").status_code == 404
        assert _remove(other, track_id).status_code == 204
    with setup.client() as client:
        assert _state(client, track_id) == "ready", "other user's remove deleted nothing"


def test_needs_a_login(db: str, tmp_path: Path) -> None:
    setup = _setup(db, tmp_path, ".mp3")
    with TestClient(setup.app()) as anonymous:
        assert anonymous.get("/v1/downloads").status_code == 401


# ------------------------------------------------------------ failure and log


def test_failure_goes_to_the_failures_list_and_the_log_stays_private(
    db: str, tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    caplog.set_level(logging.INFO)
    setup = _setup(db, tmp_path, ".mp3", found=False)
    track_id = setup.song["id"]
    with setup.client() as client:
        _ask(client, track_id)
        _until(client, track_id, "failed")
        assert client.get(f"/v1/downloads/{track_id}/file").status_code == 409

    noted = _sql(
        db,
        "SELECT count(*) FROM play_failures"
        " WHERE track_id = $1 AND kind = 'download_failed' AND ref LIKE 'download %'",
        track_id,
    )
    assert noted == 1, "failure is visible in python -m app.failures"
    lines = [record.getMessage() for record in caplog.records]
    assert any(line.startswith("download ") for line in lines), "download has its own number in the log"
    for line in lines:
        assert setup.song["artist"] not in line
        assert "Disasterpiece" not in line
        assert track_id not in line
