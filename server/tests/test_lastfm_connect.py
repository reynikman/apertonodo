"""FT-645 (R-A96, contract D1, item 11; feature B6, step S6b-2): Last.fm connect — server routes.

A user does not enter a Last.fm key: they tap "approve", authorize in browser on Last.fm, and
return. Between the two steps the server retains a one-time token; upon approval exchanges it for a session
key and stores it in the same place as ListenBrainz key — from that point the queue (FT-639, FT-641) sends
scrobbles to Last.fm as well.

Guards:
- without app key and secret (provided by server owner) Last.fm is "unavailable" and no outward request is made;
- session key cannot be read back: neither in responses nor in the log;
- "not approved yet", "token expired", and "service did not respond" — three distinct responses, and only expired
  token is forgotten;
- token lives 1 hour and is single per user; new "start" replaces previous;
- response to an old token does not connect if the user restarted or disconnected in the meantime;
- new connection — new revision (old queue task does not continue with the new key) and cleared
  "bad key" flag;
- each user has their own state; 401 without login.

What the test does not prove: real Last.fm is not called; `install_lastfm_connect` in `main.py`, reading
key and secret from environment and going outward via proxy is plugged by lead (B6).
"""

from __future__ import annotations

import asyncio
import json
import logging
import threading
import uuid
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlsplit

import asyncpg
import httpx
import pytest
from fastapi.testclient import TestClient

from app.lastfm_connect import install_lastfm_connect
from app.lastfm_scrobble import LASTFM_URL
from app.main import create_app
from app.migrate import apply

ROOT = Path(__file__).resolve().parents[2]
CATALOG = json.loads((ROOT / "contracts" / "fixtures" / "catalog.json").read_text())[
    "tracks"
]
KEY = "app-key-one"
SECRET = "app-secret-one"
SESSION = "session-key-d41d8cd98f00b204"

STATE = "/v1/scrobble/lastfm"
START = "/v1/scrobble/lastfm/start"
FINISH = "/v1/scrobble/lastfm/finish"
REMOVE = "/v1/scrobble/lastfm/remove"


class Outside:
    """Test Last.fm: tracks requests, hands out tokens in sequence, and answers exchange as configured."""

    def __init__(self) -> None:
        self.calls: list[dict[str, str]] = []
        self.tokens = 0
        self.token_answer: tuple[int, Any] | None = None
        self.session: tuple[int, Any] = (
            200,
            {"session": {"name": "Secret Person", "key": SESSION}},
        )
        self.error: Exception | None = None
        self.on_session: Any = None

    def answer(self, request: httpx.Request) -> httpx.Response:
        assert str(request.url) == LASTFM_URL
        form = {k: v[0] for k, v in parse_qs(request.content.decode()).items()}
        self.calls.append(form)
        if self.error is not None:
            raise self.error
        if form["method"] == "auth.getToken":
            if self.token_answer is not None:
                return httpx.Response(self.token_answer[0], json=self.token_answer[1])
            self.tokens += 1
            return httpx.Response(200, json={"token": f"tok-{self.tokens}"})
        assert form["method"] == "auth.getSession"
        if self.on_session is not None:
            # Concurrently, while request to Last.fm is in flight: separate thread — separate event loop.
            aside = threading.Thread(target=self.on_session)
            aside.start()
            aside.join()
        return httpx.Response(self.session[0], json=self.session[1])

    def methods(self) -> list[str]:
        return [call["method"] for call in self.calls]


def _run(url: str, query: str, *args: Any, fetch: str = "val") -> Any:
    async def run() -> Any:
        conn = await asyncpg.connect(url)
        try:
            if fetch == "row":
                return await conn.fetchrow(query, *args)
            return await conn.fetchval(query, *args)
        finally:
            await conn.close()

    return asyncio.run(run())


def _prepare(url: str) -> None:
    async def run() -> None:
        await apply(url)
        conn = await asyncpg.connect(url)
        try:
            await conn.execute("TRUNCATE scrobble_accounts, lastfm_pending")
        finally:
            await conn.close()

    asyncio.run(run())


def _app(
    url: str | None,
    outside: Outside | None,
    *,
    api_key: str = KEY,
    api_secret: str = SECRET,
) -> Any:
    app = create_app(
        database_url=url,
        catalog=CATALOG,
    )
    client = (
        httpx.AsyncClient(transport=httpx.MockTransport(outside.answer))
        if outside is not None
        else None
    )
    install_lastfm_connect(
        app, database_url=url, api_key=api_key, api_secret=api_secret, client=client
    )
    return app


@pytest.fixture
def outside() -> Outside:
    return Outside()


@pytest.fixture
def client(postgres_url: str, outside: Outside) -> TestClient:
    _prepare(postgres_url)
    return TestClient(_app(postgres_url, outside))


def _account(url: str, user_id: Any) -> Any:
    return _run(
        url,
        "SELECT token, bad, revision FROM scrobble_accounts WHERE user_id = $1 AND service = 'lastfm'",
        uuid.UUID(str(user_id)),
        fetch="row",
    )


def _pending(url: str, user_id: Any) -> str | None:
    return _run(
        url,
        "SELECT token FROM lastfm_pending WHERE user_id = $1",
        uuid.UUID(str(user_id)),
    )


def _age(url: str, user_id: Any, minutes: int) -> None:
    _run(
        url,
        "UPDATE lastfm_pending SET created_at = now() - make_interval(mins => $2) WHERE user_id = $1",
        uuid.UUID(str(user_id)),
        minutes,
    )


# --- normal path -------------------------------------------------------------


def test_nothing_connected_is_off_and_asks_nobody(
    client: TestClient, outside: Outside
) -> None:
    r = client.get(STATE)
    assert (r.status_code, r.json()) == (200, {"lastfm": "off"})
    assert outside.calls == []


def test_start_gives_the_approval_page_and_remembers_the_token(
    client: TestClient,
    outside: Outside,
    postgres_url: str,
    test_principal: dict[str, Any],
) -> None:
    r = client.post(START)
    assert r.status_code == 200
    body = r.json()
    assert set(body) == {"lastfm", "url"}
    assert body["lastfm"] == "pending"
    url = urlsplit(body["url"])
    assert (url.scheme, url.netloc, url.path) == ("https", "www.last.fm", "/api/auth/")
    assert parse_qs(url.query) == {"api_key": [KEY], "token": ["tok-1"]}
    assert SECRET not in r.text

    assert outside.methods() == ["auth.getToken"]
    assert outside.calls[0]["api_key"] == KEY
    assert "api_sig" in outside.calls[0]
    assert _pending(postgres_url, test_principal["id"]) == "tok-1"
    assert client.get(STATE).json() == {"lastfm": "pending"}
    assert _account(postgres_url, test_principal["id"]) is None, (
        "no key prior to approval"
    )


def test_finish_after_approval_connects(
    client: TestClient,
    outside: Outside,
    postgres_url: str,
    test_principal: dict[str, Any],
) -> None:
    client.post(START)
    r = client.post(FINISH)
    assert (r.status_code, r.json()) == (200, {"lastfm": "on"})
    assert outside.methods() == ["auth.getToken", "auth.getSession"]
    assert outside.calls[1]["token"] == "tok-1"
    account = _account(postgres_url, test_principal["id"])
    assert (account["token"], account["bad"]) == (SESSION, False)
    assert _pending(postgres_url, test_principal["id"]) is None, "token is one-time"
    assert client.get(STATE).json() == {"lastfm": "on"}


def test_session_key_and_profile_name_cannot_be_read_back(
    client: TestClient, caplog: pytest.LogCaptureFixture
) -> None:
    caplog.set_level(logging.DEBUG)
    texts = [client.post(START).text, client.post(FINISH).text, client.get(STATE).text]
    texts.append(client.post(FINISH).text)
    texts.append(client.post(REMOVE).text)
    log = "\n".join(r.getMessage() for r in caplog.records)
    for secret in (SESSION, "Secret Person", SECRET):
        assert all(secret not in text for text in texts), secret
        assert secret not in log, secret
    assert "tok-1" not in log, "token does not enter the log"


# --- three verification outcomes ---------------------------------------------


def test_not_approved_yet_keeps_waiting(
    client: TestClient,
    outside: Outside,
    postgres_url: str,
    test_principal: dict[str, Any],
) -> None:
    client.post(START)
    outside.session = (403, {"error": 14, "message": "not authorized"})
    r = client.post(FINISH)
    assert (r.status_code, r.json()) == (200, {"lastfm": "pending"})
    assert _pending(postgres_url, test_principal["id"]) == "tok-1"
    assert _account(postgres_url, test_principal["id"]) is None
    # User approved — the same token succeeds.
    outside.session = (200, {"session": {"key": SESSION}})
    assert client.post(FINISH).json() == {"lastfm": "on"}
    assert [c.get("token") for c in outside.calls[1:]] == ["tok-1", "tok-1"]


@pytest.mark.parametrize("code", [15, 4])
def test_expired_token_is_forgotten(
    client: TestClient,
    outside: Outside,
    postgres_url: str,
    test_principal: dict[str, Any],
    code: int,
) -> None:
    client.post(START)
    outside.session = (403, {"error": code, "message": "expired"})
    r = client.post(FINISH)
    assert (r.status_code, r.json()) == (200, {"lastfm": "expired"})
    assert _pending(postgres_url, test_principal["id"]) is None
    assert client.get(STATE).json() == {"lastfm": "off"}
    # Nothing left to check — do not go outward.
    before = len(outside.calls)
    assert client.post(FINISH).json() == {"lastfm": "off"}
    assert len(outside.calls) == before


@pytest.mark.parametrize(
    "trouble",
    [
        (503, {"error": 16, "message": "try again"}),
        (403, {"error": 10, "message": "Invalid API key"}),
        (500, {"session": {"key": SESSION}}),
        (200, {"session": {}}),
        httpx.ConnectError("down"),
    ],
)
def test_service_trouble_keeps_the_token_for_another_try(
    client: TestClient,
    outside: Outside,
    postgres_url: str,
    test_principal: dict[str, Any],
    trouble: Any,
) -> None:
    client.post(START)
    if isinstance(trouble, Exception):
        outside.error = trouble
    else:
        outside.session = trouble
    r = client.post(FINISH)
    assert (r.status_code, r.json()) == (502, {"lastfm": "failed"})
    assert _pending(postgres_url, test_principal["id"]) == "tok-1"
    assert _account(postgres_url, test_principal["id"]) is None
    assert client.get(STATE).json() == {"lastfm": "pending"}
    outside.error = None
    outside.session = (200, {"session": {"key": SESSION}})
    assert client.post(FINISH).json() == {"lastfm": "on"}


@pytest.mark.parametrize(
    "trouble",
    [
        (403, {"error": 10, "message": "Invalid API key"}),
        (200, {}),
        (500, {"token": "tok-x"}),
        httpx.ReadTimeout("slow"),
    ],
)
def test_start_trouble_remembers_nothing(
    client: TestClient,
    outside: Outside,
    postgres_url: str,
    test_principal: dict[str, Any],
    trouble: Any,
) -> None:
    if isinstance(trouble, Exception):
        outside.error = trouble
    else:
        outside.token_answer = trouble
    r = client.post(START)
    assert (r.status_code, r.json()) == (502, {"lastfm": "failed"})
    assert _pending(postgres_url, test_principal["id"]) is None
    assert client.get(STATE).json() == {"lastfm": "off"}


def test_failed_restart_keeps_the_earlier_token(
    client: TestClient,
    outside: Outside,
    postgres_url: str,
    test_principal: dict[str, Any],
) -> None:
    client.post(START)
    outside.token_answer = (503, {"error": 16})
    assert client.post(START).status_code == 502
    assert _pending(postgres_url, test_principal["id"]) == "tok-1"


# --- token: single, 1 hour ---------------------------------------------------


def test_finish_without_start_asks_nobody(client: TestClient, outside: Outside) -> None:
    r = client.post(FINISH)
    assert (r.status_code, r.json()) == (200, {"lastfm": "off"})
    assert outside.calls == []


def test_second_start_replaces_the_token(
    client: TestClient,
    outside: Outside,
    postgres_url: str,
    test_principal: dict[str, Any],
) -> None:
    client.post(START)
    second = client.post(START).json()
    assert parse_qs(urlsplit(second["url"]).query)["token"] == ["tok-2"]
    assert _pending(postgres_url, test_principal["id"]) == "tok-2"
    assert _run(postgres_url, "SELECT count(*) FROM lastfm_pending") == 1
    client.post(FINISH)
    assert outside.calls[-1]["token"] == "tok-2"


@pytest.mark.parametrize(("minutes", "alive"), [(59, True), (61, False)])
def test_token_lives_an_hour(
    client: TestClient,
    outside: Outside,
    postgres_url: str,
    test_principal: dict[str, Any],
    minutes: int,
    alive: bool,
) -> None:
    client.post(START)
    _age(postgres_url, test_principal["id"], minutes)
    assert client.get(STATE).json() == {"lastfm": "pending" if alive else "off"}
    before = len(outside.calls)
    r = client.post(FINISH)
    assert r.json() == {"lastfm": "on" if alive else "off"}
    assert len(outside.calls) == before + (1 if alive else 0), (
        "do not go outward for expired token"
    )
    if not alive:
        assert _account(postgres_url, test_principal["id"]) is None


def test_restart_after_an_old_token_starts_the_hour_again(
    client: TestClient,
    outside: Outside,
    postgres_url: str,
    test_principal: dict[str, Any],
) -> None:
    client.post(START)
    _age(postgres_url, test_principal["id"], 50)
    client.post(START)
    _age_now = _run(
        postgres_url,
        "SELECT created_at > now() - interval '1 minute' FROM lastfm_pending WHERE user_id = $1",
        uuid.UUID(str(test_principal["id"])),
    )
    assert _age_now is True


# --- race conditions ---------------------------------------------------------


def test_answer_for_a_replaced_token_does_not_connect(
    client: TestClient,
    outside: Outside,
    postgres_url: str,
    test_principal: dict[str, Any],
) -> None:
    # While Last.fm was answering for first token, user restarted (second tab, second phone).
    me = uuid.UUID(str(test_principal["id"]))
    client.post(START)
    outside.on_session = lambda: _run(
        postgres_url,
        "UPDATE lastfm_pending SET token = 'tok-new' WHERE user_id = $1",
        me,
    )
    r = client.post(FINISH)
    assert (r.status_code, r.json()) == (200, {"lastfm": "pending"})
    assert _account(postgres_url, me) is None
    assert _pending(postgres_url, me) == "tok-new"


def test_answer_after_remove_does_not_connect(
    client: TestClient,
    outside: Outside,
    postgres_url: str,
    test_principal: dict[str, Any],
) -> None:
    me = uuid.UUID(str(test_principal["id"]))
    client.post(START)
    outside.on_session = lambda: _run(
        postgres_url, "DELETE FROM lastfm_pending WHERE user_id = $1", me
    )
    r = client.post(FINISH)
    assert (r.status_code, r.json()) == (200, {"lastfm": "off"})
    assert _account(postgres_url, me) is None, (
        "disconnected — late response does not connect"
    )


def test_expired_answer_does_not_forget_a_newer_token(
    client: TestClient,
    outside: Outside,
    postgres_url: str,
    test_principal: dict[str, Any],
) -> None:
    me = uuid.UUID(str(test_principal["id"]))
    client.post(START)
    outside.session = (403, {"error": 15})
    outside.on_session = lambda: _run(
        postgres_url,
        "UPDATE lastfm_pending SET token = 'tok-new' WHERE user_id = $1",
        me,
    )
    client.post(FINISH)
    assert _pending(postgres_url, me) == "tok-new"


def test_two_checks_at_once_do_not_lose_the_key(
    client: TestClient,
    outside: Outside,
    postgres_url: str,
    test_principal: dict[str, Any],
) -> None:
    # Two phones clicked "check" at once. Token is one-time: Last.fm hands key to first, second with same
    # token gets "expired" — and second would erase token before first wrote key.
    client.post(START)
    second: list[Any] = []

    def meanwhile() -> None:
        outside.on_session = None
        outside.session = (403, {"error": 15, "message": "used"})
        second.append(TestClient(client.app).post(FINISH))
        outside.session = (200, {"session": {"key": SESSION}})

    outside.on_session = meanwhile
    first = client.post(FINISH)
    assert (first.status_code, first.json()) == (200, {"lastfm": "on"})
    assert (second[0].status_code, second[0].json()) == (200, {"lastfm": "pending"})
    assert outside.methods().count("auth.getSession") == 1, (
        "second check does not go outward"
    )
    assert _account(postgres_url, test_principal["id"])["token"] == SESSION
    # First completed — next check works again.
    assert client.post(FINISH).json() == {"lastfm": "on"}


def test_a_check_in_flight_of_one_person_does_not_block_another(
    client: TestClient,
    outside: Outside,
    postgres_url: str,
    test_principal: dict[str, Any],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    me = str(test_principal["id"])
    other = str(uuid.uuid4())
    client.post(START)
    monkeypatch.setitem(test_principal, "id", other)
    client.post(START)
    answers: list[Any] = []

    def meanwhile() -> None:
        outside.on_session = None
        monkeypatch.setitem(test_principal, "id", me)
        answers.append(TestClient(client.app).post(FINISH).json())
        monkeypatch.setitem(test_principal, "id", other)

    outside.on_session = meanwhile
    assert client.post(FINISH).json() == {"lastfm": "on"}
    assert answers == [{"lastfm": "on"}]
    assert _account(postgres_url, me) is not None
    assert _account(postgres_url, other) is not None


def test_start_sweeps_stale_tokens_of_people_who_left(
    client: TestClient,
    postgres_url: str,
    test_principal: dict[str, Any],
) -> None:
    gone, recent = uuid.uuid4(), uuid.uuid4()
    for person, minutes in ((gone, 61), (recent, 59)):
        _run(
            postgres_url,
            "INSERT INTO lastfm_pending (user_id, token, created_at)"
            " VALUES ($1, 'left', now() - make_interval(mins => $2))",
            person,
            minutes,
        )
    client.post(START)
    assert _pending(postgres_url, gone) is None, "expired token is not kept in database"
    assert _pending(postgres_url, recent) == "left"
    assert _pending(postgres_url, test_principal["id"]) == "tok-1"


# --- reconnect and disconnect ------------------------------------------------


def test_reconnect_is_a_new_revision_and_clears_bad(
    client: TestClient,
    outside: Outside,
    postgres_url: str,
    test_principal: dict[str, Any],
) -> None:
    me = uuid.UUID(str(test_principal["id"]))
    client.post(START)
    client.post(FINISH)
    first = _account(postgres_url, me)
    _run(
        postgres_url,
        "UPDATE scrobble_accounts SET bad = true WHERE user_id = $1 AND service = 'lastfm'",
        me,
    )
    assert client.get(STATE).json() == {"lastfm": "bad_token"}

    # Last.fm returned same session key — revision is still new (D1, item 11).
    assert client.post(START).json()["lastfm"] == "pending"
    assert client.get(STATE).json() == {"lastfm": "pending"}
    assert _account(postgres_url, me)["bad"] is True, (
        "prior to approval do not touch existing"
    )
    assert client.post(FINISH).json() == {"lastfm": "on"}
    second = _account(postgres_url, me)
    assert (second["token"], second["bad"]) == (SESSION, False)
    assert second["revision"] > first["revision"]


def test_remove_forgets_the_key_and_the_token(
    client: TestClient,
    outside: Outside,
    postgres_url: str,
    test_principal: dict[str, Any],
) -> None:
    me = test_principal["id"]
    client.post(START)
    client.post(FINISH)
    client.post(START)
    r = client.post(REMOVE)
    assert (r.status_code, r.json()) == (200, {"lastfm": "off"})
    assert _account(postgres_url, me) is None
    assert _pending(postgres_url, me) is None
    assert client.get(STATE).json() == {"lastfm": "off"}
    assert outside.methods().count("auth.getSession") == 1, "disconnecting does not go outward"


def test_remove_leaves_listenbrainz_alone(
    client: TestClient, postgres_url: str, test_principal: dict[str, Any]
) -> None:
    me = uuid.UUID(str(test_principal["id"]))
    _run(
        postgres_url,
        "INSERT INTO scrobble_accounts (user_id, service, token) VALUES ($1, 'listenbrainz', 'lb-token-1')",
        me,
    )
    client.post(START)
    client.post(FINISH)
    client.post(REMOVE)
    assert _run(
        postgres_url,
        "SELECT array_agg(service) FROM scrobble_accounts WHERE user_id = $1",
        me,
    ) == ["listenbrainz"]


def test_listenbrainz_connection_is_not_a_lastfm_one(
    client: TestClient, postgres_url: str, test_principal: dict[str, Any]
) -> None:
    _run(
        postgres_url,
        "INSERT INTO scrobble_accounts (user_id, service, token, bad)"
        " VALUES ($1, 'listenbrainz', 'lb-token-1', true)",
        uuid.UUID(str(test_principal["id"])),
    )
    assert client.get(STATE).json() == {"lastfm": "off"}


def test_each_person_has_own_token_and_key(
    client: TestClient,
    outside: Outside,
    postgres_url: str,
    test_principal: dict[str, Any],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    me = str(test_principal["id"])
    other = str(uuid.uuid4())
    client.post(START)

    monkeypatch.setitem(test_principal, "id", other)
    assert client.get(STATE).json() == {"lastfm": "off"}
    before = len(outside.calls)
    assert client.post(FINISH).json() == {"lastfm": "off"}, "cannot exchange another's token"
    assert len(outside.calls) == before
    client.post(START)
    client.post(REMOVE)
    assert _pending(postgres_url, me) == "tok-1", "cannot remove another's token"

    monkeypatch.setitem(test_principal, "id", me)
    assert client.post(FINISH).json() == {"lastfm": "on"}
    assert _account(postgres_url, other) is None
    monkeypatch.setitem(test_principal, "id", other)
    client.post(REMOVE)
    assert _account(postgres_url, me) is not None, "cannot remove another's connection"


# --- without app key ---------------------------------------------------------


@pytest.mark.parametrize(
    ("api_key", "api_secret", "has_client"),
    [("", SECRET, True), (KEY, "", True), ("", "", True), (KEY, SECRET, False)],
)
def test_without_the_owner_key_lastfm_is_unavailable(
    postgres_url: str, api_key: str, api_secret: str, has_client: bool
) -> None:
    _prepare(postgres_url)
    outside = Outside()
    client = TestClient(
        _app(
            postgres_url,
            outside if has_client else None,
            api_key=api_key,
            api_secret=api_secret,
        )
    )
    r = client.get(STATE)
    assert (r.status_code, r.json()) == (200, {"lastfm": "unavailable"})
    for path in (START, FINISH):
        r = client.post(path)
        assert (r.status_code, r.json()) == (404, {"lastfm": "unavailable"}), path
    assert outside.calls == []
    assert _run(postgres_url, "SELECT count(*) FROM lastfm_pending") == 0


def test_unavailable_state_needs_no_database() -> None:
    client = TestClient(_app(None, Outside(), api_key=""))
    r = client.get(STATE)
    assert (r.status_code, r.json()) == (200, {"lastfm": "unavailable"})


def test_remove_works_after_the_owner_took_the_key_away(
    postgres_url: str, test_principal: dict[str, Any]
) -> None:
    # Server owner removed app key: user can still remove their session key.
    _prepare(postgres_url)
    me = uuid.UUID(str(test_principal["id"]))
    _run(
        postgres_url,
        "INSERT INTO scrobble_accounts (user_id, service, token) VALUES ($1, 'lastfm', $2)",
        me,
        SESSION,
    )
    client = TestClient(_app(postgres_url, Outside(), api_key=""))
    r = client.post(REMOVE)
    assert (r.status_code, r.json()) == (200, {"lastfm": "unavailable"})
    assert _account(postgres_url, me) is None


# --- database failure and auth -----------------------------------------------


def test_no_database_is_503_and_asks_nobody() -> None:
    outside = Outside()
    client = TestClient(_app(None, outside))
    for r in (
        client.get(STATE),
        client.post(START),
        client.post(FINISH),
        client.post(REMOVE),
    ):
        assert r.status_code == 503
        assert r.json() == {"status": "library_unavailable"}
    assert outside.calls == [], "do not request token that cannot be remembered"


@pytest.mark.real_auth
def test_without_login_refused(postgres_url: str) -> None:
    outside = Outside()
    client = TestClient(_app(postgres_url, outside))
    assert client.get(STATE).status_code == 401
    for path in (START, FINISH, REMOVE):
        assert client.post(path).status_code == 401, path
    assert outside.calls == []


def test_body_and_query_are_not_needed_and_change_nothing(
    client: TestClient,
    outside: Outside,
    postgres_url: str,
    test_principal: dict[str, Any],
) -> None:
    # User does not send token or key: anything arriving in body is ignored by server.
    r = client.post(START, json={"token": "mine", "api_key": "other"})
    assert r.status_code == 200
    assert _pending(postgres_url, test_principal["id"]) == "tok-1"
    assert outside.calls[0]["api_key"] == KEY
    r = client.post(FINISH + "?token=evil", json={"token": "evil"})
    assert r.json() == {"lastfm": "on"}
    assert outside.calls[1]["token"] == "tok-1"


def test_migration_keeps_one_token_per_person(postgres_url: str) -> None:
    _prepare(postgres_url)
    me = uuid.uuid4()
    _run(
        postgres_url, "INSERT INTO lastfm_pending (user_id, token) VALUES ($1, 'a')", me
    )
    with pytest.raises(asyncpg.UniqueViolationError):
        _run(
            postgres_url,
            "INSERT INTO lastfm_pending (user_id, token) VALUES ($1, 'b')",
            me,
        )
    assert (
        _run(
            postgres_url,
            "SELECT created_at > now() - interval '1 minute' FROM lastfm_pending WHERE user_id = $1",
            me,
        )
        is True
    )
