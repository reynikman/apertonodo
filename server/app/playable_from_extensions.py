"""Determine whether a song is playable by querying extensions (POST /v1/has, FT-758 / FT-594d).

Contract (contracts/extension-api.md):
- GET {url}/v1/info: only the response is remembered (has / no has), failure retried on next call;
- POST {url}/v1/has sent concurrently in batches of <= 50 pairs (asyncio.gather), order preserved, timeout 2s;
- Any error, non-200, timeout, or malformed response -> extension "did not answer";
- Summary per pair: True for any -> True; otherwise if at least one did not answer -> True; otherwise False;
- Empty names/titles -> False without request;
- Log without song titles and artist names.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Any

import httpx

logger = logging.getLogger("apertonodo")

TIMEOUT_S = 2.0
BATCH_SIZE = 50

STATUS_HAS = "has"
STATUS_NO_HAS = "no_has"
STATUS_FAILED = "failed"


def _is_empty(artist: str, title: str) -> bool:
    """Pair is empty if artist or title is empty after stripping whitespace."""
    return (
        not isinstance(artist, str)
        or not isinstance(title, str)
        or not artist.strip()
        or not title.strip()
    )


def _parse_hits(data: Any, expected_len: int) -> list[bool] | None:
    """Response is valid only as 200 {"hits": [bool, ...]} of same length, each value bool."""
    if not isinstance(data, dict):
        return None
    hits = data.get("hits")
    if not isinstance(hits, list) or len(hits) != expected_len:
        return None
    if not all(type(x) is bool for x in hits):
        return None
    return hits


class Playable:
    """Track availability check across connected extensions."""

    def __init__(
        self,
        urls: dict[str, str],
        *,
        client: httpx.AsyncClient,
        timeout: float = TIMEOUT_S,
        **kwargs: Any,
    ) -> None:
        self._urls = {name: url.rstrip("/") for name, url in urls.items()}
        self._client = client
        self._timeout = timeout
        self._info_status: dict[str, str] = {}
        self._info_lock: asyncio.Lock | None = None

    def _get_lock(self) -> asyncio.Lock:
        if self._info_lock is None:
            self._info_lock = asyncio.Lock()
        return self._info_lock

    async def _check_extension(self, name: str, url: str) -> str:
        try:
            response = await asyncio.wait_for(
                self._client.get(f"{url}/v1/info", timeout=self._timeout),
                timeout=self._timeout,
            )
            if response.status_code != 200:
                logger.warning(
                    "extension %s info failed with status %d",
                    name,
                    response.status_code,
                )
                return STATUS_FAILED
            try:
                data = response.json()
            except Exception as exc:
                logger.warning(
                    "extension %s info invalid json: %s", name, type(exc).__name__
                )
                return STATUS_FAILED
            if not isinstance(data, dict):
                logger.warning("extension %s info response is not a dict", name)
                return STATUS_FAILED
            features = data.get("features")
            if isinstance(features, (list, tuple, set)) and "has" in features:
                return STATUS_HAS
            return STATUS_NO_HAS
        except Exception as exc:
            logger.warning("extension %s info error: %s", name, type(exc).__name__)
            return STATUS_FAILED

    async def _ensure_info(self) -> set[str]:
        if len(self._info_status) == len(self._urls):
            return set()
        async with self._get_lock():
            pending = [
                (name, url)
                for name, url in self._urls.items()
                if name not in self._info_status
            ]
            failed: set[str] = set()
            if not pending:
                return failed
            statuses = await asyncio.gather(
                *(self._check_extension(name, url) for name, url in pending)
            )
            for (name, _), status in zip(pending, statuses, strict=True):
                if status == STATUS_HAS:
                    self._info_status[name] = STATUS_HAS
                elif status == STATUS_NO_HAS:
                    self._info_status[name] = STATUS_NO_HAS
                else:
                    failed.add(name)
            return failed

    async def _ask_has(
        self, name: str, url: str, batch: list[tuple[str, str]]
    ) -> list[bool] | None:
        payload = {"pairs": [{"artist": a, "title": t} for a, t in batch]}
        try:
            response = await asyncio.wait_for(
                self._client.post(
                    f"{url}/v1/has",
                    json=payload,
                    timeout=self._timeout,
                ),
                timeout=self._timeout,
            )
            if response.status_code != 200:
                logger.warning(
                    "extension %s /v1/has returned status %d",
                    name,
                    response.status_code,
                )
                return None
            try:
                data = response.json()
            except Exception as exc:
                logger.warning(
                    "extension %s /v1/has invalid json: %s",
                    name,
                    type(exc).__name__,
                )
                return None
            hits = _parse_hits(data, len(batch))
            if hits is None:
                logger.warning("extension %s /v1/has malformed response body", name)
                return None
            return hits
        except Exception as exc:
            logger.warning(
                "extension %s /v1/has request error: %s", name, type(exc).__name__
            )
            return None

    async def _query_batch(
        self,
        batch: list[tuple[str, str]],
        active_exts: list[tuple[str, str]],
        has_failed_info: bool,
    ) -> list[bool]:
        if not active_exts:
            return [has_failed_info] * len(batch)

        responses = await asyncio.gather(
            *(self._ask_has(name, url, batch) for name, url in active_exts)
        )

        batch_result: list[bool] = []
        for i in range(len(batch)):
            if any(resp[i] for resp in responses if resp is not None):
                batch_result.append(True)
            elif has_failed_info or any(resp is None for resp in responses):
                batch_result.append(True)
            else:
                batch_result.append(False)
        return batch_result

    async def pairs(self, pairs: list[tuple[str, str]]) -> list[bool]:
        """Check (artist, title) pairs, returning a list of bools in the same order."""
        if not pairs:
            return []

        valid_items: list[tuple[int, tuple[str, str]]] = []
        for idx, (artist, title) in enumerate(pairs):
            if not _is_empty(artist, title):
                valid_items.append((idx, (artist, title)))

        if not valid_items:
            return [False] * len(pairs)

        failed_info_exts = await self._ensure_info()
        has_failed_info = bool(failed_info_exts)

        active_exts = [
            (name, url)
            for name, url in self._urls.items()
            if self._info_status.get(name) == STATUS_HAS
        ]

        valid_pairs = [pair for _, pair in valid_items]
        valid_indices = [idx for idx, _ in valid_items]

        batches = [
            valid_pairs[i : i + BATCH_SIZE]
            for i in range(0, len(valid_pairs), BATCH_SIZE)
        ]

        batch_results = await asyncio.gather(
            *(
                self._query_batch(batch, active_exts, has_failed_info)
                for batch in batches
            )
        )

        valid_results: list[bool] = []
        for batch_res in batch_results:
            valid_results.extend(batch_res)

        results = [False] * len(pairs)
        for idx, res in zip(valid_indices, valid_results, strict=True):
            results[idx] = res

        return results

    async def playable(self, artist: str, titles: list[str]) -> list[bool]:
        """Check tracks of a single artist."""
        return await self.pairs([(artist, title) for title in titles])
