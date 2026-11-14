"""FT-769: fallback album cover — from extension, not from core.

No cover in archive — core previously fetched `cover.jpg` from the release itself. With extensions, core
has no release: it queries `POST /v1/cover` on extensions with the `cover` feature and takes the first image.
"""

from __future__ import annotations

from typing import Any

from fake_extension import running_extension
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response

from app.extensions import Extensions

JPEG = b"\xff\xd8\xff\xe0" + b"\x00" * 64 + b"\xff\xd9"


def _ext(features: list[str], answer: Response, asked: list[dict[str, Any]]) -> FastAPI:
    app = FastAPI()

    @app.get("/v1/info")
    def info() -> dict[str, Any]:
        return {"api": 1, "name": "x", "version": "0", "kind": "music", "features": features}

    @app.post("/v1/cover")
    async def cover(request: Request) -> Response:
        asked.append(await request.json())
        return answer

    return app


def test_cover_comes_from_extension_with_the_feature() -> None:
    asked: list[dict[str, Any]] = []
    image = Response(JPEG, media_type="image/jpeg")
    with running_extension(_ext(["cover"], image, asked)) as url:
        got = Extensions({"bt": url}).cover("Metallica", "Master of Puppets")
    assert got == JPEG
    assert asked == [{"artist": "Metallica", "title": "Master of Puppets"}]


def test_extension_without_feature_is_not_asked() -> None:
    asked: list[dict[str, Any]] = []
    image = Response(JPEG, media_type="image/jpeg")
    with running_extension(_ext(["catalog"], image, asked)) as url:
        got = Extensions({"folder": url}).cover("Metallica", "Master of Puppets")
    assert got is None
    assert asked == []


def test_not_found_and_not_image_give_nothing_and_next_is_asked() -> None:
    first: list[dict[str, Any]] = []
    second: list[dict[str, Any]] = []
    third: list[dict[str, Any]] = []
    missing = JSONResponse({"error": "not_found"}, status_code=404)
    html = Response(b"<html>", media_type="text/html")
    image = Response(JPEG, media_type="image/jpeg")
    with (
        running_extension(_ext(["cover"], missing, first)) as a,
        running_extension(_ext(["cover"], html, second)) as b,
        running_extension(_ext(["cover"], image, third)) as c,
    ):
        got = Extensions({"a": a, "b": b, "c": c}).cover("A", "B")
    assert got == JPEG
    assert len(first) == len(second) == len(third) == 1


def test_dead_extension_gives_nothing() -> None:
    assert Extensions({"gone": "http://127.0.0.1:9"}).cover("A", "B") is None


def test_catalog_asks_extensions_when_they_are_on() -> None:
    """Wiring: with extensions, `pictures.from_release` goes to the extension, not anywhere else."""
    from app.catalog_api import Catalog

    class _Pictures:
        from_release: Any = None

    asked: list[dict[str, Any]] = []
    image = Response(JPEG, media_type="image/jpeg")
    with running_extension(_ext(["cover"], image, asked)) as url:
        app = FastAPI()
        app.state.extensions = Extensions({"bt": url})
        pictures = _Pictures()
        Catalog(
            app,
            database_url=None,
            remember=lambda _: None,
            pictures=pictures,
        )
        got = pictures.from_release("Metallica", "Master of Puppets")
    assert got == JPEG
    assert asked == [{"artist": "Metallica", "title": "Master of Puppets"}]
