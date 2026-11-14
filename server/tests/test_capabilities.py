"""FT-637 (Р-A96, Р-A97, contract Д4): server tells app what it can do.

App and server are not updated at the same time. So that new app does not show buttons that
old server does not understand, and server owner could skip setting up Last.fm, app asks for
capabilities list and hides the rest. In addition server provides its persistent installation id — by it
app distinguishes "same server moved" from "another server now at this address".

Guarded:
- installation id is created once and never changes — neither between requests, nor between restarts, nor when
  two initial requests arrive concurrently;
- list is exactly what was provided by the wiring lead, once each, in alphabetical order; words violating rules
  are dropped rather than breaking the response;
- for different users the list may differ: deciding function sees the request;
- failure when evaluating the list is an honest 503 rejection, not an empty list ("server supports nothing" would hide
  everything in the app);
- route is locked like all others; response is not cached on the path.

What tests do not prove: which words production server returns — list and `words` function are written by the lead at
wiring (В2); that the app hides buttons according to this list; that "feature off" rejection is set on
every disabled route.
"""

from __future__ import annotations

import asyncio
import json
import uuid
from pathlib import Path
from typing import Any

import asyncpg
import pytest
from fastapi import Request
from fastapi.testclient import TestClient

from app.capabilities import API_LEVEL, feature_off, install_capabilities, server_id
from app.main import create_app
from app.migrate import apply

ROOT = Path(__file__).resolve().parents[2]
CATALOG = json.loads((ROOT / "contracts" / "fixtures" / "catalog.json").read_text())[
    "tracks"
]


def _sql(url: str, query: str, *args: Any) -> Any:
    async def run() -> Any:
        conn = await asyncpg.connect(url)
        try:
            return await conn.fetchval(query, *args)
        finally:
            await conn.close()

    return asyncio.run(run())


@pytest.fixture
def base(postgres_url: str) -> str:
    asyncio.run(apply(postgres_url))
    _sql(postgres_url, "TRUNCATE server_identity")
    return postgres_url


def _client(url: str | None, words: Any) -> TestClient:
    app = create_app(
        database_url=url,
        catalog=CATALOG,
    )
    install_capabilities(app, database_url=url, words=words)
    return TestClient(app)


def _get(url: str | None, words: Any) -> Any:
    return _client(url, words).get("/v1/capabilities")


# --- response ------------------------------------------------------------------


def test_answer_has_exactly_three_fields(base: str) -> None:
    response = _get(base, lambda request: ["ratings", "news"])
    assert response.status_code == 200
    body = response.json()
    assert set(body) == {"server_id", "api", "capabilities"}
    assert body["capabilities"] == ["news", "ratings"]
    assert body["api"] == API_LEVEL == 1 and isinstance(body["api"], int)
    assert uuid.UUID(body["server_id"]).version == 4


def test_words_come_once_and_in_order(base: str) -> None:
    body = _get(
        base,
        lambda request: ["scrobble", "import", "scrobble", "history_control", "import"],
    ).json()
    assert body["capabilities"] == ["history_control", "import", "scrobble"]


def test_empty_list_is_an_honest_answer(base: str) -> None:
    response = _get(base, lambda request: [])
    assert response.status_code == 200
    assert response.json()["capabilities"] == []


def test_words_against_the_rules_are_dropped(base: str) -> None:
    words = [
        "ratings",
        "Ratings",
        "two words",
        "",
        "9lives",
        "a" * 41,
        "тексты",
        None,
        7,
        "scrobble_lastfm",
        "x-y",
    ]
    body = _get(base, lambda request: words).json()
    assert body["capabilities"] == ["ratings", "scrobble_lastfm"]
    assert _get(base, lambda request: ["a" * 40, "a1_b"]).json()["capabilities"] == [
        "a1_b",
        "a" * 40,
    ]


def test_words_may_be_any_iterable_and_async(base: str) -> None:
    async def later(request: Request) -> Any:
        await asyncio.sleep(0)
        return {"news", "import"}

    assert _get(base, later).json()["capabilities"] == ["import", "news"]
    assert _get(base, lambda request: (w for w in ("b", "a"))).json()[
        "capabilities"
    ] == ["a", "b"]


def test_words_see_who_is_asking(base: str, test_principal: dict[str, Any]) -> None:
    seen: list[str] = []

    def words(request: Request) -> list[str]:
        seen.append(str(request.state.user["id"]))
        return ["ratings"]

    _get(base, words)
    assert seen == [str(test_principal["id"])]


def test_failure_to_decide_is_a_refusal_not_an_empty_list(base: str) -> None:
    def broken(request: Request) -> list[str]:
        raise RuntimeError("Paper Lanterns")

    response = _client(base, broken).get("/v1/capabilities")
    assert response.status_code == 503
    assert response.json() == {"status": "capabilities_unavailable"}
    assert "Paper" not in response.text


def test_without_database_is_a_refusal(base: str) -> None:
    response = _get(None, lambda request: ["ratings"])
    assert response.status_code == 503
    assert response.json() == {"status": "library_unavailable"}


def test_answer_is_not_cached_on_the_way(base: str) -> None:
    assert (
        _get(base, lambda request: ["ratings"]).headers["cache-control"] == "no-store"
    )


@pytest.mark.real_auth
def test_path_is_behind_the_lock(base: str) -> None:
    called: list[int] = []

    def words(request: Request) -> list[str]:
        called.append(1)
        return ["ratings"]

    assert _client(base, words).get("/v1/capabilities").status_code == 401
    assert called == []


# --- installation id --------------------------------------------------------


def test_server_id_survives_requests_and_restarts(base: str) -> None:
    first = _get(base, lambda request: []).json()["server_id"]
    again = _client(base, lambda request: [])
    assert again.get("/v1/capabilities").json()["server_id"] == first
    assert again.get("/v1/capabilities").json()["server_id"] == first
    assert _sql(base, "SELECT count(*) FROM server_identity") == 1


def test_two_first_requests_at_once_agree(base: str) -> None:
    async def run() -> list[uuid.UUID]:
        conns = [await asyncpg.connect(base) for _ in range(6)]
        try:
            return list(await asyncio.gather(*(server_id(conn) for conn in conns)))
        finally:
            for conn in conns:
                await conn.close()

    ids = asyncio.run(run())
    assert len(set(ids)) == 1
    assert isinstance(ids[0], uuid.UUID)
    assert _sql(base, "SELECT count(*) FROM server_identity") == 1


def test_another_database_is_another_server(base: str) -> None:
    first = _get(base, lambda request: []).json()["server_id"]
    _sql(base, "TRUNCATE server_identity")
    assert _get(base, lambda request: []).json()["server_id"] != first


def test_table_cannot_hold_two_servers(base: str) -> None:
    _get(base, lambda request: [])
    with pytest.raises(asyncpg.PostgresError):
        _sql(base, "INSERT INTO server_identity (server_id) VALUES (gen_random_uuid())")
    assert _sql(base, "SELECT count(*) FROM server_identity") == 1


def test_migration_is_numbered_and_repeatable(base: str) -> None:
    assert (
        Path(__file__).resolve().parents[1] / "migrations" / "051_server_identity.sql"
    ).exists()
    asyncio.run(apply(base))


# --- "feature off" ----------------------------------------------------


def test_feature_off_is_one_recognisable_answer() -> None:
    response = feature_off("scrobble_lastfm")
    assert response.status_code == 409
    assert json.loads(bytes(response.body)) == {
        "status": "feature_off",
        "feature": "scrobble_lastfm",
    }
