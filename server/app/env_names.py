"""Product names the server accepts: new `apertonodo` first, old `flowtune` as fallback.

The old names are still sent by the production server, CI, owner scripts and
installed apps, so they stay accepted until the owner drops them (FT-888).
"""

import os
from collections.abc import Mapping

# New header name first; the old one is accepted until all clients are moved.
KEY_HEADERS = ("x-apertonodo-key", "x-flowtune-key")  # old name, accepted until clients are moved


def env(name: str, default: str = "", source: Mapping[str, str] | None = None) -> str:
    """Read APERTONODO_<name>, else the old FLOWTUNE_<name> (accepted until the deploy is moved)."""
    src = os.environ if source is None else source
    for prefix in ("APERTONODO_", "FLOWTUNE_"):  # FLOWTUNE_: old name, accepted until deploy moved
        value = src.get(prefix + name)
        if value is not None:
            return value
    return default


def sent_key(headers: Mapping[str, str]) -> str:
    """Key from a starlette-style (case-insensitive) headers mapping, new header first."""
    for header in KEY_HEADERS:
        value = headers.get(header)
        if value:
            return value
    return ""
