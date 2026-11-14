"""FT-643 (P-A96, P-A97, contract D1, items 10–12; feature B6, step C6b-1): Last.fm scrobble.

Request signing, dispatching a single scrobble to Last.fm, and the two-stage
user authorization flow (requesting one-time token and exchanging it for session key).
"""

from __future__ import annotations

import hashlib
from collections.abc import Mapping
from typing import Any
from urllib.parse import urlencode

import httpx

from app.play_sender import Sender
from app.scrobble import Listen

LASTFM_URL = "https://ws.audioscrobbler.com/2.0/"


def sign(params: Mapping[str, str], secret: str) -> str:
    """Last.fm signature: sort keys alphabetically, concatenate key + value, append secret, MD5."""
    text = "".join(
        k + v
        for k, v in sorted(params.items())
        if k not in ("format", "callback", "api_sig")
    )
    return hashlib.md5((text + secret).encode("utf-8")).hexdigest()  # noqa: S324


def approve_url(api_key: str, token: str) -> str:
    """URL opened by the user in browser to authorize the application."""
    query = urlencode({"api_key": api_key, "token": token})
    return f"https://www.last.fm/api/auth/?{query}"


def _parse_count(val: Any) -> int | None:
    if type(val) is int:
        return val
    if isinstance(val, str) and val.isdigit():
        return int(val)
    return None


def _ignored_code(scrobbles: dict[str, Any]) -> int | None:
    """Reason "ignored" from `scrobble.ignoredMessage.code`; `None` if unparseable."""
    scrobble = scrobbles.get("scrobble")
    message = scrobble.get("ignoredMessage") if isinstance(scrobble, dict) else None
    return _parse_count(message.get("code")) if isinstance(message, dict) else None


def lastfm(
    client: httpx.AsyncClient,
    *,
    api_key: str,
    api_secret: str,
) -> Sender:
    """Send a single scrobble to Last.fm (track.scrobble method)."""

    async def send(token: str, listen: Listen) -> str:
        try:
            params: dict[str, str] = {
                "method": "track.scrobble",
                "api_key": api_key,
                "sk": token,
                "artist": listen.artist,
                "track": listen.title,
                "timestamp": str(int(listen.played_at.timestamp())),
            }
            if listen.duration_ms >= 1000:
                params["duration"] = str(listen.duration_ms // 1000)

            data = {
                **params,
                "api_sig": sign(params, api_secret),
                "format": "json",
            }
            response = await client.post(LASTFM_URL, data=data)
            try:
                payload = response.json()
            except Exception:
                return "retry"

            if not isinstance(payload, dict):
                return "retry"

            if "error" in payload:
                err = payload["error"]
                if type(err) is int:
                    if err == 9:
                        return "bad_token"
                    if err == 6:
                        return "refused"
                return "retry"

            if response.status_code != 200:
                return "retry"

            scrobbles = payload.get("scrobbles")
            if not isinstance(scrobbles, dict):
                return "retry"
            attr = scrobbles.get("@attr")
            if not isinstance(attr, dict):
                return "retry"

            accepted = _parse_count(attr.get("accepted"))
            ignored = _parse_count(attr.get("ignored"))
            if accepted is None or ignored is None:
                return "retry"
            if accepted >= 1:
                return "sent"
            if ignored >= 1:
                # Reason 5 is user daily limit, 4 is timestamp in the future (clock
                # skew): will be accepted on retry later. Other reasons cannot be retried.
                return "retry" if _ignored_code(scrobbles) in (4, 5) else "refused"
            return "retry"
        except Exception:
            return "retry"

    return send


async def request_token(
    client: httpx.AsyncClient,
    *,
    api_key: str,
    api_secret: str,
) -> str | None:
    """First stage: request one-time token (auth.getToken)."""
    try:
        params: dict[str, str] = {
            "method": "auth.getToken",
            "api_key": api_key,
        }
        data = {
            **params,
            "api_sig": sign(params, api_secret),
            "format": "json",
        }
        response = await client.post(LASTFM_URL, data=data)
        if response.status_code != 200:
            return None
        try:
            payload = response.json()
        except Exception:
            return None
        if not isinstance(payload, dict):
            return None
        if "error" in payload:
            return None
        token = payload.get("token")
        if isinstance(token, str) and token:
            return token
        return None
    except Exception:
        return None


async def get_session(
    client: httpx.AsyncClient,
    *,
    api_key: str,
    api_secret: str,
    token: str,
) -> tuple[str, str | None]:
    """Second stage: exchange authorized token for session key (auth.getSession)."""
    try:
        params: dict[str, str] = {
            "method": "auth.getSession",
            "api_key": api_key,
            "token": token,
        }
        data = {
            **params,
            "api_sig": sign(params, api_secret),
            "format": "json",
        }
        response = await client.post(LASTFM_URL, data=data)
        try:
            payload = response.json()
        except Exception:
            return ("failed", None)
        if not isinstance(payload, dict):
            return ("failed", None)

        if "error" in payload:
            err = payload["error"]
            if type(err) is int:
                if err == 14:
                    return ("pending", None)
                if err in (15, 4):
                    return ("expired", None)
            return ("failed", None)

        if response.status_code != 200:
            return ("failed", None)

        session = payload.get("session")
        if not isinstance(session, dict):
            return ("failed", None)

        key = session.get("key")
        if isinstance(key, str) and key:
            return ("ok", key)
        return ("failed", None)
    except Exception:
        return ("failed", None)
