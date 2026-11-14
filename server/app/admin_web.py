"""The /admin page: three static files and nothing else.

The page signs in through /v1/auth/login and talks to /v1/admin with the
login token in memory, so there is no cookie and nothing for another site
to forge. The files are a fixed list: no path from the request is ever
joined to a directory.
"""

from __future__ import annotations

from pathlib import Path

from fastapi import APIRouter, FastAPI
from fastapi.responses import Response

_DIR = Path(__file__).parent / "data" / "admin"

_FILES = {
    "": ("index.html", "text/html; charset=utf-8"),
    "/": ("index.html", "text/html; charset=utf-8"),
    "/admin.css": ("admin.css", "text/css; charset=utf-8"),
    "/admin.js": ("admin.js", "text/javascript; charset=utf-8"),
}

HEADERS = {
    "Cache-Control": "no-store",
    "Content-Security-Policy": (
        "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; "
        "base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
    ),
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "no-referrer",
}

router = APIRouter(prefix="/admin")


def _serve(name: str, media_type: str) -> Response:
    return Response((_DIR / name).read_bytes(), media_type=media_type, headers=HEADERS)


def _route(path: str, name: str, media_type: str) -> None:
    async def page() -> Response:
        return _serve(name, media_type)

    router.add_api_route(path, page, methods=["GET"], include_in_schema=False)


for _path, (_name, _type) in _FILES.items():
    _route(_path, _name, _type)


def install_admin_web(app: FastAPI) -> None:
    app.include_router(router)
