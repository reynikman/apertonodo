"""FT-726 (Kn-1b, P-A88, book contract FT-721): core queries the book extension."""

from __future__ import annotations

import asyncio
from collections.abc import Callable, Coroutine
from dataclasses import replace
import time
from typing import Any

import httpx

from app.book_found import FoundBook, found_books
from app.books import normalize_asset

CONNECT_S: float = 1.0
FIND_READ_S: float = 10.0
CALL_READ_S: float = 5.0

__all__ = ["BookExtension"]


class BookExtension:
    """Book extension client adhering to `contracts/extension-api.md`."""

    def __init__(
        self,
        name: str,
        url: str,
        *,
        transport: httpx.AsyncBaseTransport | httpx.BaseTransport | None = None,
        poll_s: float = 1.0,
        wait_s: float = 15.0,
        clock: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], Coroutine[Any, Any, None]] = asyncio.sleep,
    ) -> None:
        self.name = name
        self.url = url.rstrip("/")
        self.transport = transport
        self.poll_s = poll_s
        self.wait_s = wait_s
        self.clock = clock
        self.sleep = sleep

    def _client(self, timeout: httpx.Timeout) -> httpx.AsyncClient:
        kwargs: dict[str, Any] = {"timeout": timeout}
        if self.transport is not None:
            kwargs["transport"] = self.transport
        return httpx.AsyncClient(**kwargs)

    @staticmethod
    def _item_rank(item: dict[str, Any]) -> tuple[int, int]:
        raw_pop = item.get("popularity")
        pop_val = (
            raw_pop
            if isinstance(raw_pop, int)
            and not isinstance(raw_pop, bool)
            and raw_pop > 0
            else -1
        )
        raw_sz = item.get("size")
        sz_val = (
            raw_sz
            if isinstance(raw_sz, int)
            and not isinstance(raw_sz, bool)
            and raw_sz >= 0
            else 0
        )
        return (pop_val, sz_val)

    async def search(self, query: str, limit: int = 50) -> list[FoundBook]:
        """Searches for books via `POST /v1/books/find` of the extension."""
        clean_query = str(query)[:200]
        if isinstance(limit, bool) or not isinstance(limit, int):
            clean_limit = 50
        else:
            clean_limit = max(1, min(limit, 50))

        timeout = httpx.Timeout(FIND_READ_S, connect=CONNECT_S)
        async with self._client(timeout) as client:
            response = await client.post(
                f"{self.url}/v1/books/find",
                json={"query": clean_query, "limit": clean_limit},
            )
            response.raise_for_status()
            try:
                data = response.json()
            except Exception as exc:
                raise ValueError("Invalid JSON response from books extension") from exc

        if not isinstance(data, dict):
            raise ValueError("Response body must be a dict")
        items = data.get("items")
        if not isinstance(items, list):
            raise ValueError("Response items must be a list")

        raw_hits: list[object] = []
        items_by_asset: dict[str, dict[str, Any]] = {}

        for it in items:
            if isinstance(it, dict):
                raw_id = it.get("id")
                asset = f"{self.name}:{raw_id}"
                hit = dict(it)
                hit["asset"] = asset
                hit["hint"] = raw_id
                raw_hits.append(hit)

                rank = self._item_rank(it)
                if (
                    asset not in items_by_asset
                    or rank > self._item_rank(items_by_asset[asset])
                ):
                    items_by_asset[asset] = it
            else:
                raw_hits.append(it)

        books = found_books(raw_hits, limit=clean_limit)
        result: list[FoundBook] = []
        for book in books:
            orig = items_by_asset.get(book.asset)
            if orig is not None:
                raw_author = orig.get("author")
                author = (
                    raw_author.strip()
                    if isinstance(raw_author, str) and raw_author.strip()
                    else book.author
                )
                raw_narrator = orig.get("narrator")
                narrator = (
                    raw_narrator.strip()
                    if isinstance(raw_narrator, str) and raw_narrator.strip()
                    else book.narrator
                )
                raw_year = orig.get("year")
                year = (
                    raw_year
                    if isinstance(raw_year, int)
                    and not isinstance(raw_year, bool)
                    and 1000 <= raw_year <= 2100
                    else book.year
                )
                if (author, narrator, year) != (book.author, book.narrator, book.year):
                    book = replace(book, author=author, narrator=narrator, year=year)
            result.append(book)
        return result

    async def files(self, asset: str, hint: str) -> list[dict[str, Any]] | None:
        """Requests audiobook files via `POST /v1/books/files`."""
        if not isinstance(asset, str) or not isinstance(hint, str):
            return None

        normalized = normalize_asset(asset)
        if normalized is None or normalized != asset:
            return None

        prefix, sep, file_id = asset.partition(":")
        if prefix != self.name or file_id != hint:
            return None

        timeout = httpx.Timeout(CALL_READ_S, connect=CONNECT_S)
        deadline = self.clock() + self.wait_s

        async with self._client(timeout) as client:
            while True:
                response = await client.post(
                    f"{self.url}/v1/books/files",
                    json={"id": hint},
                )
                if response.status_code == 404:
                    return None
                response.raise_for_status()

                try:
                    data = response.json()
                except Exception:
                    return None

                if not isinstance(data, dict):
                    return None

                state = data.get("state")
                if state == "ready":
                    raw_files = data.get("files")
                    if not isinstance(raw_files, list):
                        return None
                    result: list[dict[str, Any]] = []
                    for f in raw_files:
                        if not isinstance(f, dict):
                            return None
                        length = f.get("size") if f.get("size") is not None else f.get("length")
                        result.append(
                            {
                                "index": f.get("index"),
                                "name": f.get("name"),
                                "length": length,
                            }
                        )
                    return result

                if state == "preparing":
                    if self.clock() + self.poll_s > deadline:
                        return None
                    await self.sleep(self.poll_s)
                    continue

                return None
