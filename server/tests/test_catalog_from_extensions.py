"""FT-757 (FT-594c, P8): genre catalog is built from extension exports, not from releases table.

`app.catalog_from_extensions.build(database_url, urls, client=…)` reads `GET /v1/catalog` of each
extension that has `features: ["catalog", …]` in `GET /v1/info` (`contracts/extension-api.md`),
and writes `catalog_artists` the same way `app.catalog.build` does: single transaction, old catalog is visible until commit.

Guarded:
- popularity of same artist from two extensions and two rows is summed; spelling is most frequent;
- row without `genre` or with word not in `contracts/genres.txt` does not enter genre catalog (as today);
- "not an artist" (VA, "Compilation"), empty name, garbage row — skip row, not fail;
- no export (`404` or no `catalog` in `features`) — extension skipped;
- **old catalog is not touched** if at least one extension with export answered non-`200`/`404`, is down, or
  stream was cut in middle; and if zero rows were collected — core does not wipe catalog with empty data;
- log contains no artist names.

What this test does not prove: wiring to `python -m app.catalog build` and `EXTENSIONS` (lead); live extensions.
"""

from __future__ import annotations

import asyncio
import json
import logging
from collections.abc import AsyncIterator, Callable
from typing import Any

import asyncpg
import httpx
import pytest

from app import catalog_from_extensions
from app.migrate import apply

ROCK = "classic-rock"
JAZZ = "jazz"
A = "http://ext-a.test"
B = "http://ext-b.test"
OLD = [(ROCK, "old artist", "Old Artist", "O", 7)]


def line(
    artist: Any, title: str = "Song", popularity: Any = 1, genre: Any = ROCK
) -> dict[str, Any]:
    row: dict[str, Any] = {"artist": artist, "title": title, "popularity": popularity}
    if genre is not None:
        row["genre"] = genre
    return row


def ndjson(rows: list[Any]) -> bytes:
    return "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows).encode()


class Cut(httpx.AsyncByteStream):
    """Stream interrupted after first bytes: this is how extension crashing halfway looks."""

    def __init__(self, head: bytes) -> None:
        self.head = head

    async def __aiter__(self) -> AsyncIterator[bytes]:
        yield self.head
        raise httpx.RemoteProtocolError(
            "peer closed connection without sending complete message body"
        )


class Ext:
    """Extension from test: `features` and export reply are configurable; remembers queries."""

    def __init__(
        self,
        rows: list[Any] | None = None,
        *,
        features: tuple[str, ...] = ("catalog", "has"),
    ) -> None:
        self.rows = rows or []
        self.features = list(features)
        self.status = 200
        self.cut = False
        self.down = False
        self.calls: list[str] = []

    def answer(self, request: httpx.Request) -> httpx.Response:
        self.calls.append(request.url.path)
        if self.down:
            raise httpx.ConnectError("refused", request=request)
        if request.url.path == "/v1/info":
            return httpx.Response(
                200, json={"name": "ext", "version": "1", "features": self.features}
            )
        assert request.url.path == "/v1/catalog", request.url.path
        if self.status != 200:
            return httpx.Response(self.status, json={"error": "unavailable"})
        if self.cut:
            return httpx.Response(200, stream=Cut(ndjson(self.rows[:1])))
        return httpx.Response(
            200,
            content=ndjson(self.rows),
            headers={"content-type": "application/x-ndjson"},
        )


def client_for(exts: dict[str, Ext]) -> httpx.AsyncClient:
    def route(request: httpx.Request) -> httpx.Response:
        return exts[f"{request.url.scheme}://{request.url.host}"].answer(request)

    return httpx.AsyncClient(transport=httpx.MockTransport(route))


def _db(url: str, work: Callable[[asyncpg.Connection], Any]) -> Any:
    async def run() -> Any:
        conn = await asyncpg.connect(url)
        try:
            return await work(conn)
        finally:
            await conn.close()

    return asyncio.run(run())


@pytest.fixture
def base(postgres_url: str) -> str:
    asyncio.run(apply(postgres_url))

    async def prepare(conn: asyncpg.Connection) -> None:
        await conn.execute("DELETE FROM catalog_artists")
        await conn.execute("DELETE FROM catalog_built")
        await conn.copy_records_to_table(
            "catalog_artists",
            records=OLD,
            columns=("genre", "artist_key", "name", "letter", "popularity"),
        )

    _db(postgres_url, prepare)
    return postgres_url


def rows(url: str) -> list[tuple[str, str, str, str, int]]:
    async def read(conn: asyncpg.Connection) -> list[tuple[str, str, str, str, int]]:
        found = await conn.fetch(
            "SELECT genre, artist_key, name, letter, popularity FROM catalog_artists ORDER BY genre, artist_key"
        )
        return [tuple(r) for r in found]

    return _db(url, read)


def built_at(url: str) -> Any:
    return _db(
        url,
        lambda conn: conn.fetchval("SELECT built_at FROM catalog_built WHERE id = 1"),
    )


def run(url: str, exts: dict[str, Ext]) -> Any:
    async def go() -> Any:
        async with client_for(exts) as client:
            return await catalog_from_extensions.build(
                url, {name: name for name in exts}, client=client
            )

    return asyncio.run(go())


# --- building -----------------------------------------------------------------


def test_two_extensions_sum_into_one_catalog(base: str) -> None:
    a = Ext(
        [
            line("Velvet Orchard", popularity=3),
            line("Velvet Orchard", "Other", 2),
            line("Кино", genre=JAZZ),
        ]
    )
    b = Ext([line("velvet orchard", popularity=10)])
    result = run(base, {A: a, B: b})
    assert (result.status, result.artists, result.genres) == ("built", 2, 2)
    assert rows(base) == [
        (ROCK, "velvet orchard", "Velvet Orchard", "V", 15),
        (JAZZ, "кино", "Кино", "К", 1),
    ]
    assert built_at(base) is not None
    assert "/v1/catalog" in a.calls and "/v1/catalog" in b.calls


def test_rows_without_a_known_genre_stay_out(base: str) -> None:
    a = Ext(
        [
            line("Glass Harbor"),
            line("No Genre", genre=None),
            line("Odd Genre", genre="Rock"),
            line("X", genre="polka"),
        ]
    )
    run(base, {A: a})
    assert [r[1] for r in rows(base)] == ["glass harbor"]


def test_not_artists_and_rubbish_lines_are_skipped(base: str) -> None:
    a = Ext(
        [
            line("Glass Harbor"),
            line("VA"),
            line("Various Artists"),
            line("Сборник"),
            line(""),
            line("   "),
            line(None),
            line(42),
            line("Bad Popularity", popularity="7"),
            line("Negative", popularity=-1),
            line("A" * 81),
            "not an object",
            [1, 2],
        ]
    )
    result = run(base, {A: a})
    assert result.status == "built"
    assert [r[1] for r in rows(base)] == ["glass harbor"]


def test_most_frequent_spelling_wins(base: str) -> None:
    a = Ext([line("ABBA"), line("Abba"), line("ABBA"), line("abba")])
    run(base, {A: a})
    assert rows(base) == [(ROCK, "abba", "ABBA", "A", 4)]


def test_extension_without_catalog_is_skipped(base: str) -> None:
    a = Ext([line("Glass Harbor")])
    b = Ext([line("Never Asked")], features=("pins",))
    c = Ext([line("Not Found")])
    c.status = 404
    result = run(base, {A: a, B: b, "http://ext-c.test": c})
    assert result.status == "built"
    assert [r[1] for r in rows(base)] == ["glass harbor"]
    assert "/v1/catalog" not in b.calls


# --- old catalog is not touched ----------------------------------------------


@pytest.mark.parametrize("status", [503, 500, 401])
def test_failed_extension_keeps_the_old_catalog(base: str, status: int) -> None:
    a = Ext([line("Glass Harbor")])
    b = Ext([line("Velvet Orchard")])
    b.status = status
    result = run(base, {A: a, B: b})
    assert result.status == "kept"
    assert rows(base) == OLD
    assert built_at(base) is None


def test_stream_cut_in_the_middle_keeps_the_old_catalog(base: str) -> None:
    a = Ext([line("Glass Harbor"), line("Velvet Orchard"), line("Кино", genre=JAZZ)])
    a.cut = True
    result = run(base, {A: a})
    assert result.status == "kept"
    assert rows(base) == OLD


def test_extension_down_keeps_the_old_catalog(base: str) -> None:
    a = Ext([line("Glass Harbor")])
    b = Ext([line("Velvet Orchard")])
    b.down = True
    result = run(base, {A: a, B: b})
    assert result.status == "kept"
    assert rows(base) == OLD


def test_nothing_to_build_keeps_the_old_catalog(base: str) -> None:
    empty = Ext([])
    assert run(base, {A: empty}).status == "kept"
    assert rows(base) == OLD

    no_genre = Ext([line("No Genre", genre=None)])
    assert run(base, {A: no_genre}).status == "kept"
    assert rows(base) == OLD

    nobody = Ext([line("Never Asked")], features=("pins",))
    assert run(base, {A: nobody}).status == "kept"
    assert run(base, {}).status == "kept"
    assert rows(base) == OLD


# --- logging ------------------------------------------------------------------


def test_log_has_counts_not_names(base: str, caplog: pytest.LogCaptureFixture) -> None:
    caplog.set_level(logging.DEBUG)
    a = Ext([line("Velvet Orchard"), line("Кино", genre=JAZZ)])
    run(base, {A: a})
    b = Ext([line("Glass Harbor")])
    b.status = 503
    run(base, {A: a, B: b})
    text = "\n".join(r.getMessage() for r in caplog.records)
    for name in ("Velvet", "velvet", "Кино", "кино", "Glass", "Song"):
        assert name not in text


# --- return 1: blind Sonnet, findings confirmed by tests ---------------------


class Raw(Ext):
    """Extension serving export as raw bytes."""

    def __init__(self, body: bytes | httpx.AsyncByteStream) -> None:
        super().__init__([])
        self.body = body

    def answer(self, request: httpx.Request) -> httpx.Response:
        if request.url.path != "/v1/catalog":
            return super().answer(request)
        self.calls.append(request.url.path)
        if isinstance(self.body, bytes):
            return httpx.Response(200, content=self.body)
        return httpx.Response(200, stream=self.body)


@pytest.mark.parametrize(
    "bad",
    [
        json.dumps(line("Evil\u0000Name"), ensure_ascii=False),
        json.dumps(
            line("Bad\ud800Name")
        ),  # lone surrogate: JSON accepts it, UTF-8 does not
        json.dumps(line("Bell\u0007Name"), ensure_ascii=False),
    ],
)
def test_a_name_the_base_cannot_store_is_a_skipped_line(base: str, bad: str) -> None:
    body = (json.dumps(line("Glass Harbor")) + "\n" + bad + "\n").encode()
    result = run(base, {A: Raw(body)})
    assert result.status == "built"
    assert [r[1] for r in rows(base)] == ["glass harbor"]


def test_only_newline_ends_a_line(base: str) -> None:
    """`ensure_ascii=False` writes U+2028 and U+2029 as is — only `\\n` cuts lines."""
    body = "".join(
        json.dumps(r, ensure_ascii=False) + "\n"
        for r in (
            line("Foo Bar", popularity=5),
            line("Baz\u2029Qux"),
            line("Glass Harbor"),
        )
    ).encode()
    run(base, {A: Raw(body)})
    assert [r[1] for r in rows(base)] == ["baz qux", "foo bar", "glass harbor"]


def test_an_endless_line_is_bounded_in_memory(base: str) -> None:
    import tracemalloc

    class Endless(httpx.AsyncByteStream):
        async def __aiter__(self) -> AsyncIterator[bytes]:
            yield (json.dumps(line("Glass Harbor")) + "\n").encode()
            for _ in range(96):
                yield b"x" * (1 << 20)
            yield b"\n" + (json.dumps(line("Velvet Orchard")) + "\n").encode()

    tracemalloc.start()
    try:
        result = run(base, {A: Raw(Endless())})
        peak = tracemalloc.get_traced_memory()[1]
    finally:
        tracemalloc.stop()
    assert peak < 16 << 20, f"peak {peak >> 20} MiB"
    assert result.status == "built"
    assert [r[1] for r in rows(base)] == ["glass harbor", "velvet orchard"]


def test_big_chunks_do_not_make_reading_quadratic(base: str) -> None:
    """Extension serves export in 4 MiB chunks: line parsing is linear (lead fix)."""
    import time

    body = "".join(
        json.dumps(line(f"Artist {i % 5000}", popularity=1), ensure_ascii=False) + "\n"
        for i in range(200_000)
    ).encode()

    class Chunks(httpx.AsyncByteStream):
        async def __aiter__(self) -> AsyncIterator[bytes]:
            for i in range(0, len(body), 4 << 20):
                yield body[i : i + (4 << 20)]

    began = time.monotonic()
    result = run(base, {A: Raw(Chunks())})
    assert time.monotonic() - began < 8
    assert (result.status, result.artists) == ("built", 5000)


# --- FT-838: выгрузка на боевых размерах ----------------------------------------


def test_catalog_stream_waits_longer_than_the_default_five_seconds(base: str) -> None:
    """Расширение отдаёт первую строку выгрузки не сразу: источник сперва считает
    запрос по миллионам строк. С таймаутом httpx по умолчанию (5 с на чтение)
    пересборка на боевых размерах молча оставляла бы старый каталог."""
    seen: dict[str, Any] = {}
    ext = Ext([line("Velvet Orchard")])

    def route(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/v1/catalog":
            seen.update(request.extensions["timeout"])
        return ext.answer(request)

    async def go() -> Any:
        async with httpx.AsyncClient(transport=httpx.MockTransport(route)) as client:
            return await catalog_from_extensions.build(base, {A: A}, client=client)

    result = asyncio.run(go())
    assert result.status == "built"
    assert seen["read"] is not None and seen["read"] >= 300, seen
    assert seen["connect"] is not None and seen["connect"] <= 10, seen
