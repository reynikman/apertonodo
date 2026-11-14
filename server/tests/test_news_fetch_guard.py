"""FT-572 (Р-A83): news collector only accesses public addresses — with proxy as well.

A user inputs any link, the server fetches it itself. Without protection this is a door
inside: `http://sidecar:3030/`, database, router, tailnet machines behind proxy
(`100.64.0.0/10`). Therefore the address is checked in our code against allowed IPs —
before connecting and before sending to proxy — and anew after each redirect.

Contract of `app/news_fetch.py` module (card FT-572):
- `await fetch(url, *, resolve=..., transport=None, proxy=None, max_bytes=2 MiB, timeout=15.0)`
  → object with `.status`, `.body` (bytes), `.url` (URL after redirects);
- rejection — `NewsFetchRefused` exception; no network request is sent;
- `resolve(host) -> list[str]` — host to IP resolution (mocked in tests);
- `transport` — `httpx` transport (`MockTransport` in tests, no network);
- redirects — manual, at most 5, each target checked anew;
- response larger than `max_bytes` — `NewsFetchRefused` (abort, not reading entirely).
"""

from __future__ import annotations

import asyncio
import re
from pathlib import Path
from typing import Any

import httpx
import pytest

from app import news_fetch

ROOT = Path(__file__).resolve().parents[2]
PUBLIC_IP = "93.184.216.34"
NAMES = {
    "news.example.org": [PUBLIC_IP],
    "inside.example.org": ["192.168.1.1"],       # public name, internal address
    "mixed.example.org": [PUBLIC_IP, "10.0.0.5"],  # if at least one is internal — refuse
    "sidecar": ["172.18.0.4"],
    "postgres": ["172.18.0.2"],
    "localhost": ["127.0.0.1"],
}


def _resolve(host: str) -> list[str]:
    return NAMES.get(host, [host])


class Recorder:
    def __init__(self, handler: Any) -> None:
        self.calls: list[httpx.Request] = []
        self.handler = handler

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.calls.append(request)
        return self.handler(request)


def _host(request: httpx.Request) -> str:
    return request.headers.get("host", request.url.host).split(":")[0]


def _run(coro: Any) -> Any:
    return asyncio.run(coro)


FORBIDDEN = [
    "http://sidecar:3030/",
    "http://postgres:5432/",
    "http://192.168.1.1/",
    "http://127.0.0.1/",
    "http://localhost:8000/",
    "http://[::1]/",
    "http://100.64.0.3:8080/",
    "http://10.0.0.1/",
    "http://172.16.5.4/",
    "http://169.254.169.254/latest/meta-data/",
    "http://[fd00::1]/",
    "http://0.0.0.0/",
    "http://224.0.0.1/",
    "http://inside.example.org/feed.xml",
    "http://mixed.example.org/feed.xml",
    "file:///etc/passwd",
    "gopher://news.example.org/",
    "ftp://news.example.org/feed.xml",
]


@pytest.mark.parametrize("url", FORBIDDEN)
@pytest.mark.parametrize("proxy", [None, "http://192.168.1.2:8888"])
def test_internal_or_odd_address_is_refused_before_any_request(url: str, proxy: str | None) -> None:
    recorder = Recorder(lambda request: httpx.Response(200, text="secret"))
    with pytest.raises(news_fetch.NewsFetchRefused):
        _run(news_fetch.fetch(url, resolve=_resolve, transport=httpx.MockTransport(recorder), proxy=proxy))
    assert recorder.calls == [], "request went out even though address is internal"


def test_public_address_is_fetched() -> None:
    recorder = Recorder(lambda request: httpx.Response(200, content=b"<rss/>"))
    result = _run(news_fetch.fetch("https://news.example.org/feed.xml", resolve=_resolve, transport=httpx.MockTransport(recorder)))
    assert result.status == 200 and result.body == b"<rss/>"
    assert len(recorder.calls) == 1


@pytest.mark.parametrize("target", ["http://192.168.1.1/admin", "http://engine:3030/streams", "http://inside.example.org/", "file:///etc/passwd"])
def test_redirect_to_internal_address_is_refused(target: str) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        if _host(request) == "news.example.org":
            return httpx.Response(302, headers={"location": target})
        return httpx.Response(200, text="secret")

    recorder = Recorder(handler)
    with pytest.raises(news_fetch.NewsFetchRefused):
        _run(news_fetch.fetch("https://news.example.org/feed.xml", resolve=_resolve, transport=httpx.MockTransport(recorder)))
    assert all(_host(r) == "news.example.org" for r in recorder.calls), "redirect led to internal network"


def test_public_redirect_is_followed_but_not_forever() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/final":
            return httpx.Response(200, content=b"ok")
        return httpx.Response(301, headers={"location": "https://news.example.org/final"})

    result = _run(news_fetch.fetch("https://news.example.org/start", resolve=_resolve, transport=httpx.MockTransport(handler)))
    assert result.body == b"ok" and str(result.url).endswith("/final")

    loop = Recorder(lambda request: httpx.Response(302, headers={"location": "https://news.example.org/again"}))
    with pytest.raises(news_fetch.NewsFetchRefused):
        _run(news_fetch.fetch("https://news.example.org/again", resolve=_resolve, transport=httpx.MockTransport(loop)))
    assert len(loop.calls) <= 6


def test_oversized_answer_is_cut_off() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=b"x" * 5000)

    with pytest.raises(news_fetch.NewsFetchRefused):
        _run(news_fetch.fetch("https://news.example.org/big", resolve=_resolve, transport=httpx.MockTransport(handler), max_bytes=1000))


def test_news_proxy_is_hermetic_in_tests_and_blanked_in_local_guard() -> None:
    import os

    assert not os.environ.get("NEWS_PROXY")
    guard = (ROOT / "scripts" / "public_guard_local.sh").read_text()
    assert re.search(r"\bNEWS_PROXY=''", guard), "NEWS_PROXY is not reset in scripts/public_guard_local.sh"
