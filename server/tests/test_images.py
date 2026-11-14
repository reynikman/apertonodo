"""Images: album covers and artist photos (Phase K, G54) on real PostgreSQL.

What is guarded here and why:

1. **Source order.** Cover Art Archive by album MBID first; if missing,
   release payload file. Owner decision 2026-09-20.
2. **Images are files on disk.** Database holds only the path and a "tried,
   not found" mark. 100k covers in `bytea` would mean 5 GB per database copy.
3. **"One at a time" fixed.** Opening an artist page orders covers for the entire
   grid at once, and no order is dropped. Before Phase K only a single
   background task was scheduled, resulting in only 4 rows total in prod, 2 with images.
4. **Artist photos require credits** (author and license). Without author or
   license, the photo is not taken at all: displaying Wikimedia Commons images without
   attribution violates their license (legal requirement, not cosmetics).
5. **Nightly crawler** pre-fetches popular items: order and limit match Last.fm
   crawler, rate-limited to MusicBrainz at <= 1 req/s.
6. Logs contain no artist names, track titles, or URLs.

Responses from Cover Art Archive, Wikidata, and Wikimedia Commons are recorded fixtures
in real format. Release list and MusicBrainz responses match catalog pages
(`tests/test_catalog_browse.py`) and are reused from there.
"""

from __future__ import annotations

import asyncio
import logging
import time
from pathlib import Path
from typing import Any

import asyncpg
import pytest
from fakes import (
    PHOTO_AUTHOR,
    PHOTO_LICENSE,
    PHOTO_URL,
    FakeWeb,
    photo_routes,
    pictures,
)
from fastapi.testclient import TestClient
from fake_extension import running_extension
from test_catalog_browse import (
    _cover_extension,
    _extension,
    ARTIST,
    JPEG,
    LOW_TIDE,
    PAPER,
    FakeMusicBrainz,
    _app,
    _seed,
)

from app import images
from app.images import Images

PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 500
ARCHIVE = f"https://coverartarchive.org/release-group/{LOW_TIDE}/front-500"


@pytest.fixture
def built(postgres_url: str) -> str:
    """Same release list and built catalog as the catalog pages.

    Local fixture rather than shared with `test_catalog_browse`: pytest would accept
    a shared one, but ruff treats the re-exported symbol as a redefinition,
    causing linter failures across the suite.
    """
    asyncio.run(_seed(postgres_url))
    asyncio.run(_extension().build_catalog(postgres_url))
    return postgres_url



async def _rows(url: str, sql: str, *args: Any) -> list[Any]:
    conn = await asyncpg.connect(url)
    try:
        return await conn.fetch(sql, *args)
    finally:
        await conn.close()


def _alone(url: str, artist_key: str) -> None:
    """Leave only one artist in the catalog to keep the crawler queue predictable."""
    asyncio.run(_rows(url, "DELETE FROM catalog_artists WHERE artist_key <> $1", artist_key))


# --- 1–2. source and storage ----------------------------------------------


def test_cover_is_a_file_on_disk_and_only_a_path_in_the_database(
    built: str, tmp_path: Path
) -> None:
    shelf = pictures(tmp_path, built, FakeWeb({"coverartarchive.org": JPEG}))
    shelf.want(("cover", LOW_TIDE, "Glass Harbor", "Low Tide"))
    shelf.queue.join()

    rows = asyncio.run(_rows(built, "SELECT * FROM album_images WHERE album_id = $1::uuid", LOW_TIDE))
    # No image bytes in DB: path, timestamps, and size (FT-544 disk quota).
    assert set(rows[0].keys()) <= {"album_id", "path", "tried_at", "opened_at", "size_bytes"}
    assert not any(isinstance(value, bytes) for value in rows[0].values())
    path = rows[0]["path"]
    # Path is relative: moving disk mounts won't break database references.
    assert path == f"covers/{LOW_TIDE[:2]}/{LOW_TIDE}.jpg"
    assert (tmp_path / path).read_bytes() == JPEG
    # No partial files remain: written to temp file, then renamed atomically.
    assert [item.name for item in (tmp_path / "covers" / LOW_TIDE[:2]).iterdir()] == [
        f"{LOW_TIDE}.jpg"
    ]


def test_png_stays_png(built: str, tmp_path: Path) -> None:
    shelf = pictures(tmp_path, built, FakeWeb({"coverartarchive.org": PNG}))
    shelf.want(("cover", LOW_TIDE, "Glass Harbor", "Low Tide"))
    shelf.queue.join()
    with TestClient(_app(built, FakeMusicBrainz(), None, shelf)) as client:
        answer = client.get(f"/v1/covers/{LOW_TIDE}")
    assert answer.headers["content-type"] == "image/png"
    assert answer.content == PNG


def test_not_an_image_is_not_kept(built: str, tmp_path: Path) -> None:
    """Archive responded with non-image content: treated as "not found", not a cover.

    Inspect magic bytes, not headers: error pages with
    `content-type: image/jpeg` are common across proxies.
    """
    shelf = pictures(tmp_path, built, FakeWeb({"coverartarchive.org": b"<html>error</html>"}))
    shelf.want(("cover", LOW_TIDE, "Glass Harbor", "Low Tide"))
    shelf.queue.join()
    rows = asyncio.run(_rows(built, "SELECT path FROM album_images"))
    assert rows[0]["path"] is None
    assert not (tmp_path / "covers").exists()


def test_searched_and_not_found_is_remembered(built: str, tmp_path: Path) -> None:
    """`path IS NULL` with non-null `tried_at` records "searched, not found"."""
    web = FakeWeb({"coverartarchive.org": 404})
    shelf = pictures(tmp_path, built, web)
    shelf.want(("cover", LOW_TIDE, "Glass Harbor", "Low Tide"))
    shelf.queue.join()

    async def check() -> set[str]:
        conn = await asyncpg.connect(built)
        try:
            return await images.tried(conn, [LOW_TIDE, PAPER])
        finally:
            await conn.close()

    assert asyncio.run(check()) == {LOW_TIDE}


def test_a_busy_archive_is_not_remembered_as_not_found(built: str, tmp_path: Path) -> None:
    """503 is an archive error, not a missing cover: do not record the attempt.

    Otherwise a transient failure silences the album for `RETRY` (3 months).
    In prod on 2026-09-20 that occurred: out of 6 "coverless" albums, 5 had covers
    in archive that served fine on the very next attempt.
    """
    shelf = pictures(tmp_path, built, FakeWeb({"coverartarchive.org": 503}))
    shelf.want(("cover", LOW_TIDE, "Glass Harbor", "Low Tide"))
    shelf.queue.join()

    # Row does not exist at all: `tried` won't skip this album, and page
    # will request cover again.
    assert asyncio.run(_rows(built, "SELECT album_id FROM album_images")) == []

    async def skipped() -> set[str]:
        conn = await asyncpg.connect(built)
        try:
            return await images.tried(conn, [LOW_TIDE])
        finally:
            await conn.close()

    assert asyncio.run(skipped()) == set()


def test_release_is_asked_only_after_the_archive(built: str, tmp_path: Path) -> None:
    asked: list[dict[str, Any]] = []
    web = FakeWeb({"coverartarchive.org": 404})
    shelf = pictures(tmp_path, built, web)
    with running_extension(_cover_extension(asked)) as url:
        with TestClient(_app(built, FakeMusicBrainz(), {"bt": url}, shelf)):
            shelf.want(("cover", LOW_TIDE, "Glass Harbor", "Low Tide"))
            shelf.queue.join()
    assert web.asked == [ARCHIVE]
    assert asked  # fallback path was triggered
    assert asyncio.run(_rows(built, "SELECT path FROM album_images"))[0]["path"] is not None


# --- 3. "one at a time" ---------------------------------------------------


def test_the_whole_grid_is_ordered_at_once(built: str, tmp_path: Path) -> None:
    """Artist page requests covers for all grid albums at once.

    Fixes the pre-Phase K behavior: previously only one cover was fetched per
    page visit, slowly filling the grid one image at a time. With P-A37
    (FT-460), unplayable albums are included too: archive needs MBID, not a seed.
    """
    web = FakeWeb({"coverartarchive.org": JPEG})
    shelf = pictures(tmp_path, built, web)
    with TestClient(_app(built, FakeMusicBrainz(), None, shelf)) as client:
        first = client.get("/v1/artist", params={"name": "Glass Harbor"}).json()
        shelf.queue.join()
        again = client.get("/v1/artist", params={"name": "Glass Harbor"}).json()
    # Opened page does not block: covers are not yet loaded.
    assert [album["cover"] for album in first["albums"]] == [None] * 4
    # Next view displays full grid at once, each album with its own cover.
    assert [album["cover"] for album in again["albums"]] == [
        f"/v1/covers/{album['id']}" for album in again["albums"]
    ]
    assert [album["id"] for album in again["albums"]][:2] == [LOW_TIDE, PAPER]
    assert len([url for url in web.asked if "coverartarchive" in url]) == 4


def test_nothing_is_dropped_while_the_queue_is_busy(built: str, tmp_path: Path) -> None:
    """Twenty orders in a row yields twenty images, not one.

    Old `cover_soon` dropped everything except the first request.
    """
    web = FakeWeb({"coverartarchive.org": JPEG})
    shelf = pictures(tmp_path, built, web)
    ids = [f"0e0f1a9c-5f2c-4b4f-9d44-3a1d2f7a1{number:03d}" for number in range(20)]
    for album_id in ids:
        shelf.want(("cover", album_id, "Glass Harbor", "Low Tide"))
    shelf.queue.join()
    kept = asyncio.run(_rows(built, "SELECT album_id FROM album_images WHERE path IS NOT NULL"))
    assert {str(row["album_id"]) for row in kept} == set(ids)


def test_the_same_album_is_not_ordered_twice(built: str, tmp_path: Path) -> None:
    web = FakeWeb({"coverartarchive.org": JPEG})
    shelf = pictures(tmp_path, built, web)
    for _ in range(5):
        shelf.want(("cover", LOW_TIDE, "Glass Harbor", "Low Tide"))
    shelf.queue.join()
    assert web.asked == [ARCHIVE]


# --- 4. artist photo and attribution --------------------------------------


def test_photo_comes_with_the_author_and_the_licence(built: str, tmp_path: Path) -> None:
    web = FakeWeb(photo_routes(ARTIST, JPEG))
    shelf = pictures(tmp_path, built, web)
    with TestClient(_app(built, FakeMusicBrainz(), None, shelf)) as client:
        client.get("/v1/artist", params={"name": "Glass Harbor"})
        shelf.queue.join()
        page = client.get("/v1/artist", params={"name": "Glass Harbor"}).json()
        image = client.get(page["artist"]["photo"])
    assert page["artist"]["photo"] == f"/v1/photos/{ARTIST}"
    assert page["artist"]["photo_credit"] == f"{PHOTO_AUTHOR}, {PHOTO_LICENSE}"
    assert image.status_code == 200
    assert image.content == JPEG
    # Three metadata path requests and fourth for image itself — measured 2026-09-20.
    assert [url for url in web.asked if "coverartarchive" not in url] == [
        f"https://musicbrainz.org/ws/2/artist/{ARTIST}?inc=url-rels&fmt=json",
        "https://www.wikidata.org/w/api.php?action=wbgetclaims&entity=Q9903&property=P18&format=json",
        *[url for url in web.asked if "commons.wikimedia.org" in url],
        PHOTO_URL,
    ]


@pytest.mark.parametrize("missing", ["Artist", "LicenseShortName"])
def test_photo_without_a_credit_is_not_taken_at_all(
    built: str, tmp_path: Path, missing: str
) -> None:
    """Without author or license, photo is neither saved nor displayed.

    Not decorative: Wikimedia Commons images require author attribution.
    Displaying without it violates license terms, visible immediately upon
    publishing to GitHub.
    """
    routes = photo_routes(ARTIST, JPEG)
    extra = routes["commons.wikimedia.org/w/api.php"]["query"]["pages"]["-1"]["imageinfo"][0]
    extra["extmetadata"].pop(missing)
    web = FakeWeb(routes)
    shelf = pictures(tmp_path, built, web)
    with TestClient(_app(built, FakeMusicBrainz(), None, shelf)) as client:
        client.get("/v1/artist", params={"name": "Glass Harbor"})
        shelf.queue.join()
        page = client.get("/v1/artist", params={"name": "Glass Harbor"}).json()
        image = client.get(f"/v1/photos/{ARTIST}")
    assert page["artist"]["photo"] is None
    assert page["artist"]["photo_credit"] is None
    assert image.status_code == 404
    assert not (tmp_path / "photos").exists()


def test_a_photo_already_kept_without_a_credit_is_not_shown(
    built: str, tmp_path: Path
) -> None:
    """Restriction enforced at query time as well, not only upon ingestion.

    An uncredited row should never enter DB, but if it ends up there —
    after manual edit, restore, or migration — it must never leak to API responses.
    Violating attribution violates Wikimedia Commons license terms.
    """
    (tmp_path / "photos" / ARTIST[:2]).mkdir(parents=True)
    (tmp_path / "photos" / ARTIST[:2] / f"{ARTIST}.jpg").write_bytes(JPEG)
    asyncio.run(
        _rows(
            built,
            "INSERT INTO artist_photos (artist_key, mbid, path, author, license) "
            "VALUES ('glass harbor', $1::uuid, $2, '', '')",
            ARTIST,
            f"photos/{ARTIST[:2]}/{ARTIST}.jpg",
        )
    )
    shelf = pictures(tmp_path, built, FakeWeb({}))
    with TestClient(_app(built, FakeMusicBrainz(), None, shelf)) as client:
        page = client.get("/v1/artist", params={"name": "Glass Harbor"}).json()
        image = client.get(f"/v1/photos/{ARTIST}")
    assert page["artist"]["photo"] is None
    assert page["artist"]["photo_credit"] is None
    assert image.status_code == 404


def test_artist_without_wikidata_is_remembered_as_tried(built: str, tmp_path: Path) -> None:
    web = FakeWeb({f"/artist/{ARTIST}": {"relations": []}})
    shelf = pictures(tmp_path, built, web)
    with TestClient(_app(built, FakeMusicBrainz(), None, shelf)) as client:
        client.get("/v1/artist", params={"name": "Glass Harbor"})
        shelf.queue.join()
        client.get("/v1/artist", params={"name": "Glass Harbor"})
        shelf.queue.join()
    # Queried once, not on every page load.
    assert len([url for url in web.asked if "musicbrainz.org" in url]) == 1
    rows = asyncio.run(_rows(built, "SELECT path, author, license FROM artist_photos"))
    assert (rows[0]["path"], rows[0]["author"], rows[0]["license"]) == (None, None, None)


def test_a_busy_commons_is_not_remembered_as_no_photo(built: str, tmp_path: Path) -> None:
    """503 fetching the image file is a Commons outage, not a missing artist photo.

    The error body isn't recognized as an image, so without checking status it would
    be logged as "searched, not found" and remove artist from queue for `RETRY` (3 months).
    Same pitfall as covers, handled at binary download instead of JSON queries.
    """
    web = FakeWeb({**photo_routes(ARTIST, JPEG), "upload.wikimedia.org": 503})
    shelf = pictures(tmp_path, built, web)
    shelf.want(("photo", "glass harbor", ARTIST, ""))
    shelf.queue.join()

    # Row does not exist: photo will be requested again on next page view.
    assert asyncio.run(_rows(built, "SELECT artist_key FROM artist_photos")) == []
    assert not (tmp_path / "photos").exists()


def test_author_html_from_commons_becomes_plain_text() -> None:
    assert images.plain('<a href="/wiki/User:X" title="t">Иван&nbsp;Петров</a>\n') == "Иван Петров"


# --- 5. nightly crawler ---------------------------------------------------


def test_robot_walks_popular_artists_and_takes_photo_and_covers(
    built: str, tmp_path: Path
) -> None:
    """Design and limits match Last.fm crawler; continues itself automatically."""
    _alone(built, "glass harbor")
    web = FakeWeb(
        {
            "/ws/2/artist?": {"artists": [{"id": ARTIST, "name": "Glass Harbor"}]},
            "/ws/2/release-group?": {
                "release-group-count": 2,
                "release-groups": [
                    {"id": LOW_TIDE, "title": "Low Tide", "primary-type": "Album", "secondary-types": []},
                    {"id": PAPER, "title": "Paper Crown", "primary-type": "EP", "secondary-types": []},
                ],
            },
            "coverartarchive.org": JPEG,
            **photo_routes(ARTIST, JPEG),
        }
    )
    shelf = pictures(tmp_path, built, web, limit=1)
    done, covers = shelf.crawl()
    shelf.queue.join()
    assert (done, covers) == (1, 2)
    kept = asyncio.run(_rows(built, "SELECT album_id FROM album_images WHERE path IS NOT NULL"))
    assert {str(row["album_id"]) for row in kept} == {LOW_TIDE, PAPER}
    assert asyncio.run(_rows(built, "SELECT path FROM artist_photos"))[0]["path"] is not None
    # Second crawl does not repeat work: queue is derived from DB.
    assert shelf.crawl() == (0, 0)


def test_robot_warms_the_page_cache_and_the_page_asks_nobody(
    built: str, tmp_path: Path
) -> None:
    """Crawler writes MusicBrainz responses into the same cache read by artist page."""
    _alone(built, "glass harbor")
    web = FakeWeb(
        {
            "/ws/2/artist?": {"artists": [{"id": ARTIST, "name": "Glass Harbor"}]},
            "/ws/2/release-group?": {"release-group-count": 0, "release-groups": []},
            "coverartarchive.org": JPEG,
            **photo_routes(ARTIST, JPEG),
        }
    )
    shelf = pictures(tmp_path, built, web, limit=1)
    shelf.crawl()
    shelf.queue.join()
    down = FakeMusicBrainz(fail=100)
    with TestClient(_app(built, down, None, shelf)) as client:
        page = client.get("/v1/artist", params={"name": "Glass Harbor"})
    assert page.status_code == 200
    assert down.calls == []


def test_robot_does_not_go_for_a_dead_album(built: str, tmp_path: Path) -> None:
    """Album not in any active release: nowhere to fetch cover from."""
    dead = "0e0f1a9c-5f2c-4b4f-9d44-3a1d2f7a0003"  # Winter Keys
    _alone(built, "glass harbor")
    # Online path without local MB copy. With local copy: tests/test_images_local.py (FT-542).
    asyncio.run(_rows(built, "DELETE FROM mb_loads"))
    web = FakeWeb(
        {
            "/ws/2/artist?": {"artists": [{"id": ARTIST, "name": "Glass Harbor"}]},
            "/ws/2/release-group?": {
                "release-group-count": 1,
                "release-groups": [
                    {"id": dead, "title": "Winter Keys", "primary-type": "Album", "secondary-types": []}
                ],
            },
            **photo_routes(ARTIST, JPEG),
        }
    )
    shelf = pictures(tmp_path, built, web, limit=1)
    assert shelf.crawl() == (1, 0)
    shelf.queue.join()
    assert not any("coverartarchive" in url for url in web.asked)


def test_robot_takes_the_most_popular_first(built: str, tmp_path: Path) -> None:
    """Without listening history, queue is ordered by catalog popularity."""
    shelf = pictures(tmp_path, built, FakeWeb({}))
    assert [name for _key, name in asyncio.run(shelf._todo())] == [
        "Velvet Orchard",  # 50 + 2 seeders
        "Glass Harbor",  # 30 + 5 + 7
        "Ржавый Ключ",  # 10
        "Édith Glow",  # 3
    ]


def test_robot_takes_listened_artists_before_popular(built: str, tmp_path: Path) -> None:
    """Listened and favorited artists first, then catalog popularity."""
    asyncio.run(
        _rows(
            built,
            "INSERT INTO listens (canonical_key, track_id, title, artist, duration_ms) "
            "VALUES ('edith', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid, 'Soft', 'Édith Glow', 180000)",
        )
    )
    asyncio.run(
        _rows(
            built,
            "INSERT INTO favorites (canonical_key, track_id, title, artist, duration_ms) "
            "VALUES ('rzhavy', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'::uuid, 'x', 'Ржавый Ключ', 180000)",
        )
    )
    shelf = pictures(tmp_path, built, FakeWeb({}), limit=3)
    assert [name for _key, name in asyncio.run(shelf._todo())] == [
        "Ржавый Ключ",
        "Édith Glow",
        "Velvet Orchard",
    ]


def test_robot_stops_on_a_refusal_and_continues_next_time(built: str, tmp_path: Path) -> None:
    # Online MusicBrainz error is relevant only without local copy (FT-542).
    asyncio.run(_rows(built, "DELETE FROM mb_loads"))
    web = FakeWeb({"/ws/2/artist?": 503})
    shelf = pictures(tmp_path, built, web, limit=5)
    assert shelf.crawl() == (0, 0)
    # Nothing recorded as "attempted": next pass resumes from the same spot.
    assert asyncio.run(_rows(built, "SELECT artist_key FROM artist_photos")) == []


def test_one_request_a_second_to_the_outside(tmp_path: Path) -> None:
    """Shared rate-limit between crawler and page queue: they don't accelerate together.

    MusicBrainz tracks requests by egress IP, and all our outbound calls go through
    a shared proxy — so we must throttle requests internally.
    """
    web = FakeWeb({"example": {"ok": True}})
    shelf = Images(tmp_path, "postgresql://unused", client=web.client)
    assert shelf.pause_s >= 1.0
    started = time.monotonic()
    with shelf.client() as client:
        shelf.get(client, "https://example.org/a")
        shelf.get(client, "https://example.org/b")
    assert time.monotonic() - started >= shelf.pause_s


# --- 6. log ---------------------------------------------------------------


def test_image_log_has_no_names_titles_or_addresses(
    built: str, tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    caplog.set_level(logging.INFO, logger="apertonodo")
    web = FakeWeb({"coverartarchive.org": JPEG, **photo_routes(ARTIST, JPEG)})
    shelf = pictures(tmp_path, built, web)
    with TestClient(_app(built, FakeMusicBrainz(), None, shelf)) as client:
        client.get("/v1/artist", params={"name": "Glass Harbor"})
        shelf.queue.join()
    text = caplog.text.casefold()
    # Positive control: image log lines are present.
    assert "cover: stored" in text and "from archive" in text
    assert "photo: stored with credit" in text
    for secret in ("glass", "harbor", "low tide", "paper crown", "wikimedia", "upload.", ARTIST):
        assert secret not in text, secret
