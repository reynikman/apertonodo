"""Shared fakes for tests: images (FakeWeb) and extension that populates catalog.

Extension from test (`SeededExtension`) replaced the former releases table: tests for catalog, search, and
genres specify a list of "releases" and receive the same `catalog_artists`, `catalog_built` and the same
"is playable" answer — but via extension paths (`GET /v1/catalog`, `POST /v1/has`).
"""

from __future__ import annotations

import json
import re
import threading
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import Any

import httpx
from fastapi import FastAPI

from app import catalog, catalog_from_extensions
from app.catalog import artist_of
from app.genres import GENRE_BY_FORUM
from app.images import Images
from app.names import norm
from app.playable_from_extensions import Playable


class FakeWeb:
    """Internet with recorded responses — for images (Phase K).

    The `routes` key is a path fragment, the value is image bytes, JSON dict, or
    HTTP status code. If no rule matched — 404, just like Cover Art
    Archive responds when front cover is absent. `asked` records the request order:
    it confirms that fallback route is only used after the primary one fails.
    """

    def __init__(self, routes: dict[str, Any]) -> None:
        self.routes = routes
        self.asked: list[str] = []

    def answer(self, request: httpx.Request) -> httpx.Response:
        self.asked.append(str(request.url))
        for mark, answer in self.routes.items():
            if mark in str(request.url):
                if isinstance(answer, int):
                    return httpx.Response(answer)
                if isinstance(answer, bytes):
                    return httpx.Response(200, content=answer)
                return httpx.Response(200, json=answer)
        return httpx.Response(404)

    def client(self) -> httpx.Client:
        return httpx.Client(transport=httpx.MockTransport(self.answer), follow_redirects=True)


PHOTO_URL = "https://upload.wikimedia.org/wikipedia/commons/thumb/band.jpg"
PHOTO_AUTHOR = "Фотограф Имярек"
PHOTO_LICENSE = "CC BY-SA 4.0"


def photo_routes(
    mbid: str, image: bytes, *, author: str = PHOTO_AUTHOR, license_name: str = PHOTO_LICENSE
) -> dict[str, Any]:
    """Three recorded responses for the path 'MusicBrainz -> Wikidata -> Wikimedia Commons'.

    The author comes from Commons as an HTML fragment — this is how it is recorded here.
    """
    return {
        f"/artist/{mbid}": {
            "relations": [
                {"type": "discogs", "url": {"resource": "https://www.discogs.com/artist/1"}},
                {"type": "wikidata", "url": {"resource": "https://www.wikidata.org/wiki/Q9903"}},
            ]
        },
        "www.wikidata.org/w/api.php": {
            "claims": {"P18": [{"mainsnak": {"datavalue": {"value": "Band live.jpg"}}}]}
        },
        "commons.wikimedia.org/w/api.php": {
            "query": {
                "pages": {
                    "-1": {
                        "imageinfo": [
                            {
                                "thumburl": PHOTO_URL,
                                "url": "https://upload.wikimedia.org/commons/band.jpg",
                                "extmetadata": {
                                    "Artist": {"value": f'<a href="/wiki/User:X">{author}</a>'},
                                    "LicenseShortName": {"value": license_name},
                                },
                            }
                        ]
                    }
                }
            }
        },
        "upload.wikimedia.org": image,
    }


# Image shelves of current test: `conftest.images_settle` waits for their
# threads before database is passed to next test (FT-547).
SHELVES: list[Images] = []


def pictures(root: Any, database_url: str, web: FakeWeb, **extra: Any) -> Images:
    """Images (Phase K) using recorded responses and local directory on disk.

    Pause between requests is disabled: in prod it protects external services from us,
    while in test suite it would only slow down the test run.
    """
    shelf = Images(Path(root), database_url, client=web.client, pause_s=0.0, **extra)
    SHELVES.append(shelf)
    return shelf


# Disc image conversions like "image", "ape", etc. are not served: phone cannot play them.
_UNPLAYABLE = re.compile(r"\b(image|ape|wavpack|wv|iso|sacd|dsd|dsf|dff)\b")
EXT_URL = "http://ext.test"

# (topic, forum, release title, tracks, seeders) — same tuples that previously seeded `releases`.
Release = tuple[int, int, str, list[str], int]


class SeededExtension:
    """Extension assembled from a list of "releases".

    Serves what a real extension serves: `/v1/info`, `/v1/catalog` dump (artist, genre,
    popularity) and `/v1/has` responses. A track "exists" if its title is in the release title
    or tracks of an active release by this artist; active — with seeders and not a disc image.
    """

    def __init__(self, releases: list[Release]) -> None:
        self.rows = [
            (forum, title, [norm(t) for t in tracks], seeders)
            for _topic, forum, title, tracks, seeders in releases
            if seeders > 0 and not _UNPLAYABLE.search(norm(title))
        ]

    def catalog_lines(self) -> bytes:
        lines = []
        for forum, title, _tracks, seeders in self.rows:
            genre, artist = GENRE_BY_FORUM.get(forum), artist_of(title)
            if genre and artist:
                lines.append(json.dumps({"artist": artist, "genre": genre, "popularity": seeders}))
        return "\n".join(lines).encode()

    def has(self, artist: str, title: str) -> bool:
        who, what = f" {norm(artist)} ", f" {norm(title)} "
        for _forum, name, tracks, _seeders in self.rows:
            if who not in f" {norm(name)} ":
                continue
            if what in f" {norm(name)} " or any(what in f" {line} " for line in tracks):
                return True
        return False

    def _answer(self, request: httpx.Request) -> httpx.Response:
        if request.url.path == "/v1/info":
            return httpx.Response(200, json={"name": "ext", "version": "1", "features": ["catalog", "has"]})
        if request.url.path == "/v1/catalog":
            return httpx.Response(200, content=self.catalog_lines())
        pairs = json.loads(request.content)["pairs"]
        return httpx.Response(200, json={"hits": [self.has(p["artist"], p["title"]) for p in pairs]})

    def client(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(transport=httpx.MockTransport(self._answer))

    def playable(self) -> Playable:
        return Playable({"ext": EXT_URL}, client=self.client())

    async def build_catalog(self, database_url: str) -> catalog_from_extensions.BuildResult:
        """Build `catalog_artists` the way server does: from extension export."""
        async with self.client() as client:
            return await catalog_from_extensions.build(database_url, {"ext": EXT_URL}, client=client)


async def seed_extension(database_url: str, releases: list[Release]) -> SeededExtension:
    """Catalog from extension + "is playable" from it, until test ends (reset by conftest)."""
    ext = SeededExtension(releases)
    await ext.build_catalog(database_url)
    catalog.use_extensions(ext.playable())
    return ext


class CountingExtension:
    """Extension that finds nothing and counts `find` queries.

    `gate` — while closed, queries for titles in `slow` hang (up to 20 s): used to hold prep.
    """

    def __init__(self, slow: set[str] | None = None) -> None:
        self.gate = threading.Event()
        self.asked: list[str] = []
        self.slow = slow or set()
        self._lock = threading.Lock()

    def app(self) -> FastAPI:
        app = FastAPI()

        @app.get("/v1/info")
        def info() -> dict[str, Any]:
            return {"api": 1, "name": "count", "version": "0", "kind": "music", "features": []}

        @app.post("/v1/find")
        def find(body: dict[str, Any]) -> dict[str, Any]:
            title = str(body["track"]["title"])
            with self._lock:
                self.asked.append(title)
            if title in self.slow:
                self.gate.wait(20)
            return {"items": []}

        return app


@contextmanager
def folder_extension() -> Iterator[dict[str, str]]:
    """Folder extension with tracks from `contracts/fixtures/audio`: `extensions=` for `create_app`."""
    from fake_extension import make_fake_extension, running_extension

    with running_extension(make_fake_extension()) as url:
        yield {"fake": url}
