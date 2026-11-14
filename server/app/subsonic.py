"""OpenSubsonic: protocol layer allowing third-party players to handshake with Apertonodo.

Only Subsonic protocol logic lives here: `/rest/{method}` and `/rest/{method}.view` paths, parameter parsing,
authentication, unified response envelope (JSON or XML), error codes. No music domain logic here:
future cards add methods to the `METHODS` table (`@method("search3")`) without touching auth or envelope.

The module does not access the database directly: username, password, and API key verification
is provided externally via `SubsonicAuth`. Passwords use one-way hashing, so "token + salt" login
(md5 of password) cannot be verified — we return code 41.

Privacy: credentials contain passwords and keys, so the log omits request paths, parameters,
exception messages, and tracebacks — only static message strings and exception class names.
Responses do not echo user input: errors use fixed text messages.
"""

from __future__ import annotations

import logging
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Any, Protocol
from urllib.parse import parse_qsl
from xml.etree import ElementTree

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response

log = logging.getLogger("apertonodo")

API_VERSION = "1.16.1"
SERVER_TYPE = "Apertonodo"
XML_NAMESPACE = "http://subsonic.org/restapi"

# English text: displayed to user by third-party players; user locale is unknown to server.
ERRORS = {
    0: "Server error or method not supported.",
    10: "Required login parameter is missing.",
    40: "Wrong username or password.",
    41: "Token and salt login is not supported: use a password or an API key.",
    43: "Multiple conflicting authentication mechanisms provided.",
    44: "Invalid API key.",
}


@dataclass(frozen=True)
class SubsonicUser:
    id: str
    username: str


class SubsonicAuth(Protocol):
    async def by_password(
        self, username: str, password: str
    ) -> SubsonicUser | None: ...

    async def by_api_key(self, api_key: str) -> SubsonicUser | None: ...


Handler = Callable[[SubsonicUser | None, dict[str, str]], Awaitable[dict[str, Any]]]

# Method name -> handler (user, params) -> response data. New methods register here.
METHODS: dict[str, Handler] = {}
# Public methods that do not require authentication (queried before login).
PUBLIC: set[str] = set()


def method(name: str, *, public: bool = False) -> Callable[[Handler], Handler]:
    def register(fn: Handler) -> Handler:
        METHODS[name] = fn
        if public:
            PUBLIC.add(name)
        return fn

    return register


@method("ping")
async def _ping(user: SubsonicUser | None, params: dict[str, str]) -> dict[str, Any]:
    return {}


@method("getLicense")
async def _license(user: SubsonicUser | None, params: dict[str, str]) -> dict[str, Any]:
    return {"license": {"valid": True}}


@method("tokenInfo")
async def _token_info(
    user: SubsonicUser | None, params: dict[str, str]
) -> dict[str, Any]:
    assert user is not None
    return {"tokenInfo": {"username": user.username}}


@method("getOpenSubsonicExtensions", public=True)
async def _extensions(
    user: SubsonicUser | None, params: dict[str, str]
) -> dict[str, Any]:
    return {
        "openSubsonicExtensions": [
            {"name": "apiKeyAuthentication", "versions": [1]},
            {"name": "formPost", "versions": [1]},
        ]
    }


class _Failed(Exception):
    def __init__(self, code: int) -> None:
        self.code = code


async def _params(request: Request) -> dict[str, str]:
    """Parameters from query string; for POST, form-urlencoded body supplements query string (formPost extension)."""
    params = dict(parse_qsl(request.url.query, keep_blank_values=True))
    if request.method == "POST":
        if request.headers.get("content-type", "").startswith(
            "application/x-www-form-urlencoded"
        ):
            text = (await request.body()).decode("utf-8", errors="replace")
            for key, value in parse_qsl(text, keep_blank_values=True):
                params.setdefault(key, value)
    return params


async def _login(auth: SubsonicAuth, params: dict[str, str]) -> SubsonicUser:
    try:
        if "apiKey" in params:
            if any(k in params for k in ("u", "p", "t")):
                raise _Failed(43)
            if not params["apiKey"]:
                raise _Failed(10)
            user = await auth.by_api_key(params["apiKey"])
            if user is None:
                raise _Failed(44)
            return user
        if "u" in params and ("t" in params or "s" in params) and "p" not in params:
            raise _Failed(41)
        if not params.get("u") or not params.get("p"):
            raise _Failed(10)
        password = params["p"]
        if password.startswith("enc:"):
            try:
                password = bytes.fromhex(password[4:]).decode("utf-8")
            except ValueError:
                raise _Failed(40) from None
        user = await auth.by_password(params["u"], password)
        if user is None:
            raise _Failed(40)
        return user
    except _Failed:
        raise
    except Exception as exc:
        # Exception text might contain key or password — log only class name.
        log.warning("subsonic: auth check failed (%s)", type(exc).__name__)
        raise _Failed(0) from None


def _xml_value(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def _fill(element: ElementTree.Element, data: dict[str, Any]) -> None:
    """Scalars become attributes; dicts and lists become nested elements with the same key tag."""
    for key, value in data.items():
        items = value if isinstance(value, list) else [value]
        for item in items:
            if isinstance(item, dict):
                _fill(ElementTree.SubElement(element, key), item)
            elif isinstance(value, list):
                ElementTree.SubElement(element, key).text = _xml_value(item)
            else:
                element.set(key, _xml_value(item))


def _envelope(
    data: dict[str, Any], failed: int | None, server_version: str, fmt: str
) -> Response:
    body: dict[str, Any] = {
        "status": "failed" if failed is not None else "ok",
        "version": API_VERSION,
        "type": SERVER_TYPE,
        "serverVersion": server_version,
        "openSubsonic": True,
    }
    body.update(
        {"error": {"code": failed, "message": ERRORS[failed]}}
        if failed is not None
        else data
    )
    if fmt == "json":
        return JSONResponse({"subsonic-response": body})
    root = ElementTree.Element("subsonic-response", {"xmlns": XML_NAMESPACE})
    _fill(root, body)
    return Response(
        ElementTree.tostring(root, encoding="utf-8", xml_declaration=True),
        media_type="application/xml",
    )


def install_subsonic(app: FastAPI, *, auth: SubsonicAuth, server_version: str) -> None:
    """Mount `/rest/{method}` and `/rest/{method}.view` (GET and POST). In main.py — single line."""

    async def rest(request: Request) -> Response:
        params = await _params(request)
        fmt = "json" if params.get("f") == "json" else "xml"
        name = request.path_params["name"].removesuffix(".view")
        try:
            handler = METHODS.get(name)
            user = None if name in PUBLIC else await _login(auth, params)
            if handler is None:
                raise _Failed(0)
            try:
                data = await handler(user, params)
            except _Failed:
                # Method's specific error code ("not found", etc.) preserved as-is rather than generic 0.
                raise
            except Exception as exc:
                log.warning("subsonic: method failed (%s)", type(exc).__name__)
                raise _Failed(0) from None
        except _Failed as failed:
            return _envelope({}, failed.code, server_version, fmt)
        return _envelope(data, None, server_version, fmt)

    app.add_api_route(
        "/rest/{name}", rest, methods=["GET", "POST"], include_in_schema=False
    )
