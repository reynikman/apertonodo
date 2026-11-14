"""Phone playback report for a book part goes to the book extension, not music ones (FT-596 review)."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any

from fake_extension import running_extension
from fastapi import FastAPI, Request, Response
from fastapi.testclient import TestClient

from app.main import create_app
from app.store import token_hash


def test_book_playback_failed_notifies_book_extension() -> None:
    """Audiobook playback failure report must go to the book extension (app.state.book_extensions).

    In main.py:974 the call app.state.extensions.failed(...) always raises KeyError for books,
    because the book extension name is registered in book_extensions, not in extensions.
    As a result the book extension does not learn about the failed file and does not deprioritize it.
    """
    received_reports: list[dict[str, Any]] = []

    ext_app = FastAPI()

    @ext_app.post("/v1/failed")
    async def ext_failed(request: Request) -> Response:
        body = await request.json()
        received_reports.append(body)
        return Response(status_code=204)

    with running_extension(ext_app) as book_url:
        app = create_app(
            catalog=[],
            extensions={},
            book_extensions={"mock_books": book_url},
        )
        token = "test_audiobook_token_review"
        app.state.sessions[token_hash(token)] = {
            "state": "ready",
            "track": {"id": "11111111-1111-1111-1111-111111111111"},
            "buffered_ms": 0,
            "media_path": "",
            "expires_at": datetime.now(timezone.utc) + timedelta(hours=1),
            "user_id": None,
            "legacy_owner": True,
            "prefer": None,
            "asset": "mock_books:file42",
            "book_file": 0,
        }

        with TestClient(app) as client:
            resp = client.post("/v1/playback/failed", json={"token": token})
            assert resp.status_code == 204

        # Book extension should have received notification about the failed file
        assert received_reports == [{"id": "file42", "reason": "bad_audio"}], (
            "Book extension did not receive playback failure notification"
        )
