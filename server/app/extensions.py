"""Extensions client per `contracts/extension-api.md` contract (FT-589).

The core does not know where an extension gets its file: a local folder on disk
and a p2p engine look identical to it. The extension runs in the internal compose
network, its address is provided to the core via
`EXTENSIONS="<name>=<url>,<name>=<url>"`. Neither addresses, file ids, nor song
titles are logged from here.
"""

from __future__ import annotations

import asyncio
import logging
import re
import time
from collections.abc import AsyncIterator, Callable
from pathlib import Path
from typing import Any

import httpx
from fastapi.responses import StreamingResponse

logger = logging.getLogger(__name__)

_NAME = re.compile(r"[a-z][a-z0-9-]{0,31}")
# Identifier per contract has no "/" or ":": it goes into path "/v1/files/{id}" and key "<name>:<id>".
_ID = re.compile(r"[A-Za-z0-9._~-]{1,200}")
# A dead extension must not stall Play: connect timeout is 1s, while
# find response per contract is up to 10s.
CONNECT_S = 1.0
FIND_READ_S = 10.0
CALL_READ_S = 5.0
# The extension holds `prepare` itself while the file is being prepared (up to 8 s), and only then
# answers `preparing`: reading it for less would drop a song that is ready in a second.
PREPARE_READ_S = 12.0
# Cover: the extension might need to extract the file from the release — like the former core path.
COVER_READ_S = 60.0
COVER_MAX_BYTES = 10 * 1024 * 1024
# Extension itself waits up to 30s for missing bytes (contract), phone drops silence
# sooner — like other streams, wait 20s.
STREAM_READ_S = 20.0
PREPARE_POLL_S = 0.5
_PASS_HEADERS = ("content-type", "content-length", "content-range", "accept-ranges")


def parse_extensions(text: str) -> dict[str, str]:
    """`name=url,name=url` -> dictionary. Bad string raises `ValueError`: playing silently without extension is worse."""
    found: dict[str, str] = {}
    for part in (item.strip() for item in text.split(",")):
        if not part:
            continue
        name, sep, url = part.partition("=")
        name, url = name.strip(), url.strip()
        if not sep or not url or not _NAME.fullmatch(name):
            raise ValueError("EXTENSIONS: expected <name>=<url>, name — [a-z][a-z0-9-]{0,31}")
        if name in found:
            raise ValueError("EXTENSIONS: duplicate name")
        found[name] = url.rstrip("/")
    return found


class Extensions:
    """All connected extensions; each call is by name."""

    def __init__(self, urls: dict[str, str]) -> None:
        self.urls = dict(urls)

    def __bool__(self) -> bool:
        return bool(self.urls)

    async def find(self, name: str, track: dict[str, Any]) -> list[dict[str, Any]]:
        """What the extension has for this track, best first. Network error raises exception to caller."""
        body = {
            key: track[key]
            for key in ("id", "artist", "title", "album", "duration_ms", "recording_mbid")
            if track.get(key)
        }
        async with httpx.AsyncClient(
            timeout=httpx.Timeout(FIND_READ_S, connect=CONNECT_S)
        ) as client:
            response = await client.post(
                f"{self.urls[name]}/v1/find", json={"track": body, "limit": 4}
            )
            response.raise_for_status()
            items = response.json().get("items") or []
        return [
            item for item in items
            if isinstance(item, dict) and isinstance(item.get("id"), str) and _ID.fullmatch(item["id"])
        ]

    async def prepare(self, name: str, file_id: str, deadline: float) -> dict[str, Any] | None:
        """Wait for `preparing` -> `ready` within Play budget (`deadline` by `time.monotonic`).

        Return `ready` response (dictionary, may include `stats`) or `None` if file is not ready."""
        async with httpx.AsyncClient(
            timeout=httpx.Timeout(PREPARE_READ_S, connect=CONNECT_S)
        ) as client:
            while True:
                response = await client.post(f"{self.urls[name]}/v1/prepare", json={"id": file_id})
                if response.status_code == 404:
                    return None
                response.raise_for_status()
                answer = response.json()
                state = answer.get("state")
                if state == "ready":
                    return answer
                if state != "preparing" or time.monotonic() + PREPARE_POLL_S >= deadline:
                    return None
                await asyncio.sleep(PREPARE_POLL_S)

    async def failed(self, name: str, file_id: str, reason: str) -> None:
        async with httpx.AsyncClient(
            timeout=httpx.Timeout(CALL_READ_S, connect=CONNECT_S)
        ) as client:
            response = await client.post(
                f"{self.urls[name]}/v1/failed", json={"id": file_id, "reason": reason}
            )
            response.raise_for_status()

    def fetch_file(self, name: str, file_id: str, dest: Path) -> str:
        """Entire file streamed to disk, not memory. Synchronous: called from worker thread. Return Content-Type."""
        timeout = httpx.Timeout(STREAM_READ_S, connect=CONNECT_S)
        try:
            with httpx.Client(timeout=timeout) as client, client.stream(
                "GET", f"{self.urls[name]}/v1/files/{file_id}"
            ) as response:
                response.raise_for_status()
                with dest.open("wb") as out:
                    for chunk in response.iter_raw():
                        out.write(chunk)
                return response.headers.get("content-type", "")
        except BaseException:
            dest.unlink(missing_ok=True)
            raise

    def cover(self, artist: str, title: str) -> bytes | None:
        """Album cover from the first extension with `cover` feature. Synchronous: called from image thread.

        Not an image, not 200, network error — try next extension; none provided — `None`.
        """
        for name, url in self.urls.items():
            try:
                with httpx.Client(timeout=httpx.Timeout(COVER_READ_S, connect=CONNECT_S)) as client:
                    info = client.get(f"{url}/v1/info")
                    if info.status_code != 200 or "cover" not in (info.json().get("features") or []):
                        continue
                    response = client.post(f"{url}/v1/cover", json={"artist": artist, "title": title})
            except (httpx.HTTPError, ValueError) as exc:
                logger.info("extension %s: cover failed: %s", name, type(exc).__name__)
                continue
            kind = response.headers.get("content-type", "")
            if response.status_code == 200 and kind.startswith("image/") and 0 < len(response.content) <= COVER_MAX_BYTES:
                return response.content
        return None

    async def pin(self, name: str, file_id: str, pinned: bool) -> None:
        """Pin or unpin file. Extension without `pins` in `features` receives nothing."""
        async with httpx.AsyncClient(
            timeout=httpx.Timeout(CALL_READ_S, connect=CONNECT_S)
        ) as client:
            info = await client.get(f"{self.urls[name]}/v1/info")
            info.raise_for_status()
            if "pins" not in (info.json().get("features") or []):
                return
            response = await client.post(
                f"{self.urls[name]}/v1/pins", json={"id": file_id, "pinned": pinned}
            )
            response.raise_for_status()

    async def proxy_stream(
        self,
        name: str,
        file_id: str,
        *,
        method: str,
        range_header: str | None,
        aborted: type[Exception],
        on_end: Callable[[int, str], None] | None = None,
        on_progress: Callable[[int], None] | None = None,
        path: str | None = None,
    ) -> StreamingResponse:
        """Proxy extension file to phone, in chunks as received, with its Range header.

        `aborted` — exception "interrupted mid-response, reason already logged" (known by core).
        `path` — alternative path in extension: book parts stream from `/v1/books/file/{id}/{index}` (FT-772).
        """
        client = httpx.AsyncClient(timeout=httpx.Timeout(STREAM_READ_S, connect=CONNECT_S))
        head = method.upper() == "HEAD"
        try:
            request = client.build_request(
                "GET",
                f"{self.urls[name]}{path or f'/v1/files/{file_id}'}",
                headers={"Range": range_header} if range_header else {},
            )
            response = await client.send(request, stream=True)
        except BaseException:
            await client.aclose()
            raise
        chunks = response.aiter_raw()
        first = b""
        if not head:
            # The first chunk is read before sending headers: an extension silent from
            # the beginning yields 503 to the core rather than 206 with zero bytes.
            try:
                first = await anext(chunks, b"")
            except BaseException:
                await response.aclose()
                await client.aclose()
                raise

        async def body() -> AsyncIterator[bytes]:
            sent = 0
            status = response.status_code
            reason = "complete" if status < 400 else f"extension answered {status}"
            try:
                if head:
                    return
                if first:
                    sent += len(first)
                    yield first
                    if on_progress is not None:
                        on_progress(sent)
                async for chunk in chunks:
                    sent += len(chunk)
                    yield chunk
                    if on_progress is not None:
                        on_progress(sent)
            except GeneratorExit:
                reason = "client gone"
                raise
            except httpx.TimeoutException as exc:
                reason = "extension stalled"
                raise aborted(reason) from exc
            except Exception as exc:
                reason = "extension error"
                raise aborted(reason) from exc
            finally:
                await response.aclose()
                await client.aclose()
                if on_end is not None:
                    on_end(sent, reason)

        out = {key: response.headers[key] for key in _PASS_HEADERS if key in response.headers}
        out["Cache-Control"] = "no-store"
        return StreamingResponse(
            body(),
            status_code=response.status_code,
            headers=out,
            media_type=out.get("content-type", "audio/mpeg"),
        )
