"""FT-772: audiobooks are connected to the server under their own `BOOK_EXTENSIONS` variable.

End-to-end path over real HTTP: fake extension `kind: books` -> search -> bookshelf -> Play part -> bytes
of this exact file via `/v1/stream/{token}`. Music `EXTENSIONS` is not set — audiobooks
are enabled independently of music switchover (FT-598).
"""

from __future__ import annotations

import asyncio
import uuid
from typing import Any

import asyncpg
import pytest
from fake_extension import running_extension
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response
from fastapi.testclient import TestClient

from app.main import create_app
from app.migrate import apply

BOOK_ID = "book-772"
PARTS = {0: b"ID3-part-one-" * 64, 1: b"ID3-part-two-" * 64, 2: b"ID3-part-three-" * 64}
NAMES = {0: "01 Glava.mp3", 1: "02 Glava.mp3", 2: "03 Glava.mp3"}


def _book_extension(calls: list[str]) -> FastAPI:
    app = FastAPI()

    @app.get("/v1/info")
    def info() -> dict[str, Any]:
        return {"api": 1, "name": "bt-books", "version": "0.1.0", "kind": "books", "features": []}

    @app.post("/v1/books/find")
    async def find(request: Request) -> dict[str, Any]:
        calls.append("find")
        return {
            "items": [
                {
                    "id": BOOK_ID,
                    "title": "Мастер и Маргарита",
                    "author": "Михаил Булгаков",
                    "narrator": "",
                    "year": 2011,
                    "size": 50 * 1024 * 1024,
                    "language": "ru",
                    "popularity": 3,
                }
            ]
        }

    @app.post("/v1/books/files")
    async def files(request: Request) -> Any:
        body = await request.json()
        calls.append(f"files {body['id']}")
        if body["id"] != BOOK_ID:
            return JSONResponse({"error": "unknown_id"}, status_code=404)
        return {
            "state": "ready",
            "files": [
                {"index": i, "name": NAMES[i], "size": 6 * 1024 * 1024} for i in PARTS
            ],
        }

    @app.get("/v1/books/file/{item}/{index}")
    def file(item: str, index: int) -> Response:
        calls.append(f"file {item} {index}")
        if item != BOOK_ID or index not in PARTS:
            return JSONResponse({"error": "unknown_id"}, status_code=404)
        return Response(PARTS[index], media_type="audio/mpeg")

    return app


@pytest.fixture
def base(postgres_url: str, test_principal: dict[str, Any]) -> str:
    async def prepare() -> None:
        await apply(postgres_url)
        conn = await asyncpg.connect(postgres_url)
        try:
            await conn.execute("TRUNCATE books CASCADE")
            await conn.execute(
                "INSERT INTO users (id, username) VALUES ($1, $2) ON CONFLICT (id) DO NOTHING",
                uuid.UUID(str(test_principal["id"])),
                f"me-{str(test_principal['id'])[:8]}",
            )
        finally:
            await conn.close()

    asyncio.run(prepare())
    return postgres_url


def _core(database_url: str, books: dict[str, str] | None) -> Any:
    return create_app(
        database_url=database_url,
        catalog=[],
        extensions={},
        book_extensions=books,
    )


def test_book_part_plays_through_the_book_extension(base: str) -> None:
    calls: list[str] = []
    with (
        running_extension(_book_extension(calls)) as url,
        TestClient(_core(base, {"bt-books": url})) as client,
    ):
        found = client.get("/v1/books/search", params={"q": "мастер"})
        assert found.status_code == 200, found.text
        books = found.json()["books"]
        assert [b["title"] for b in books] == ["Мастер и Маргарита"]
        assert "bt-books" not in found.text and BOOK_ID not in found.text

        shelved = client.post("/v1/books/shelf", json={"ref": books[0]["ref"]})
        assert shelved.status_code == 200, shelved.text
        book = shelved.json()["book"]
        assert book["parts"] == 3

        played = client.post(f"/v1/books/{book['id']}/play", json={"part": 2})
        assert played.status_code == 200, played.text
        token = played.json()["token"]
        assert played.json()["state"] == "ready"

        stream = client.get(f"/v1/stream/{token}")
        assert stream.status_code in (200, 206), stream.text
        assert stream.content == PARTS[1], "part 2 is the second file in filename order"
        assert f"file {BOOK_ID} 1" in calls


def test_without_book_extensions_search_is_unavailable_not_missing(base: str) -> None:
    with TestClient(_core(base, {})) as client:
        reply = client.get("/v1/books/search", params={"q": "мастер"})
        assert reply.status_code == 503, "book endpoints are wired and honestly report unavailable rather than 404"
        assert reply.json() == {"status": "book_search_unavailable"}


def test_book_extensions_come_from_env(base: str, monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[str] = []
    with running_extension(_book_extension(calls)) as url:
        monkeypatch.setenv("BOOK_EXTENSIONS", f"bt-books={url}")
        app = create_app(
            database_url=base,
            catalog=[],
            extensions={},
        )
        with TestClient(app) as client:
            found = client.get("/v1/books/search", params={"q": "мастер"})
            assert found.status_code == 200, found.text
            assert calls == ["find"]
