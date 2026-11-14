"""FT-725 (C2, R-A99, contract D5a): audiobook endpoints for mobile client.

Module `app/book_api.py` connects existing components (FT-720 books, FT-724 "to shelf", resume position,
FT-71x ref tokens for findings) with HTTP. Contract with mobile — `mobile/lib/book_client.dart`:

- `GET    /v1/books/search?q=&limit=` -> `{books: [{ref, title, author, narrator, year,
  size_bytes}]}`; search failure — 503 `book_search_unavailable`;
- `GET    /v1/books/shelf` -> `{books: [book]}`, book = `{id, title, author, narrator, year,
  size_bytes, parts, shelved_at}`;
- `POST   /v1/books/shelf` `{ref}` -> `{state: ok|exists, book}`; 410 — ref expired or alien;
  409 `{status: no_space|limit|not_a_book}`; 503 — file source did not respond;
- `DELETE /v1/books/shelf/{id}` -> 204;
- `GET    /v1/books/{id}` -> `{book, parts: [{number, title, start_ms, end_ms}]}`; not own — 404;
- `POST   /v1/books/{id}/play` `{part}` -> `{token, state}`; part outside book — 404;
- `PUT    /v1/books/positions` `{items}` and `GET /v1/books/positions?after=&limit=` -> `{items, mark}`.

`install_books(app, *, database_url, search, files, play, refs=None, space=...)` — `search(q, limit)`,
`files(asset, hint)`, `play(conn, user_id, book_id, part)` are supplied externally (in prod — extension and
engine, here fakes).

Guarded: responses contain neither `asset`, nor `hint`, nor source name; each user has their own shelf;
body is not read beyond limit; DB failure is 503, not 500; log contains neither query nor title.

What this test does not prove: real search, files and audio (lead wiring in `main.py`), that
the phone plays the book.
"""

from __future__ import annotations

import asyncio
import json
import logging
import uuid
from collections.abc import Awaitable, Callable, Iterator
from pathlib import Path
from typing import Any

import asyncpg
import pytest
from fastapi.testclient import TestClient

from app.book_api import install_books
from app.book_found import FoundBook
from app.main import create_app
from app.migrate import apply

ROOT = Path(__file__).resolve().parents[2]
CATALOG = json.loads((ROOT / "contracts" / "fixtures" / "catalog.json").read_text())[
    "tracks"
]

SEARCH = "/v1/books/search"
SHELF = "/v1/books/shelf"
POSITIONS = "/v1/books/positions"

ASSET = "bookhost:7250001"
HINT = "opaque-hint-725"
TITLE = "Secret Novel Title"
QUERY = "secretquery725"
STAMP = "2026-10-10T11:00:00.000Z"
SECRETS = (ASSET, "7250001", HINT, "bookhost", "asset", "hint", "info_hash", "magnet")


def found(asset: str = ASSET, title: str = TITLE) -> FoundBook:
    return FoundBook(
        title=title,
        author="Secret Author",
        narrator="Secret Reader",
        year=2011,
        size_bytes=3003,
        popularity=5,
        asset=asset,
        hint=HINT,
    )


def listing(count: int = 3) -> list[dict[str, Any]]:
    return [
        {"index": n, "name": f"Book/{n:02d}.mp3", "length": 1000 + n}
        for n in range(1, count + 1)
    ]


class Search:
    def __init__(self) -> None:
        self.calls: list[tuple[str, int]] = []
        self.answer: list[FoundBook] = [found()]
        self.error: Exception | None = None

    async def __call__(self, q: str, limit: int) -> list[FoundBook]:
        self.calls.append((q, limit))
        if self.error is not None:
            raise self.error
        return list(self.answer)


class Files:
    def __init__(self) -> None:
        self.calls: list[tuple[str, str]] = []
        self.answer: Any = listing()

    async def __call__(self, asset: str, hint: str) -> Any:
        self.calls.append((asset, hint))
        return self.answer


class Play:
    def __init__(self) -> None:
        self.calls: list[tuple[uuid.UUID, uuid.UUID, int]] = []

    async def __call__(
        self, conn: asyncpg.Connection, user: uuid.UUID, book: uuid.UUID, part: int
    ) -> tuple[str, str] | None:
        self.calls.append((user, book, part))
        return (f"tok-{part}", "ready")


def _db(url: str, work: Callable[[asyncpg.Connection], Awaitable[Any]]) -> Any:
    async def run() -> Any:
        conn = await asyncpg.connect(url)
        try:
            return await work(conn)
        finally:
            await conn.close()

    return asyncio.run(run())


@pytest.fixture(autouse=True)
def reports_as_on_the_server() -> Iterator[None]:
    import sentry_sdk

    sentry_sdk.init(max_request_body_size="never")
    try:
        yield
    finally:
        sentry_sdk.get_client().close()
        sentry_sdk.init()


@pytest.fixture
def base(postgres_url: str, test_principal: dict[str, Any]) -> str:
    asyncio.run(apply(postgres_url))

    async def prepare(conn: asyncpg.Connection) -> None:
        await conn.execute("TRUNCATE books CASCADE")
        await conn.execute(
            "INSERT INTO users (id, username) VALUES ($1, $2) ON CONFLICT (id) DO NOTHING",
            uuid.UUID(str(test_principal["id"])),
            f"me-{str(test_principal['id'])[:8]}",
        )

    _db(postgres_url, prepare)
    return postgres_url


@pytest.fixture
def search() -> Search:
    return Search()


@pytest.fixture
def files() -> Files:
    return Files()


@pytest.fixture
def play() -> Play:
    return Play()


def _app(url: str | None, search: Search, files: Files, play: Play, **kw: Any) -> Any:
    app = create_app(
        database_url=url,
        catalog=CATALOG,
    )
    install_books(app, database_url=url, search=search, files=files, play=play, **kw)
    return app


@pytest.fixture
def client(base: str, search: Search, files: Files, play: Play) -> TestClient:
    return TestClient(_app(base, search, files, play))


@pytest.fixture
def as_bob(
    base: str, test_principal: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> Callable[[], None]:
    bob = uuid.uuid4()

    def switch() -> None:
        async def add(conn: asyncpg.Connection) -> None:
            await conn.execute(
                "INSERT INTO users (id, username) VALUES ($1, $2)",
                bob,
                f"bob-{bob.hex[:8]}",
            )

        _db(base, add)
        monkeypatch.setitem(test_principal, "id", str(bob))

    return switch


def clean(text: str) -> None:
    low = text.lower()
    for word in SECRETS:
        assert word.lower() not in low, word


def find_ref(client: TestClient) -> str:
    reply = client.get(SEARCH, params={"q": QUERY})
    assert reply.status_code == 200, reply.text
    return reply.json()["books"][0]["ref"]


def shelve(client: TestClient) -> dict[str, Any]:
    reply = client.post(SHELF, json={"ref": find_ref(client)})
    assert reply.status_code == 200, reply.text
    return reply.json()


# --- search ------------------------------------------------------------------


def test_search_gives_refs_and_fields_without_source(
    client: TestClient, search: Search
) -> None:
    reply = client.get(SEARCH, params={"q": QUERY, "limit": "5"})
    assert reply.status_code == 200
    books = reply.json()["books"]
    assert len(books) == 1
    book = books[0]
    assert set(book) == {
        "ref",
        "title",
        "author",
        "narrator",
        "year",
        "size_bytes",
        "language",
    }
    assert (
        book["title"] == TITLE
        and book["year"] == 2011
        and book["size_bytes"] == 3003
        and book["language"] == "ru"
    )
    assert isinstance(book["ref"], str) and book["ref"]
    assert search.calls == [(QUERY, 5)]
    clean(reply.text.replace(TITLE, "").replace("Secret Author", ""))


def test_search_limit_is_capped_and_cut(client: TestClient, search: Search) -> None:
    search.answer = [found(f"bookhost:{n}", f"T{n}") for n in range(80)]
    reply = client.get(SEARCH, params={"q": QUERY, "limit": "999"})
    assert reply.status_code == 200
    assert search.calls[-1][1] == 50
    assert len(reply.json()["books"]) == 50


@pytest.mark.parametrize(
    "params",
    [
        {"q": ""},
        {"q": "a"},
        {"q": "x" * 201},
        {"q": QUERY, "limit": "-1"},
        {"q": QUERY, "limit": "abc"},
        {"q": QUERY, "limit": "0"},
    ],
)
def test_search_rejects_bad_query(
    client: TestClient, search: Search, params: dict[str, str]
) -> None:
    assert client.get(SEARCH, params=params).status_code == 400
    assert search.calls == []


def test_search_failure_is_not_an_empty_list(
    client: TestClient, search: Search
) -> None:
    search.error = RuntimeError("boom")
    reply = client.get(SEARCH, params={"q": QUERY})
    assert reply.status_code == 503
    assert reply.json() == {"status": "book_search_unavailable"}


# --- shelf -------------------------------------------------------------------


def test_shelve_by_ref_then_shelf_lists_it(client: TestClient, files: Files) -> None:
    out = shelve(client)
    assert out["state"] == "ok"
    book = out["book"]
    assert set(book) == {
        "id",
        "title",
        "author",
        "narrator",
        "year",
        "size_bytes",
        "parts",
        "shelved_at",
    }
    assert book["title"] == TITLE and book["parts"] == 3
    assert book["shelved_at"].endswith("Z")
    assert files.calls == [(ASSET, HINT)]

    listed = client.get(SHELF)
    assert listed.status_code == 200
    assert [b["id"] for b in listed.json()["books"]] == [book["id"]]
    clean(listed.text)


def test_shelve_twice_is_exists(client: TestClient) -> None:
    first = shelve(client)
    again = shelve(client)
    assert again["state"] == "exists"
    assert again["book"]["id"] == first["book"]["id"]


def test_unknown_ref_is_expired(client: TestClient, files: Files) -> None:
    reply = client.post(SHELF, json={"ref": "no-such-ref"})
    assert reply.status_code == 410
    assert files.calls == []


def test_someone_elses_ref_is_expired(
    client: TestClient, files: Files, as_bob: Callable[[], None]
) -> None:
    ref = find_ref(client)
    as_bob()
    assert client.post(SHELF, json={"ref": ref}).status_code == 410
    assert files.calls == []


@pytest.mark.parametrize("body", [{}, {"ref": 5}, [], "x", {"ref": None}])
def test_shelve_bad_body(client: TestClient, body: Any) -> None:
    assert client.post(SHELF, json=body).status_code == 400


def test_shelve_body_is_bounded(client: TestClient) -> None:
    reply = client.post(SHELF, content=b'{"ref":"' + b"a" * 200_000 + b'"}')
    assert reply.status_code == 413


def test_no_files_from_source_is_503(client: TestClient, files: Files) -> None:
    files.answer = None
    reply = client.post(SHELF, json={"ref": find_ref(client)})
    assert reply.status_code == 503
    assert client.get(SHELF).json()["books"] == []


def test_no_space_is_409(base: str, search: Search, files: Files, play: Play) -> None:
    client = TestClient(_app(base, search, files, play, space=10))
    reply = client.post(SHELF, json={"ref": find_ref(client)})
    assert reply.status_code == 409
    assert reply.json() == {"status": "no_space"}


def test_not_a_book_is_409(client: TestClient, files: Files) -> None:
    files.answer = [{"index": 1, "name": "readme.txt", "length": 10}]
    reply = client.post(SHELF, json={"ref": find_ref(client)})
    assert reply.status_code == 409
    assert reply.json() == {"status": "not_a_book"}


def test_unshelve(client: TestClient) -> None:
    book_id = shelve(client)["book"]["id"]
    assert client.post(f"{SHELF}/{book_id}/remove").status_code == 204
    assert client.get(SHELF).json()["books"] == []
    assert client.get(f"/v1/books/{book_id}").status_code == 404


def test_unshelve_bad_id_is_404(client: TestClient) -> None:
    assert client.post(f"{SHELF}/not-a-uuid/remove").status_code == 404


def test_shelves_are_personal(client: TestClient, as_bob: Callable[[], None]) -> None:
    book_id = shelve(client)["book"]["id"]
    as_bob()
    assert client.get(SHELF).json()["books"] == []
    assert client.get(f"/v1/books/{book_id}").status_code == 404
    assert client.post(f"/v1/books/{book_id}/play", json={"part": 1}).status_code == 404


# --- book and audio ----------------------------------------------------------


def test_details_list_parts_in_order(client: TestClient) -> None:
    book_id = shelve(client)["book"]["id"]
    reply = client.get(f"/v1/books/{book_id}")
    assert reply.status_code == 200
    body = reply.json()
    assert body["book"]["id"] == book_id
    assert [p["number"] for p in body["parts"]] == [1, 2, 3]
    for part in body["parts"]:
        assert set(part) == {"number", "title", "start_ms", "end_ms"}
    clean(reply.text)


def test_details_bad_id_is_404(client: TestClient) -> None:
    assert client.get("/v1/books/" + "z" * 36).status_code == 404
    assert client.get(f"/v1/books/{uuid.uuid4()}").status_code == 404


def test_play_part(
    client: TestClient, play: Play, test_principal: dict[str, Any]
) -> None:
    book_id = shelve(client)["book"]["id"]
    reply = client.post(f"/v1/books/{book_id}/play", json={"part": 2})
    assert reply.status_code == 200
    assert reply.json() == {"token": "tok-2", "state": "ready"}
    assert play.calls == [(uuid.UUID(str(test_principal["id"])), uuid.UUID(book_id), 2)]


@pytest.mark.parametrize("part", [0, 4, -1])
def test_play_part_outside_book_is_404(
    client: TestClient, play: Play, part: int
) -> None:
    book_id = shelve(client)["book"]["id"]
    assert (
        client.post(f"/v1/books/{book_id}/play", json={"part": part}).status_code == 404
    )
    assert play.calls == []


@pytest.mark.parametrize("body", [{}, {"part": "1"}, {"part": True}, {"part": 1.5}, []])
def test_play_bad_body(client: TestClient, play: Play, body: Any) -> None:
    book_id = shelve(client)["book"]["id"]
    assert client.post(f"/v1/books/{book_id}/play", json=body).status_code == 400
    assert play.calls == []


# --- resume position ---------------------------------------------------------


def test_positions_round_trip(client: TestClient) -> None:
    book_id = shelve(client)["book"]["id"]
    item = {
        "book_id": book_id,
        "part": 2,
        "position_ms": 61_000,
        "finished": False,
        "updated_at": STAMP,
    }
    put = client.post(POSITIONS, json={"items": [item]})
    assert put.status_code == 200, put.text
    assert put.json()["items"][0]["position_ms"] == 61_000

    got = client.get(POSITIONS, params={"after": "0", "limit": "500"})
    assert got.status_code == 200
    body = got.json()
    assert [i["book_id"] for i in body["items"]] == [book_id]
    assert isinstance(body["mark"], int) and body["mark"] > 0

    later = client.get(POSITIONS, params={"after": str(body["mark"])})
    assert later.json() == {"items": [], "mark": body["mark"]}


@pytest.mark.parametrize("body", [{}, {"items": "x"}, []])
def test_positions_bad_body(client: TestClient, body: Any) -> None:
    assert client.post(POSITIONS, json=body).status_code == 400


@pytest.mark.parametrize("params", [{"after": "-1"}, {"after": "x"}, {"limit": "0"}])
def test_positions_bad_query(client: TestClient, params: dict[str, str]) -> None:
    assert client.get(POSITIONS, params=params).status_code == 400


# --- failures and logging ----------------------------------------------------


def test_no_database_is_503_not_500(search: Search, files: Files, play: Play) -> None:
    client = TestClient(_app(None, search, files, play))
    assert client.get(SHELF).status_code == 503
    assert client.get(f"/v1/books/{uuid.uuid4()}").status_code == 503
    assert client.get(POSITIONS).status_code == 503


def test_nothing_secret_in_the_log(
    client: TestClient, caplog: pytest.LogCaptureFixture
) -> None:
    caplog.set_level(logging.DEBUG)
    book_id = shelve(client)["book"]["id"]
    client.get(f"/v1/books/{book_id}")
    client.post(f"/v1/books/{book_id}/play", json={"part": 1})
    text = caplog.text
    for word in (QUERY, TITLE, ASSET, HINT, "Secret Author"):
        assert word not in text, word


def test_same_book_found_by_two_people(
    client: TestClient, as_bob: Callable[[], None]
) -> None:
    find_ref(client)
    as_bob()
    reply = client.post(SHELF, json={"ref": find_ref(client)})
    assert reply.status_code == 200, reply.text
    assert reply.json()["state"] == "ok"


def test_database_failure_mid_request_is_503(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    from app import books

    async def broken(*args: Any, **kwargs: Any) -> Any:
        raise asyncpg.PostgresError("boom")

    monkeypatch.setattr(books, "shelf", broken)
    reply = client.get(SHELF)
    assert reply.status_code == 503
    assert reply.json() == {"status": "library_unavailable"}


def test_first_finders_ref_survives_a_second_finder(
    client: TestClient, as_bob: Callable[[], None], test_principal: dict[str, Any]
) -> None:
    mine = find_ref(client)
    me = test_principal["id"]
    as_bob()
    find_ref(client)
    test_principal["id"] = me
    reply = client.post(SHELF, json={"ref": mine})
    assert reply.status_code == 200, reply.text
