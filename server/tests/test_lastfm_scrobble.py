"""FT-643 (R-A96, contract D1, items 10-12; feature B6, step S6b-1): Last.fm — signature, dispatch, permission.

Listen queue (FT-639) and its dispatcher (FT-641) know nothing about Last.fm: the dispatcher is given
a function "token + listen -> status word". Here is that function for Last.fm and two steps of obtaining
user permission (request token -> user approves in browser -> exchange token for session key).

Guards:
- request signature is computed as required by Last.fm (names in alphabetical order, `format` is not signed,
  UTF-8) — otherwise the service replies "invalid signature" to every request;
- track start time and user session key are sent outward; application secret is never sent;
- service response becomes a queue status word: accepted — `sent`; revoked session key — `bad_token`;
  service down, rate limiting, or server owner key is broken — `retry` (scrobble is not lost);
  service refused scrobble — `refused`;
- malformed response and network failure do not crash dispatch and do not enter the log;
- exchanging token for key distinguishes "user has not approved yet", "token expired", and "failed".

What the test does not prove: real Last.fm is not called (lead has no application key — that is obtained
by the server owner, R-A96); HTTP routes and persisting session key in database are not here — next card.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
from datetime import UTC, datetime
from typing import Any
from urllib.parse import parse_qs, urlsplit

import httpx
import pytest

from app.lastfm_scrobble import (
    LASTFM_URL,
    approve_url,
    get_session,
    lastfm,
    request_token,
    sign,
)
from app.scrobble import Listen

KEY = "key-one"
SECRET = "secret-one"
STARTED = datetime(2026, 9, 21, 14, 13, 20, tzinfo=UTC)  # 1790000000
LISTEN = Listen("Би-2", "Песня", 200_500, STARTED)
ACCEPTED = {"scrobbles": {"@attr": {"accepted": 1, "ignored": 0}, "scrobble": {}}}


def _form(request: httpx.Request) -> dict[str, str]:
    assert request.method == "POST"
    assert str(request.url) == LASTFM_URL
    assert request.headers["content-type"].startswith(
        "application/x-www-form-urlencoded"
    )
    parsed = parse_qs(
        request.content.decode("utf-8"), keep_blank_values=True, strict_parsing=True
    )
    assert all(len(values) == 1 for values in parsed.values()), "field duplicated"
    return {name: values[0] for name, values in parsed.items()}


def _expected_sig(form: dict[str, str]) -> str:
    """Signature according to Last.fm description, written independently of the code."""
    text = "".join(
        name + form[name] for name in sorted(form) if name not in ("api_sig", "format")
    )
    return hashlib.md5((text + SECRET).encode("utf-8")).hexdigest()  # noqa: S324


class _Service:
    def __init__(self, status: int = 200, body: Any = None, raw: bytes | None = None):
        self.status, self.body, self.raw = status, body, raw
        self.forms: list[dict[str, str]] = []
        self.error: Exception | None = None

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.forms.append(_form(request))
        if self.error is not None:
            raise self.error
        if self.raw is not None:
            return httpx.Response(self.status, content=self.raw)
        return httpx.Response(self.status, json=self.body)


def _send(
    service: _Service, listen: Listen = LISTEN, token: str = "session-one"
) -> str:
    async def go() -> str:
        async with httpx.AsyncClient(transport=httpx.MockTransport(service)) as client:
            return await lastfm(client, api_key=KEY, api_secret=SECRET)(token, listen)

    return asyncio.run(go())


def _own(caplog: pytest.LogCaptureFixture) -> list[str]:
    """Log lines of module itself: internal lines from asyncio and httpx (URL without body) do not count."""
    foreign = ("asyncio", "httpx", "httpcore")
    return [r.getMessage() for r in caplog.records if not r.name.startswith(foreign)]


# --- signature ---------------------------------------------------------------


def test_signature_is_md5_of_sorted_names_and_values_plus_secret() -> None:
    params = {"token": "tok-1", "method": "auth.getSession", "api_key": KEY}
    assert sign(params, SECRET) == "bd7b589fb869590e8f7433efcc104652"


def test_signature_takes_utf8_and_skips_format_and_callback() -> None:
    params = {
        "method": "track.scrobble",
        "track": "Песня",
        "artist": "Би-2",
        "timestamp": "1790000000",
        "sk": "SK",
        "api_key": KEY,
    }
    expected = "769d7a21f09e015c879f418ae124db25"
    assert sign(params, SECRET) == expected
    assert sign({**params, "format": "json", "callback": "cb"}, SECRET) == expected
    assert sign(params, "other") != expected


def test_signature_does_not_change_its_argument() -> None:
    params = {"b": "2", "a": "1"}
    sign(params, SECRET)
    assert list(params.items()) == [("b", "2"), ("a", "1")]


# --- scrobble submission -----------------------------------------------------


def test_scrobble_request_carries_the_start_time_and_the_session_key() -> None:
    service = _Service(body=ACCEPTED)
    assert _send(service) == "sent"
    (form,) = service.forms
    assert form == {
        "method": "track.scrobble",
        "api_key": KEY,
        "sk": "session-one",
        "artist": "Би-2",
        "track": "Песня",
        "timestamp": "1790000000",
        "duration": "200",
        "format": "json",
        "api_sig": _expected_sig(form),
    }
    assert SECRET not in json.dumps(form), "app secret is not sent outward"


@pytest.mark.parametrize("duration_ms", [0, 999, -5])
def test_unknown_duration_is_not_sent(duration_ms: int) -> None:
    service = _Service(body=ACCEPTED)
    assert _send(service, Listen("A", "T", duration_ms, STARTED)) == "sent"
    (form,) = service.forms
    assert "duration" not in form
    assert form["api_sig"] == _expected_sig(form)


def test_ampersand_and_plus_in_a_title_survive_the_form() -> None:
    service = _Service(body=ACCEPTED)
    assert _send(service, Listen("AC/DC & Co", "1+1=2 ?", 61_000, STARTED)) == "sent"
    (form,) = service.forms
    assert (form["artist"], form["track"]) == ("AC/DC & Co", "1+1=2 ?")
    assert form["api_sig"] == _expected_sig(form)


@pytest.mark.parametrize(
    "attr",
    [
        {"accepted": 1, "ignored": 0},
        {"accepted": "1", "ignored": "0"},
    ],
)
def test_accepted_scrobble_is_sent(attr: dict[str, Any]) -> None:
    assert _send(_Service(body={"scrobbles": {"@attr": attr}})) == "sent"


@pytest.mark.parametrize(
    "attr",
    [
        {"accepted": 0, "ignored": 1},
        {"accepted": "0", "ignored": "1"},
    ],
)
def test_ignored_scrobble_is_refused(attr: dict[str, Any]) -> None:
    # Service refused scrobble (too old, artist in its blacklist): retrying will not help.
    assert _send(_Service(body={"scrobbles": {"@attr": attr}})) == "refused"


def _ignored(code: Any) -> dict[str, Any]:
    """Last.fm 'ignored' response with reason, as in its JSON."""
    return {
        "scrobbles": {
            "@attr": {"accepted": 0, "ignored": 1},
            "scrobble": {"ignoredMessage": {"code": code, "#text": "Secret Artist"}},
        }
    }


@pytest.mark.parametrize("code", ["1", "2", "3", 1, 3, "0", "77", None, "x"])
def test_ignored_for_good_is_refused(code: Any) -> None:
    # 1 and 2 — artist or song in service blacklist, 3 — timestamp too old: retrying will not help.
    assert _send(_Service(body=_ignored(code))) == "refused"


@pytest.mark.parametrize("code", ["4", 4, "5", 5])
def test_passing_reason_is_a_retry_and_not_a_loss(code: Any) -> None:
    # 5 — user daily scrobble limit reached: same scrobble will be accepted tomorrow.
    # 4 — timestamp from the future: clocks drifted by minutes, later that time is no longer future.
    assert _send(_Service(body=_ignored(code))) == "retry"


@pytest.mark.parametrize(
    "scrobble",
    [None, "x", [], [{"ignoredMessage": {"code": "5"}}], {"ignoredMessage": "5"}],
)
def test_ignored_without_a_readable_reason_is_refused(scrobble: Any) -> None:
    body = {"scrobbles": {"@attr": {"accepted": 0, "ignored": 1}, "scrobble": scrobble}}
    assert _send(_Service(body=body)) == "refused"


@pytest.mark.parametrize(
    ("status", "code", "word"),
    [
        (403, 9, "bad_token"),  # session key revoked by user
        (400, 6, "refused"),  # service rejects the scrobble itself
        (200, 9, "bad_token"),  # error code takes precedence over HTTP status
        (403, 4, "retry"),
        (403, 10, "retry"),  # application key — issue of server owner, not user
        (403, 13, "retry"),  # signature
        (403, 26, "retry"),  # application key suspended
        (503, 11, "retry"),  # service offline
        (503, 16, "retry"),  # temporary outage
        (429, 29, "retry"),  # rate limit
        (400, 8, "retry"),
        (400, 999, "retry"),
    ],
)
def test_error_code_becomes_a_word(status: int, code: int, word: str) -> None:
    service = _Service(status, {"error": code, "message": "Secret Artist said no"})
    assert _send(service) == word


@pytest.mark.parametrize(
    ("status", "body", "raw"),
    [
        (500, None, b"<html>Bad Gateway</html>"),
        (200, None, b"not json"),
        (200, None, b""),
        (200, [1, 2], None),
        (200, "text", None),
        (200, {}, None),
        (200, {"scrobbles": {}}, None),
        (200, {"scrobbles": "x"}, None),
        (200, {"scrobbles": {"@attr": {"accepted": "many", "ignored": 0}}}, None),
        (200, {"scrobbles": {"@attr": {"accepted": 0, "ignored": 0}}}, None),
        (200, {"scrobbles": {"@attr": None}}, None),
        (200, {"error": "nine"}, None),
        (200, {"error": True}, None),
        (200, {"error": None}, None),
        (
            200,
            {"error": "nine", **ACCEPTED},
            None,
        ),  # error is named — "accepted" next to it is ignored
        (502, ACCEPTED, None),
        (404, {"anything": 1}, None),
    ],
)
def test_broken_answer_is_a_retry_and_never_an_exception(
    status: int, body: Any, raw: bytes | None
) -> None:
    assert _send(_Service(status, body, raw)) == "retry"


@pytest.mark.parametrize(
    "error",
    [
        httpx.ConnectError("no route to https://secret.example/session-one"),
        httpx.ReadTimeout("slow"),
        httpx.RemoteProtocolError("cut"),
    ],
)
def test_network_error_is_a_retry(error: Exception) -> None:
    service = _Service()
    service.error = error
    assert _send(service) == "retry"


def test_one_request_per_listen() -> None:
    service = _Service(503, {"error": 16, "message": "try again"})
    _send(service)
    assert len(service.forms) == 1, "retries are queue responsibility, not dispatcher"


def test_nothing_is_logged(caplog: pytest.LogCaptureFixture) -> None:
    with caplog.at_level(logging.DEBUG):
        _send(_Service(403, {"error": 9, "message": "Secret Artist"}))
        failing = _Service()
        failing.error = httpx.ConnectError("no route to session-one")
        _send(failing)
        _send(_Service(200, None, b"Secret Title"))
    assert _own(caplog) == []


# --- user permission ---------------------------------------------------------


def _ask(service: _Service, work: Any) -> Any:
    async def go() -> Any:
        async with httpx.AsyncClient(transport=httpx.MockTransport(service)) as client:
            return await work(client)

    return asyncio.run(go())


def test_request_token_is_a_signed_call() -> None:
    service = _Service(body={"token": "tok-1"})
    token = _ask(service, lambda c: request_token(c, api_key=KEY, api_secret=SECRET))
    assert token == "tok-1"
    (form,) = service.forms
    assert form == {
        "method": "auth.getToken",
        "api_key": KEY,
        "format": "json",
        "api_sig": _expected_sig(form),
    }


@pytest.mark.parametrize(
    ("status", "body", "raw"),
    [
        (403, {"error": 10, "message": "Invalid API key"}, None),
        (200, {"error": 16}, None),
        (200, {"error": 16, "token": "tok-1"}, None),
        (200, {}, None),
        (200, {"token": ""}, None),
        (200, {"token": 7}, None),
        (200, ["tok"], None),
        (500, {"token": "tok-1"}, None),
        (200, None, b"<html>"),
    ],
)
def test_request_token_failure_is_none(
    status: int, body: Any, raw: bytes | None
) -> None:
    service = _Service(status, body, raw)
    assert (
        _ask(service, lambda c: request_token(c, api_key=KEY, api_secret=SECRET))
        is None
    )


def test_request_token_network_error_is_none() -> None:
    service = _Service()
    service.error = httpx.ConnectError("down")
    assert (
        _ask(service, lambda c: request_token(c, api_key=KEY, api_secret=SECRET))
        is None
    )


def test_approve_url_names_the_key_and_the_token_and_not_the_secret() -> None:
    url = urlsplit(approve_url(KEY, "tok &1"))
    assert (url.scheme, url.netloc, url.path) == ("https", "www.last.fm", "/api/auth/")
    assert parse_qs(url.query, strict_parsing=True) == {
        "api_key": [KEY],
        "token": ["tok &1"],
    }


def _session(service: _Service, token: str = "tok-1") -> tuple[str, str | None]:
    return _ask(
        service,
        lambda c: get_session(c, api_key=KEY, api_secret=SECRET, token=token),
    )


def test_session_key_comes_back_after_the_person_approved() -> None:
    service = _Service(
        body={
            "session": {"name": "Secret Person", "key": "session-one", "subscriber": 0}
        }
    )
    assert _session(service) == ("ok", "session-one")
    (form,) = service.forms
    assert form == {
        "method": "auth.getSession",
        "api_key": KEY,
        "token": "tok-1",
        "format": "json",
        "api_sig": _expected_sig(form),
    }


@pytest.mark.parametrize(
    ("status", "body", "raw", "word"),
    [
        (403, {"error": 14, "message": "not authorized"}, None, "pending"),
        (200, {"error": 14}, None, "pending"),
        (403, {"error": 15, "message": "expired"}, None, "expired"),
        (403, {"error": 4, "message": "invalid token"}, None, "expired"),
        (403, {"error": 10}, None, "failed"),
        (503, {"error": 16}, None, "failed"),
        (200, {"error": "14"}, None, "failed"),
        (200, {"error": 16, "session": {"key": "session-one"}}, None, "failed"),
        (200, {}, None, "failed"),
        (200, {"session": {}}, None, "failed"),
        (200, {"session": {"key": ""}}, None, "failed"),
        (200, {"session": {"key": 5}}, None, "failed"),
        (200, {"session": "x"}, None, "failed"),
        (500, {"session": {"key": "session-one"}}, None, "failed"),
        (200, None, b"<html>", "failed"),
    ],
)
def test_session_answers(status: int, body: Any, raw: bytes | None, word: str) -> None:
    assert _session(_Service(status, body, raw)) == (word, None)


def test_session_network_error_is_failed_and_silent(
    caplog: pytest.LogCaptureFixture,
) -> None:
    service = _Service()
    service.error = httpx.ConnectError("no route with tok-1")
    with caplog.at_level(logging.DEBUG):
        assert _session(service) == ("failed", None)
    assert _own(caplog) == []


def test_module_reads_no_environment_and_makes_no_client() -> None:
    source = open(
        __import__("app.lastfm_scrobble", fromlist=["x"]).__file__, encoding="utf-8"
    ).read()
    for word in ("os.environ", "getenv", "AsyncClient(", "logging", "print("):
        assert word not in source, word
