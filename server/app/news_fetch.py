"""FT-572 (Р-A83): the news collector goes only to public addresses.

A person pastes any link and the server follows it itself. Without an address check this is
a door into the internal network: `sidecar:3030`, Postgres, the router, tailnet machines
(`100.64.0.0/10`) — both directly and through a proxy. So this module is the only
path of the collector to the network, and it is built like this:

- the scheme is only `http`/`https`; the name is resolved to an IP by our code, and the IP
  is checked before connecting — loopback, private `10/8`, `172.16/12`,
  `192.168/16`, CGNAT `100.64/10`, link-local `169.254/16`, `fc00::/7`, `::1`,
  unspecified, multicast are forbidden; the names `localhost` and compose services without a dot;
- without a proxy the connection goes to the checked IP, and the host name stays in
  `Host`/SNI — so that the DNS answer cannot be swapped between the check and the connection
  (DNS rebinding);
- redirects are manual, at most 5, and every target is checked again by the same
  rule: a public address can redirect to an internal one;
- a response larger than `max_bytes` is cut off at once, not read to the end.

A refusal is `NewsFetchRefused`, and no network request is sent. What is not a refusal:
network errors of the connection itself (timeout, drop) — they arrive as they are.

The proxy is the variable `NEWS_PROXY`, like `MUSICBRAINZ_PROXY` for the catalog. The address
of the target is checked also when the request will go through a proxy — before sending to it:
the proxying server trusts us, not the other way round. The request then goes with the host
name in the URL (so TLS in the tunnel goes by name, not by IP), so with a proxy the name
is resolved by the proxy, and pinning to an IP does not close off DNS substitution
between the check and the connection.
"""

from __future__ import annotations

import asyncio
import ipaddress
import os
import socket
from dataclasses import dataclass
from typing import Callable

import httpx

MAX_REDIRECTS = 5
DEFAULT_MAX_BYTES = 2 * 1024 * 1024
DEFAULT_TIMEOUT_S = 15.0

_REDIRECTS = frozenset({301, 302, 303, 307, 308})


class NewsFetchRefused(Exception):
    """The address failed the check; no network request was made."""


@dataclass(frozen=True)
class NewsFetchResult:
    """Collector response: status, body and the address after redirects."""

    status: int
    body: bytes
    url: httpx.URL


def _default_resolve(host: str) -> list[str]:
    """Resolve a name to IPs by our own code; replaced in tests."""
    ips: list[str] = []
    for info in socket.getaddrinfo(host, None, type=socket.SOCK_STREAM):
        ip = str(info[4][0])
        if ip not in ips:
            ips.append(ip)
    return ips


def _ip_is_public(ip: ipaddress.IPv4Address | ipaddress.IPv6Address) -> bool:
    """IP outside the forbidden ranges of card FT-572."""
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped is not None:
        # ::ffff:127.0.0.1 is the same loopback, only dressed as IPv6.
        ip = ip.ipv4_mapped
    cgnat = ip.version == 4 and ip in ipaddress.ip_network("100.64.0.0/10")
    return not (
        ip.is_loopback
        or ip.is_private
        or ip.is_link_local
        or ip.is_multicast
        or ip.is_unspecified
        or ip.is_reserved
        or cgnat
    )


async def _checked_ip(url: httpx.URL, resolve: Callable[[str], list[str]]) -> str:
    """The address passes the check; returns the IP the connection will go to."""
    if url.scheme not in ("http", "https"):
        raise NewsFetchRefused("схема не http/https")
    host = url.host
    if not host:
        raise NewsFetchRefused("нет имени хоста")
    try:
        ipaddress.ip_address(host)
    except ValueError:
        # localhost and compose services (`sidecar`, `postgres`) have no dot.
        if "." not in host:
            raise NewsFetchRefused("имя без точки — локальный сервис") from None
        try:
            candidates = await asyncio.to_thread(resolve, host)
        except OSError as exc:
            raise NewsFetchRefused("имя не разрешилось") from exc
    else:
        candidates = [host]
    if not candidates:
        raise NewsFetchRefused("имя не разрешилось")
    for candidate in candidates:
        try:
            ip = ipaddress.ip_address(candidate)
        except ValueError as exc:
            raise NewsFetchRefused("DNS вернул не IP") from exc
        # One internal address among the answers is enough: `mixed` is a refusal.
        if not _ip_is_public(ip):
            raise NewsFetchRefused("внутренний адрес")
    return candidates[0]


def _pinned_request(url: httpx.URL, ip: str) -> httpx.Request:
    """Request to the checked IP: the host name goes in `Host` and SNI."""
    name = url.host
    authority = f"[{name}]" if ":" in name else name
    if url.port is not None:
        authority = f"{authority}:{url.port}"
    return httpx.Request(
        "GET",
        url.copy_with(host=ip),
        headers={"Host": authority},
        extensions={"sni_hostname": name},
    )


async def fetch(
    url: str | httpx.URL,
    *,
    resolve: Callable[[str], list[str]] = _default_resolve,
    transport: httpx.AsyncBaseTransport | None = None,
    proxy: str | None = None,
    max_bytes: int = DEFAULT_MAX_BYTES,
    timeout: float = DEFAULT_TIMEOUT_S,  # noqa: ASYNC109 — httpx timeout, not a coroutine cancellation
) -> NewsFetchResult:
    """Download an address — outward only and within the limit.

    `resolve` is the name-to-IP resolution (replaced in tests), `transport` is the
    httpx transport (in tests `MockTransport`, no network). The proxy defaults to
    `NEWS_PROXY` from the environment; with a passed `transport` it is not needed, the request
    goes to the transport.
    """
    if proxy is None:
        proxy = str(os.environ.get("NEWS_PROXY", "") or "").strip() or None
    # Through a proxy it resolves the name itself, and the request goes with the name in the URL:
    # in a CONNECT tunnel httpx does not pass extensions['sni_hostname'], and a request
    # to an IP would get a TLS handshake by IP with a foreign certificate.
    via_proxy = transport is None and proxy is not None
    current = httpx.URL(url)
    redirects = 0
    client = httpx.AsyncClient(
        transport=transport
        if transport is not None
        else httpx.AsyncHTTPTransport(proxy=proxy or None),
        timeout=timeout,
        follow_redirects=False,
    )
    async with client:
        while True:
            # Every target — including after a redirect — is checked again.
            ip = await _checked_ip(current, resolve)
            request = (
                httpx.Request("GET", current) if via_proxy else _pinned_request(current, ip)
            )
            response = await client.send(request, stream=True)
            try:
                location = (
                    response.headers.get("location")
                    if response.status_code in _REDIRECTS
                    else None
                )
                if location is not None:
                    if redirects >= MAX_REDIRECTS:
                        raise NewsFetchRefused("слишком много переадресаций")
                    redirects += 1
                    current = current.join(location)
                    continue
                body = bytearray()
                async for chunk in response.aiter_bytes():
                    body += chunk
                    if len(body) > max_bytes:
                        raise NewsFetchRefused("ответ больше лимита")
                return NewsFetchResult(
                    status=response.status_code, body=bytes(body), url=current
                )
            finally:
                await response.aclose()
