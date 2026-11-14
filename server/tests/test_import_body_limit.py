"""FT-646 (Х1): import request body is not read into memory beyond the limit.

Files larger than 10 MiB were previously rejected by the server — but only after reading the entire body. A gigabyte body
was loaded into memory before the first check. Here the body is fed in chunks, tracking how much the server read.
"""

from __future__ import annotations

import asyncio
import base64
import json
from collections.abc import Iterator
from typing import Any

import pytest
from fastapi import FastAPI

from app import imports
from app.import_formats import MAX_BYTES

CHUNK = 64 * 1024
CREATE = "/v1/imports"
SAVE = "/v1/imports/00000000-0000-0000-0000-000000000000/save"
HUGE = 200 * 1024 * 1024


@pytest.fixture(autouse=True)
def reports_as_on_the_server() -> Iterator[None]:
    """Error collector — as in production: it does not read the request body.

    Adjacent error report tests leave it enabled with default settings, which
    reads the entire body ahead of the handler — and the byte count would measure it, not import.
    Production configuration — `max_request_body_size="never"` in `app/error_reports.py`.
    """
    import sentry_sdk

    sentry_sdk.init(max_request_body_size="never")
    try:
        yield
    finally:
        sentry_sdk.get_client().close()
        sentry_sdk.init()


class _NoLibrary:
    async def connect(self) -> Any:
        raise AssertionError("query with invalid body must not reach the database")


def _app() -> FastAPI:
    app = FastAPI()
    app.include_router(imports.router)
    app.state.library = _NoLibrary()
    return app


def _endless(total: int, fill: bytes = b"A") -> Iterator[bytes]:
    left = total
    while left > 0:
        size = min(CHUNK, left)
        left -= size
        yield fill * size


def _post(
    path: str, chunks: Iterator[bytes], *, declared: int | str | None = None
) -> tuple[int, dict[str, Any], int]:
    """Status, response, and how many body bytes the server managed to read."""
    taken = 0
    sent: list[dict[str, Any]] = []
    headers = [(b"content-type", b"application/json")]
    if declared is not None:
        headers.append((b"content-length", str(declared).encode()))
    scope = {
        "type": "http",
        "asgi": {"version": "3.0"},
        "http_version": "1.1",
        "method": "POST",
        "scheme": "http",
        "path": path,
        "raw_path": path.encode(),
        "query_string": b"",
        "root_path": "",
        "headers": headers,
        "client": ("127.0.0.1", 1),
        "server": ("test", 80),
        "state": {},
    }

    async def receive() -> dict[str, Any]:
        nonlocal taken
        chunk = next(chunks, None)
        if chunk is None:
            return {"type": "http.request", "body": b"", "more_body": False}
        taken += len(chunk)
        return {"type": "http.request", "body": chunk, "more_body": True}

    async def send(message: dict[str, Any]) -> None:
        sent.append(message)

    asyncio.run(_app()(scope, receive, send))
    status = next(m["status"] for m in sent if m["type"] == "http.response.start")
    body = b"".join(
        m.get("body", b"") for m in sent if m["type"] == "http.response.body"
    )
    return status, json.loads(body), taken


def test_limits_fit_the_largest_allowed_file_and_nothing_more() -> None:
    # 10 MiB in base64 — 13,981,016 characters; plus file name and JSON braces.
    base64_size = 4 * ((MAX_BYTES + 2) // 3)
    assert base64_size + 1024 <= imports.MAX_BODY_BYTES <= base64_size + 1024 * 1024
    assert imports.MAX_SAVE_BYTES == 1024 * 1024


def test_huge_upload_is_refused_without_reading_it() -> None:
    status, answer, taken = _post(CREATE, _endless(HUGE))
    assert status == 413
    assert answer["status"] == "too_large"
    assert answer["message"]
    assert taken <= imports.MAX_BODY_BYTES + CHUNK, f"read {taken} bytes"


def test_honest_length_over_the_limit_is_refused_before_the_body() -> None:
    status, answer, taken = _post(CREATE, _endless(HUGE), declared=HUGE)
    assert (status, answer["status"]) == (413, "too_large")
    assert taken <= CHUNK, f"read {taken} bytes — length was declared upfront"


def test_a_lying_length_does_not_open_the_door() -> None:
    status, answer, taken = _post(CREATE, _endless(HUGE), declared=100)
    assert (status, answer["status"]) == (413, "too_large")
    assert taken <= imports.MAX_BODY_BYTES + CHUNK


def test_unreadable_length_is_not_trusted() -> None:
    for declared in (-5, "много", ""):
        status, answer, taken = _post(CREATE, _endless(HUGE), declared=declared)
        assert (status, answer["status"]) == (413, "too_large"), declared
        assert taken <= imports.MAX_BODY_BYTES + CHUNK


def test_body_at_the_limit_is_read_whole() -> None:
    # Exactly at limit — not yet "too large": body is read, rejection happens by content.
    status, answer, taken = _post(CREATE, _endless(imports.MAX_BODY_BYTES))
    assert (status, answer["status"]) == (422, "bad_file")
    assert taken == imports.MAX_BODY_BYTES


def test_one_byte_over_the_limit_is_too_large() -> None:
    status, answer, _ = _post(CREATE, _endless(imports.MAX_BODY_BYTES + 1))
    assert (status, answer["status"]) == (413, "too_large")


def test_small_garbage_is_still_a_bad_file_not_too_large() -> None:
    status, answer, _ = _post(CREATE, iter([b"\xff\xfe not json"]))
    assert (status, answer["status"]) == (422, "bad_file")
    status, answer, _ = _post(CREATE, iter([]))
    assert (status, answer["status"]) == (422, "bad_file")


def test_body_cut_into_single_bytes_is_put_back_together() -> None:
    # File containing only blank lines: read completely and rejected as "no songs".
    body = json.dumps(
        {"name": "a.txt", "data": base64.b64encode(b"\n\n").decode()}
    ).encode()
    status, answer, taken = _post(CREATE, (bytes([b]) for b in body))
    assert (status, answer["status"]) == (422, "empty")
    assert taken == len(body)


def test_huge_save_request_is_refused_without_reading_it() -> None:
    status, answer, taken = _post(SAVE, _endless(HUGE))
    assert status == 413
    assert answer["status"] == "too_large"
    assert taken <= imports.MAX_SAVE_BYTES + CHUNK, f"read {taken} bytes"


def test_save_limit_is_its_own_not_the_upload_one() -> None:
    # "Save" request carries only row selection; it doesn't need a file-sized body.
    status, _, taken = _post(SAVE, _endless(imports.MAX_SAVE_BYTES + 1))
    assert status == 413
    assert taken <= imports.MAX_SAVE_BYTES + CHUNK
    status, answer, taken = _post(SAVE, _endless(HUGE), declared=HUGE)
    assert (status, answer["status"]) == (413, "too_large")
    assert taken <= CHUNK


def test_error_collector_on_the_server_does_not_read_bodies() -> None:
    # The limit above holds only as long as the error collector does not read the body ahead of the handler.
    import inspect

    from app import app_reports, error_reports

    for module in (error_reports, app_reports):
        assert 'max_request_body_size="never"' in inspect.getsource(module), (
            module.__name__
        )
