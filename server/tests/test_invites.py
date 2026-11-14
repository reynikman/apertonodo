"""FT-856: a person chooses their own password.

Owner 14.10: "I create the user and let them in; the password they make up themselves, in the app.
I must not touch it."

Guarded here:
- the admin adds a person by name only and gets a one-time invite code (7 days); the person has no
  password until they claim the code;
- `POST /v1/auth/claim` (open, like login) takes name + code + new password, sets the password and
  signs the device in; the code works once; a wrong, used, expired or foreign code is refused the same way;
- a new code from the admin ("reset") ends the person's sessions, drops the old password and the old code;
- `POST /v1/auth/password` lets a signed-in person change their own password with the old one; other
  devices are signed out, this one stays;
- neither the code nor a password is ever echoed in a refusal or written to the log.

Not proven here: the screens in the app and on the admin page (their own tests), the phone.
"""

from __future__ import annotations

import asyncio
import hashlib
import logging
import secrets
from datetime import datetime, timedelta, timezone
from typing import Any

import asyncpg
import httpx
import pytest

from app.main import create_app
from app.migrate import apply

pytestmark = pytest.mark.real_auth

KEY = "k" * 32
ADMIN = {"x-apertonodo-key": KEY}
PASSWORD = "my own secret 1"


def _db(url: str, query: str, *args: Any) -> Any:
    async def run() -> Any:
        conn = await asyncpg.connect(url)
        try:
            return await conn.fetchval(query, *args)
        finally:
            await conn.close()

    return asyncio.run(run())


@pytest.fixture
def client(postgres_url: str) -> Any:
    asyncio.run(apply(postgres_url))
    _db(postgres_url, "TRUNCATE users, login_global_attempts, login_user_failures CASCADE")
    app = create_app(database_url=postgres_url, catalog=[], api_key=KEY)

    class Sync:
        def __getattr__(self, method: str) -> Any:
            def call(*args: Any, **kwargs: Any) -> httpx.Response:
                async def run() -> httpx.Response:
                    async with httpx.AsyncClient(
                        transport=httpx.ASGITransport(app=app), base_url="http://test"
                    ) as c:
                        return await getattr(c, method)(*args, **kwargs)

                return asyncio.run(run())

            return call

    return Sync()


def _invite(client: Any, name: str = "anna") -> tuple[str, str]:
    resp = client.post("/v1/admin/users", json={"username": name}, headers=ADMIN)
    assert resp.status_code == 201, resp.text
    body = resp.json()
    return body["user"]["id"], body["invite"]["code"]


def _claim(client: Any, code: str, name: str = "anna", password: str = PASSWORD) -> httpx.Response:
    return client.post(
        "/v1/auth/claim",
        json={"username": name, "code": code, "password": password, "device_name": "phone"},
    )


def _login(client: Any, password: str, name: str = "anna") -> httpx.Response:
    return client.post(
        "/v1/auth/login", json={"username": name, "password": password, "device_name": "phone"}
    )


def test_person_added_by_name_gets_a_code_and_no_password(client: Any, postgres_url: str) -> None:
    user_id, code = _invite(client)
    assert len(code.replace("-", "")) == 8
    assert _db(postgres_url, "SELECT password_hash FROM users WHERE id = $1::uuid", user_id) is None
    resp = client.post("/v1/admin/users", json={"username": "boris"}, headers=ADMIN)
    expires = datetime.fromisoformat(resp.json()["invite"]["expires_at"])
    assert timedelta(days=6, hours=23) < expires - datetime.now(timezone.utc) <= timedelta(days=7)


def test_code_is_stored_only_as_a_digest(client: Any, postgres_url: str) -> None:
    user_id, code = _invite(client)
    stored = _db(postgres_url, "SELECT code_hash FROM user_invites WHERE user_id = $1::uuid", user_id)
    assert stored and code not in stored and code.replace("-", "") not in stored


def test_person_added_with_a_password_gets_no_code(client: Any) -> None:
    resp = client.post(
        "/v1/admin/users", json={"username": "vera", "password": PASSWORD}, headers=ADMIN
    )
    assert resp.status_code == 201, resp.text
    assert "invite" not in resp.json()
    assert _login(client, PASSWORD, "vera").status_code == 200


def test_claim_sets_the_password_and_signs_in(client: Any) -> None:
    user_id, code = _invite(client)
    resp = _claim(client, code)
    assert resp.status_code == 200, resp.text
    assert resp.json()["user_id"] == user_id and resp.json()["token"]
    assert client.get(
        "/v1/auth/devices", headers={"authorization": f"Bearer {resp.json()['token']}"}
    ).status_code == 200
    assert _login(client, PASSWORD).status_code == 200


def test_code_is_read_without_case_spaces_and_dashes(client: Any) -> None:
    _, code = _invite(client)
    plain = code.replace("-", "")
    typed = f" {plain[:4].lower()} {plain[4:].lower()} "
    assert _claim(client, typed).status_code == 200


def test_code_works_once(client: Any) -> None:
    _, code = _invite(client)
    assert _claim(client, code).status_code == 200
    again = _claim(client, code, password="another secret 2")
    assert again.status_code == 401
    assert again.json() == {"status": "invalid_code"}
    assert _login(client, PASSWORD).status_code == 200


def test_wrong_code_and_foreign_code_are_refused_alike(client: Any, postgres_url: str) -> None:
    _, anna = _invite(client, "anna")
    _, boris = _invite(client, "boris")
    wrong = _claim(client, "ZZZZ-ZZZZ")
    foreign = _claim(client, boris, name="anna")
    unknown = _claim(client, anna, name="nobody")
    for resp in (wrong, foreign, unknown):
        assert resp.status_code == 401 and resp.json() == {"status": "invalid_code"}
    assert _db(postgres_url, "SELECT count(*) FROM users WHERE password_hash IS NOT NULL") == 0


def test_expired_code_is_refused(client: Any, postgres_url: str) -> None:
    user_id, code = _invite(client)
    _db(
        postgres_url,
        "UPDATE user_invites SET expires_at = now() - interval '1 second' WHERE user_id = $1::uuid",
        user_id,
    )
    resp = _claim(client, code)
    assert resp.status_code == 401 and resp.json() == {"status": "invalid_code"}


def test_short_password_is_refused_and_code_stays(client: Any) -> None:
    _, code = _invite(client)
    short = _claim(client, code, password="short")
    assert short.status_code == 422 and short.json() == {"status": "weak_password"}
    assert _claim(client, code).status_code == 200


def test_switched_off_person_cannot_claim(client: Any) -> None:
    user_id, code = _invite(client)
    assert client.post(
        f"/v1/admin/users/{user_id}/active", json={"active": False}, headers=ADMIN
    ).status_code == 200
    assert _claim(client, code).status_code == 401


def test_guessing_codes_is_limited(client: Any) -> None:
    _, code = _invite(client)
    answers = [_claim(client, f"AAAA-{n:04d}").status_code for n in range(12)]
    assert 429 in answers
    assert set(answers) <= {401, 429}


def test_claim_is_open_without_key_or_token(client: Any) -> None:
    _, code = _invite(client)
    resp = client.post(
        "/v1/auth/claim",
        json={"username": "anna", "code": code, "password": PASSWORD, "device_name": "phone"},
    )
    assert resp.status_code == 200


def test_new_code_resets_password_sessions_and_old_code(client: Any, postgres_url: str) -> None:
    user_id, first = _invite(client)
    token = _claim(client, first).json()["token"]
    resp = client.post(f"/v1/admin/users/{user_id}/invite", headers=ADMIN)
    assert resp.status_code == 200, resp.text
    second = resp.json()["invite"]["code"]
    assert second != first
    assert client.get("/v1/auth/devices", headers={"authorization": f"Bearer {token}"}).status_code == 401
    assert _login(client, PASSWORD).status_code == 401
    assert _db(postgres_url, "SELECT count(*) FROM user_invites WHERE user_id = $1::uuid", user_id) == 1
    assert _claim(client, second, password="fresh secret 3").status_code == 200


def test_new_code_for_unknown_person(client: Any) -> None:
    resp = client.post(f"/v1/admin/users/{secrets.token_hex(4)}-0000-0000-0000-000000000000/invite", headers=ADMIN)
    assert resp.status_code == 404


def test_only_admin_gives_codes(client: Any) -> None:
    user_id, code = _invite(client)
    token = _claim(client, code).json()["token"]
    bearer = {"authorization": f"Bearer {token}"}
    assert client.post("/v1/admin/users", json={"username": "eve"}, headers=bearer).status_code == 403
    assert client.post(f"/v1/admin/users/{user_id}/invite", headers=bearer).status_code == 403


def test_person_changes_own_password(client: Any) -> None:
    _, code = _invite(client)
    here = _claim(client, code).json()["token"]
    there = _login(client, PASSWORD).json()["token"]
    resp = client.post(
        "/v1/auth/password",
        json={"old_password": PASSWORD, "new_password": "brand new secret"},
        headers={"authorization": f"Bearer {here}"},
    )
    assert resp.status_code == 200 and resp.json() == {"status": "changed"}
    assert client.get("/v1/auth/devices", headers={"authorization": f"Bearer {here}"}).status_code == 200
    assert client.get("/v1/auth/devices", headers={"authorization": f"Bearer {there}"}).status_code == 401
    assert _login(client, PASSWORD).status_code == 401
    assert _login(client, "brand new secret").status_code == 200


def test_wrong_old_password_or_weak_new_changes_nothing(client: Any) -> None:
    _, code = _invite(client)
    token = _claim(client, code).json()["token"]
    bearer = {"authorization": f"Bearer {token}"}
    wrong = client.post(
        "/v1/auth/password", json={"old_password": "not mine 123", "new_password": "brand new secret"},
        headers=bearer,
    )
    assert wrong.status_code == 403 and wrong.json() == {"status": "wrong_password"}
    weak = client.post(
        "/v1/auth/password", json={"old_password": PASSWORD, "new_password": "short"}, headers=bearer
    )
    assert weak.status_code == 422 and weak.json() == {"status": "weak_password"}
    assert _login(client, PASSWORD).status_code == 200


def test_password_change_needs_a_signed_in_person(client: Any) -> None:
    resp = client.post(
        "/v1/auth/password", json={"old_password": PASSWORD, "new_password": "brand new secret"}
    )
    assert resp.status_code == 401


def test_codes_and_passwords_never_echoed_or_logged(client: Any, caplog: pytest.LogCaptureFixture) -> None:
    caplog.set_level(logging.DEBUG)
    _, code = _invite(client)
    answers = [
        _claim(client, code, password="short").text,
        _claim(client, code).text,
        _claim(client, code, password="another secret 2").text,
    ]
    secrets_seen = [code, code.replace("-", ""), PASSWORD, "another secret 2"]
    for text in answers + [caplog.text]:
        for value in secrets_seen:
            assert value not in text
    assert hashlib.sha256(code.encode()).hexdigest() not in caplog.text
