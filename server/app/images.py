"""Images: album covers and artist photos (Phase K, G54).

Owner decisions of 20.09.2026 maintained here:

- **Order of cover sources.** Cover Art Archive by album MBID first;
  if not found — `cover.jpg`/`folder.jpg` file from the release itself, as it was prior to
  Phase K. Production benchmark: 8 out of 10 covers arrive from archive in
  2–5s; inside releases themselves, image exists in 92 out of 123.
- **Outbound only via `MUSICBRAINZ_PROXY`**, using the same gateway as
  MusicBrainz: direct TLS from production server is blocked by SNI.
- **Images stored as files on disk** (`IMAGE_DIR`, in production — HDD
  `/mnt/flowtune/images`), database holds only path and "searched, not found" marker.
  One hundred thousand covers in `bytea` is five gigabytes in each database copy.
- **Artist photo displayed only with credit** to author and license.
  No author or license name — photo is not saved at all: displaying without
  credit violates Wikimedia Commons license and is a risk before publishing to GitHub.
- **Covers cache with storage quota** (P-A65, FT-544): 20 GB default; when
  exceeded — least recently opened are evicted, row and file completely. Artist
  photos are not subject to quota: there are hundreds of photos and hundreds of thousands of covers.
- **No placeholders.** Not found — database retains marker, UI draws
  square with initials. Neither "notes" nor foreign logos.

Why a queue rather than a single background task. Prior to Phase K, `cover_soon` scheduled
exactly one task and dropped all subsequent requests until finished: grid of
twenty albums populated one cover per page view, and in production accumulated
only four rows total over time, two with images. Now page enqueues all displayed
albums, and none are lost.

Crawler design matches Last.fm (`app/lastfm.py`): daemon thread, awakened by
catalog browsing, queue ordered by history and favorites first, then by
catalog popularity; interrupted crawl resumes from the same place,
completed items already in database.

Limit is the same 20,000 artists as Last.fm, capped at one request per second.
Fair math: artist requires MBID lookup, one or more for discography, three for photo,
and one for each album cover — tens of seconds per artist. Initial population
takes a week rather than a night; listened artists are prioritized before popular ones.
Accelerating by crawling faster is prohibited: MusicBrainz counts requests by source IP,
and we egress through a shared proxy.

Pacing lock shared across entire module: crawler and page queue are two threads, and
without shared pacing they would produce two requests per second together.
"""

from __future__ import annotations

import asyncio
import html
import json
import logging
import queue
import re
import subprocess
import tempfile
import threading
import time
from collections.abc import Callable, Mapping
from datetime import timedelta
from pathlib import Path
from typing import Any
from uuid import UUID

import asyncpg
import httpx

from app import catalog, catalog_browse
from app.musicbrainz import DEFAULT_CONTACT, exact_artist, lucene_escape, studio_groups
from app.names import norm

logger = logging.getLogger("apertonodo")

MB_ROOT = "https://musicbrainz.org/ws/2"
CAA_ROOT = "https://coverartarchive.org"
WIKIDATA_API = "https://www.wikidata.org/w/api.php"
COMMONS_API = "https://commons.wikimedia.org/w/api.php"

# Exactly same pause as MusicBrainz client: at most one request per second.
PAUSE_S = 1.05
TIMEOUT_S = 20.0
# Mobile needs no more, while Commons originals reach 20 MB.
PHOTO_WIDTH = 600
# Archive cover arrives already shrunk (`front-500`), while release file
# and Commons photo were stored as-is, up to `MAX_BYTES`: production sample 04.10 —
# 789 covers over 300 KB occupy 48% of space. UI grid needs 500
# px — exactly what archive provides, phone needs no more.
COVER_SIDE = 500
# `ffmpeg` spends tens of milliseconds per image; ten seconds indicates failure,
# in which case original image is stored as-is without stalling the queue.
SHRINK_TIMEOUT_S = 10.0
MAX_BYTES = 5_000_000
# How many artists crawler visits. Same as Last.fm.
CRAWL_ARTISTS = 20_000
# Covers per artist per crawl: UI needs grid, not entire
# discography with live albums. Remaining covers will be fetched on page view.
COVERS_PER_ARTIST = 20
# Not found — do not re-query for entire quarter. Cover appears in archive
# rarely, and each attempt costs outbound request.
RETRY = timedelta(days=90)
# Cover storage quota (FT-544, P-A65). 20 GB is ~300k covers.
COVER_QUOTA = 20 * 1024**3
# Crawler wakes up at most once per hour; active crawl is not re-entered.
CHECK_INTERVAL_S = 3600.0
# MusicBrainz responses live in metadata_cache same duration as artist page:
# shared keys allow crawler to warm cache for pages.
MB_KEEP = timedelta(days=90)
RELEASE_GROUP_PAGES = 4

TAG = re.compile(r"<[^>]*>")
SPACE = re.compile(r"\s+")
JPEG, PNG = b"\xff\xd8\xff", b"\x89PNG"


class Stop(Exception):
    """Crawl interrupted: network or third-party service error. Will resume next time."""


def kind_of(blob: bytes) -> str | None:
    """Extension from magic bytes. None if not an image.

    Inspect bytes rather than Content-Type: third-party headers cannot be trusted,
    and release filenames are arbitrary.
    """
    if blob.startswith(JPEG):
        return "jpg"
    if blob.startswith(PNG):
        return "png"
    return None


CONTENT_TYPE = {"jpg": "image/jpeg", "png": "image/png"}


def _larger_side(path: Path) -> int:
    """Larger side of image. If unreadable — 0, and `shrink` returns as-is."""
    result = subprocess.run(
        [
            "ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=width,height", "-of", "csv=p=0", str(path),
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=True,
        timeout=SHRINK_TIMEOUT_S,
    )
    numbers = [int(value) for value in result.stdout.decode().strip().split(",") if value.strip().isdigit()]
    return max(numbers, default=0)


def shrink(blob: bytes, side: int) -> bytes:
    """Downscale an image to `side` pixels on the larger side (FT-545, P-A65).

    Covers from the archive arrive already resized (`front-500`), but the fallback
    path — a file from the release — and photos from Wikimedia Commons were stored
    as-is, up to `MAX_BYTES`: production measurement on 04.10 showed 789 covers
    larger than 300 KB taking 48% of the space. Resizing uses the same `ffmpeg`
    already present in the image for Opus copies (`app/variants.py`), aspect ratio
    is preserved via `decrease`, output is JPEG (`-q:v 4`).

    Small images are returned byte-for-byte; unreadable, failed, or timed-out
    runs are also returned as-is: an album without a cover is worse than with a large
    one, and the queue must not crash because of an image.
    """
    try:
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "in"
            source.write_bytes(blob)
            if _larger_side(source) <= side:
                return blob
            target = Path(folder) / "out.jpg"
            subprocess.run(
                [
                    "ffmpeg", "-v", "error", "-y", "-nostdin", "-i", str(source),
                    "-vf", f"scale={side}:{side}:force_original_aspect_ratio=decrease",
                    "-frames:v", "1", "-q:v", "4", "-map_metadata", "-1", str(target),
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=True,
                timeout=SHRINK_TIMEOUT_S,
            )
            result = target.read_bytes()
    except (OSError, ValueError, subprocess.SubprocessError):
        return blob
    return result or blob


def plain(text: str) -> str:
    """Author credit from Wikimedia Commons arrives as HTML with links; keep plain text."""
    return SPACE.sub(" ", html.unescape(TAG.sub(" ", text))).strip()


def wikidata_id(payload: Mapping[str, Any]) -> str | None:
    """Wikidata Q-identifier from MusicBrainz artist relations."""
    for relation in payload.get("relations") or []:
        if relation.get("type") == "wikidata":
            resource = str((relation.get("url") or {}).get("resource") or "")
            return resource.rsplit("/", 1)[-1] or None
    return None


def commons_file(payload: Mapping[str, Any]) -> str | None:
    """Wikimedia Commons file name from property P18 ("image")."""
    for claim in (payload.get("claims") or {}).get("P18") or []:
        value = ((claim.get("mainsnak") or {}).get("datavalue") or {}).get("value")
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


def commons_credit(payload: Mapping[str, Any]) -> tuple[str, str, str] | None:
    """(image URL, author, license) from Wikimedia Commons response.

    Missing author or license name results in None, and photo is skipped entirely.
    Displaying Wikimedia Commons images without attribution is prohibited.
    """
    for page in ((payload.get("query") or {}).get("pages") or {}).values():
        info = ((page.get("imageinfo") or [{}]) or [{}])[0]
        extra = info.get("extmetadata") or {}
        url = str(info.get("thumburl") or info.get("url") or "").strip()
        author = plain(str((extra.get("Artist") or {}).get("value") or ""))
        license_name = plain(str((extra.get("LicenseShortName") or {}).get("value") or ""))
        if url and author and license_name:
            return url, author, license_name
    return None


class Store:
    """Image files on disk. Database only stores path relative to root."""

    def __init__(self, root: Path) -> None:
        self.root = root

    def save(self, folder: str, name: str, blob: bytes, ext: str) -> str:
        # First two characters of name form subdirectory: 100k files in one directory
        # slows down even `ls`.
        relative = f"{folder}/{name[:2]}/{name}.{ext}"
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        # Write to temporary file and rename: half-written files must never be served
        # to the phone.
        half = path.with_name(path.name + ".part")
        half.write_bytes(blob)
        half.replace(path)
        return relative

    def open(self, relative: str) -> Path | None:
        # Path originates from database, but ensure it stays within root:
        # writing there is the only place from which the server serves files.
        path = (self.root / relative).resolve()
        if not path.is_relative_to(self.root.resolve()) or not path.is_file():
            return None
        return path

    def delete(self, relative: str) -> None:
        """Remove file from disk. Path is internal but never leaves root."""
        path = (self.root / relative).resolve()
        if path.is_relative_to(self.root.resolve()):
            path.unlink(missing_ok=True)


class Images:
    """Image queue and background crawler.

    `from_release` is fallback cover path: file directly from the release.
    Provided by catalog (`app/catalog_api.py`) because it tracks releases, not this
    module. Without a source extension there is no fallback path, leaving only the archive.
    """

    def __init__(
        self,
        root: Path,
        database_url: str,
        *,
        proxy: str | None = None,
        contact: str = DEFAULT_CONTACT,
        client: Callable[[], httpx.Client] | None = None,
        from_release: Callable[[str, str], bytes | None] | None = None,
        pause_s: float = PAUSE_S,
        limit: int = CRAWL_ARTISTS,
        cover_quota_bytes: int = COVER_QUOTA,
    ) -> None:
        self.store = Store(root)
        self.database_url = database_url
        self.proxy = proxy
        self.contact = contact
        # Tests inject a client with prerecorded responses.
        self.client = client or self._client
        self.from_release = from_release
        self.pause_s = pause_s
        self.limit = limit
        self.cover_quota_bytes = cover_quota_bytes
        self.queue: queue.Queue[tuple[str, str, str, str, bool]] = queue.Queue()
        self.wanted: set[tuple[str, str]] = set()
        self.worker: threading.Thread | None = None
        self.robot: threading.Thread | None = None
        self.last_check = float("-inf")
        self._pace = threading.Lock()
        self._last_call = 0.0

    def _client(self) -> httpx.Client:
        return httpx.Client(
            timeout=TIMEOUT_S,
            proxy=self.proxy or None,
            headers={"User-Agent": f"apertonodo/1 ( {self.contact} )"},
            follow_redirects=True,
        )

    # --- queue -----------------------------------------------------------

    def want(self, job: tuple[str, str, str, str], *, playable: bool = True) -> None:
        """Enqueue an image for retrieval.

        Never raises: queue itself handles serialized "one at a time" fetching.
        Repeated requests for the same image are deduplicated.
        """
        key = (job[0], job[1])
        if key in self.wanted:
            return
        self.wanted.add(key)
        self.queue.put((*job, playable))
        if self.worker is None or not self.worker.is_alive():
            # Daemon thread rather than an event loop task: both network and disk
            # operations here are blocking, and in the event loop they would block
            # all requests, including audio streaming.
            self.worker = threading.Thread(target=self._work, name="images", daemon=True)
            self.worker.start()

    def _work(self) -> None:
        with self.client() as client:
            while True:
                job = self.queue.get()
                try:
                    self._one(client, job)
                except Exception as exc:  # noqa: BLE001
                    # Stop message is response status code or exception class name without URL (`get`);
                    # other exceptions might contain URL — keep class name only.
                    reason = f"Stop {exc}" if isinstance(exc, Stop) else type(exc).__name__
                    logger.info("image: %s failed: %s", job[0], reason)
                finally:
                    self.wanted.discard((job[0], job[1]))
                    self.queue.task_done()

    def _one(self, client: httpx.Client, job: tuple[str, str, str, str, bool]) -> None:
        kind, key, first, second, playable = job
        if kind == "cover":
            self.cover(client, key, first, second, playable=playable)
        else:
            self.photo(client, key, first, second)

    # --- single outbound request -----------------------------------------

    def get(self, client: httpx.Client, url: str, params: dict[str, str] | None = None) -> httpx.Response:
        """Outbound request with rate limiting. Pause is shared between crawler and queue."""
        with self._pace:
            wait = self.pause_s - (time.monotonic() - self._last_call)
            if wait > 0:
                time.sleep(wait)
            try:
                response = client.get(url, params=params)
            except httpx.HTTPError as exc:
                # Class name only: httpx exception string contains URL, which exposes
                # the artist/release being requested.
                raise Stop(type(exc).__name__) from None
            finally:
                self._last_call = time.monotonic()
        return response

    def json(self, client: httpx.Client, url: str, params: dict[str, str]) -> dict[str, Any]:
        response = self.get(client, url, params)
        if response.status_code != 200:
            raise Stop(f"http {response.status_code}")
        try:
            return dict(response.json())
        except ValueError:
            raise Stop("ValueError") from None

    # --- cover -----------------------------------------------------------

    def cover(
        self, client: httpx.Client, album_id: str, artist: str, title: str, *, playable: bool = True
    ) -> str:
        """Archive first; release file fallback only if album is playable."""
        began = time.monotonic()
        blob, busy = self.archive_front(client, album_id)
        source = "archive"
        if blob is None and playable and self.from_release is not None:
            blob = self.from_release(artist, title)
            source = "release"
        if blob is not None:
            blob = shrink(blob, COVER_SIDE)
        ext = kind_of(blob or b"")
        relative = self.store.save("covers", album_id, blob or b"", ext) if ext else None
        if relative is None and busy:
            # Archive was busy, not empty. Recording this as "searched, not found"
            # would silence the album until RETRY: a single 503 would mean three
            # months without a cover. On 20.09 this happened to 5 out of 6 albums,
            # all 5 having covers in the archive. Do not record attempt, leaving
            # the album unfetched so it can be requested on next page open.
            logger.info("cover: busy in %d ms", int((time.monotonic() - began) * 1000))
            return "busy"
        asyncio.run(self._save_cover(album_id, relative, len(blob or b"") if relative else None))
        if relative is None:
            logger.info("cover: none in %d ms", int((time.monotonic() - began) * 1000))
            return "none"
        logger.info(
            "cover: stored %d KB from %s in %d ms",
            len(blob or b"") // 1024,
            source,
            int((time.monotonic() - began) * 1000),
        )
        return "stored"

    def archive_front(self, client: httpx.Client, album_id: str) -> tuple[bytes | None, bool]:
        """Front cover of release group from Cover Art Archive.

        `front-500` is a pre-scaled thumbnail: phone does not need more, while originals
        can be several megabytes. Missing front cover returns 404 or 460 ("covers exist,
        but front cover is not among them", as seen with Nevermind on 20.09); this is normal.

        Second return value indicates "archive busy": 5xx and 429 indicate archive status,
        not missing cover, and must not be cached as "not found".
        """
        response = self.get(client, f"{CAA_ROOT}/release-group/{album_id}/front-500")
        if response.status_code == 200 and len(response.content) <= MAX_BYTES:
            return response.content, False
        return None, response.status_code >= 500 or response.status_code == 429

    async def _save_cover(self, album_id: str, relative: str | None, size_bytes: int | None) -> None:
        await self._write(
            "INSERT INTO album_images (album_id, path, tried_at, size_bytes) "
            "VALUES ($1::uuid, $2, now(), $3) "
            "ON CONFLICT (album_id) DO UPDATE SET path = EXCLUDED.path, tried_at = now(), "
            "size_bytes = EXCLUDED.size_bytes",
            album_id,
            relative,
            size_bytes,
        )
        if relative is not None:
            await self._evict(album_id)

    # --- space quota -----------------------------------------------------

    EVICT_SQL = """
    WITH ranked AS (
        -- Cumulative bytes preceding this row: evict oldest first, taking
        -- just enough to stay under quota. Order by COALESCE(opened_at, tried_at),
        -- tie-breaker is album_id.
        SELECT album_id,
               COALESCE(sum(size_bytes) OVER (ORDER BY COALESCE(opened_at, tried_at), album_id), 0)
                 - COALESCE(size_bytes, 0) AS passed
        FROM album_images
        WHERE album_id <> $1::uuid AND path IS NOT NULL
    )
    DELETE FROM album_images
    WHERE album_id IN (SELECT album_id FROM ranked WHERE passed < $2::bigint)
    RETURNING path, size_bytes
    """

    async def _evict(self, keep: str) -> None:
        """Evict least recently opened covers until storage is below quota.

        Sum calculated in a single query; batch deletion. Entire row deleted,
        not `path = NULL`: otherwise album would be treated as "tried and not found"
        until `RETRY`, whereas cover might exist. File removed from disk too.
        Newly stored cover is kept. Log contains numbers only.
        """
        conn = await asyncpg.connect(self.database_url)
        try:
            total = await conn.fetchval("SELECT COALESCE(sum(size_bytes), 0)::bigint FROM album_images")
            if total <= self.cover_quota_bytes:
                return
            rows = await conn.fetch(self.EVICT_SQL, keep, total - self.cover_quota_bytes)
        finally:
            await conn.close()
        if not rows:
            return
        for row in rows:
            self.store.delete(row["path"])
        logger.info(
            "cover: evicted %d, %d bytes",
            len(rows),
            sum(row["size_bytes"] or 0 for row in rows),
        )

    # --- artist photo -----------------------------------------------------

    def photo(self, client: httpx.Client, artist_key: str, mbid: str, name: str = "") -> str:
        """Photo from Wikimedia Commons: MusicBrainz -> Wikidata -> Wikimedia Commons.

        Three requests and about two seconds (20.09 measurement: 5 of 5 artists).
        Without author and license, photo is not fetched — see module docstring.
        Artist search results lack MBID: if omitted, resolve by name.
        """
        began = time.monotonic()
        if not mbid:
            found_id = self._artist_id(client, name or artist_key)
            if found_id is None:
                asyncio.run(self._save_photo(artist_key, None, None, None, None))
                logger.info("photo: none in %d ms", int((time.monotonic() - began) * 1000))
                return "none"
            mbid = str(found_id["id"])
        found = self._commons(client, mbid)
        relative = author = license_name = None
        if found is not None:
            url, author, license_name = found
            response = self.get(client, url)
            if response.status_code >= 500 or response.status_code == 429:
                # Commons is busy or rate-limiting: response indicates service status,
                # not artist availability. Error body is not an image, and without
                # this check it would be stored as "searched, not found", silencing
                # artist for RETRY (3 months). For covers this is handled with "busy"
                # flag because of release fallback. Here there is no fallback, so
                # raise `Stop`: it exits directly, same as when any of 3 lookup
                # requests fails (`json()`), skipping `_save_photo`.
                raise Stop(f"http {response.status_code}")
            blob = response.content
            ext = kind_of(blob)
            if ext is not None and len(blob) <= MAX_BYTES:
                blob = shrink(blob, PHOTO_WIDTH)
                ext = kind_of(blob)
                if ext is not None:
                    relative = self.store.save("photos", mbid, blob, ext)
        if relative is None:
            author = license_name = None
        asyncio.run(self._save_photo(artist_key, mbid, relative, author, license_name))
        if relative is None:
            logger.info("photo: none in %d ms", int((time.monotonic() - began) * 1000))
            return "none"
        logger.info("photo: stored with credit in %d ms", int((time.monotonic() - began) * 1000))
        return "stored"

    def _commons(self, client: httpx.Client, mbid: str) -> tuple[str, str, str] | None:
        relations = self.json(client, f"{MB_ROOT}/artist/{mbid}", {"inc": "url-rels", "fmt": "json"})
        entity = wikidata_id(relations)
        if entity is None:
            return None
        claims = self.json(
            client,
            WIKIDATA_API,
            {"action": "wbgetclaims", "entity": entity, "property": "P18", "format": "json"},
        )
        name = commons_file(claims)
        if name is None:
            return None
        info = self.json(
            client,
            COMMONS_API,
            {
                "action": "query",
                "titles": f"File:{name}",
                "prop": "imageinfo",
                "iiprop": "url|extmetadata",
                "iiurlwidth": str(PHOTO_WIDTH),
                "format": "json",
            },
        )
        return commons_credit(info)

    async def _save_photo(
        self,
        artist_key: str,
        mbid: str | None,
        relative: str | None,
        author: str | None,
        license_name: str | None,
    ) -> None:
        await self._write(
            "INSERT INTO artist_photos (artist_key, mbid, path, author, license, tried_at) "
            "VALUES ($1, $2::uuid, $3, $4, $5, now()) ON CONFLICT (artist_key) DO UPDATE SET "
            "mbid = EXCLUDED.mbid, path = EXCLUDED.path, author = EXCLUDED.author, "
            "license = EXCLUDED.license, tried_at = now()",
            artist_key,
            mbid,
            relative,
            author,
            license_name,
        )

    async def _write(self, sql: str, *args: Any) -> None:
        conn = await asyncpg.connect(self.database_url)
        try:
            await conn.execute(sql, *args)
        finally:
            await conn.close()

    # --- crawler ----------------------------------------------------------

    def soon(self) -> None:
        """Wake up crawler if due and not currently running. Called by catalog."""
        if self.robot is not None and self.robot.is_alive():
            return
        if time.monotonic() - self.last_check < CHECK_INTERVAL_S:
            return
        self.last_check = time.monotonic()
        self.robot = threading.Thread(target=self._crawl_safely, name="images-robot", daemon=True)
        self.robot.start()

    def _crawl_safely(self) -> None:
        try:
            self.crawl()
        except Exception as exc:  # noqa: BLE001
            logger.warning("images: crawl failed: %s", type(exc).__name__)

    def crawl(self) -> tuple[int, int]:
        """Crawl queue: listened artists first, then popular artists.

        Returns (number of artists processed, number of covers queued).
        Interrupted crawl resumes from where it stopped: completed work is in
        database, and queue is rebuilt from it.
        """
        began = time.monotonic()
        artists = asyncio.run(self._todo())
        done = covers = 0
        with self.client() as client:
            for artist_key, name in artists:
                try:
                    covers += self._artist(client, artist_key, name)
                except Stop as stop:
                    logger.info("images: stopped after %d artists: %s", done, stop)
                    break
                done += 1
                # Single shared queue for crawler and active user requests. Do not take
                # next artist until queue drains: otherwise a user opening an album
                # would wait behind 20,000 background jobs.
                self.queue.join()
        logger.info(
            "images: %d artists in %d s, %d covers queued, %d queued",
            done,
            int(time.monotonic() - began),
            covers,
            len(artists),
        )
        return done, covers

    def _artist(self, client: httpx.Client, artist_key: str, name: str) -> int:
        own = asyncio.run(self._own_artist(name))
        if own is None:
            # No local MB copy — legacy path via online MusicBrainz.
            artist = self._artist_id(client, name)
            if artist is None:
                # Artist not found in MusicBrainz: neither photo nor covers available,
                # no need to retry for a quarter.
                asyncio.run(self._save_photo(artist_key, None, None, None, None))
                return 0
            mbid = str(artist["id"])
            groups = self._albums(client, mbid)
        else:
            row, groups = own
            if row is None:
                # Artist missing from local copy as well: same as online `found is
                # None` — mark in `artist_photos` for a quarter.
                asyncio.run(self._save_photo(artist_key, None, None, None, None))
                return 0
            mbid = str(row["id"])
        self.want(("photo", artist_key, mbid, ""))
        wanted = asyncio.run(self._untried(name, groups))
        for album_id, title in wanted[:COVERS_PER_ARTIST]:
            self.want(("cover", album_id, name, title))
        return len(wanted[:COVERS_PER_ARTIST])

    async def _own_artist(
        self, name: str
    ) -> tuple[dict[str, Any] | None, list[dict[str, Any]]] | None:
        """Artist and releases from local MusicBrainz copy.

        Indicator is the same as catalog and search: copy is loaded if `mb_loads`
        has a row. `None` means no local copy, crawler falls back to online API.
        Local copy resolves both queries ("who is this" and "what albums") in one
        database call that opens artist page, avoiding outbound requests.
        """
        conn = await asyncpg.connect(self.database_url)
        try:
            if not await catalog_browse.is_published(conn):
                return None
            row, _aliases, groups, _discs = await catalog_browse.get_artist(conn, name=name)
        finally:
            await conn.close()
        if row is None:
            return None, []
        return dict(row), groups

    def _artist_id(self, client: httpx.Client, name: str) -> dict[str, Any] | None:
        key = norm(name)
        payload = self._mb(
            client,
            f"mb:artist:{key}",
            "artist",
            {"query": f'artist:"{lucene_escape(name.strip())}"', "limit": "10"},
        )
        return exact_artist(payload, key)

    def _albums(self, client: httpx.Client, artist_id: str) -> list[dict[str, Any]]:
        groups: list[dict[str, Any]] = []
        for page in range(RELEASE_GROUP_PAGES):
            payload = self._mb(
                client,
                f"mb:release-groups:{artist_id}:{page}",
                "release-group",
                {"artist": artist_id, "type": "album|ep", "limit": "100", "offset": str(page * 100)},
            )
            groups += payload.get("release-groups") or []
            if len(groups) >= int(payload.get("release-group-count") or 0):
                break
        return studio_groups(groups)

    def _mb(
        self, client: httpx.Client, key: str, path: str, params: dict[str, str]
    ) -> dict[str, Any]:
        """MusicBrainz lookup via shared cache used by artist page.

        Keys are deliberately shared with `catalog_api.Catalog.mb`: background crawl
        warms page cache so subsequent user page view requires zero network calls.
        """
        kept = asyncio.run(self._cached(key))
        if kept is not None:
            return kept
        payload = self.json(client, f"{MB_ROOT}/{path}", {**params, "fmt": "json"})
        asyncio.run(
            self._write(
                "INSERT INTO metadata_cache (cache_key, payload, fetched_at, expires_at) "
                "VALUES ($1, $2::jsonb, now(), now() + $3::interval) "
                "ON CONFLICT (cache_key) DO UPDATE SET payload = EXCLUDED.payload, "
                "fetched_at = EXCLUDED.fetched_at, expires_at = EXCLUDED.expires_at",
                key,
                json.dumps(payload),
                MB_KEEP,
            )
        )
        return payload

    async def _cached(self, key: str) -> dict[str, Any] | None:
        conn = await asyncpg.connect(self.database_url)
        try:
            row = await conn.fetchrow(
                "SELECT payload FROM metadata_cache WHERE cache_key = $1 AND expires_at > now()",
                key,
            )
        finally:
            await conn.close()
        return dict(json.loads(row["payload"])) if row is not None else None

    TODO_SQL = """
    WITH heard_names AS (
        SELECT artist FROM listens
        UNION
        SELECT artist FROM favorites
    ),
    catalog_one AS (
        SELECT artist_key, (array_agg(name ORDER BY popularity DESC))[1] AS name,
        sum(popularity) AS popularity
        FROM catalog_artists GROUP BY artist_key
    ),
    heard AS (
        SELECT DISTINCT c.artist_key, c.name, c.popularity
        FROM catalog_one c
        JOIN heard_names h ON c.name = h.artist OR c.artist_key = h.artist
    ),
    popular AS (
        SELECT artist_key, name, popularity
        FROM catalog_one
        ORDER BY popularity DESC, artist_key
        LIMIT $1
    ),
    ranked AS (
        SELECT artist_key, name, popularity, 1 AS heard FROM heard
        UNION ALL
        SELECT p.artist_key, p.name, p.popularity, 0
        FROM popular p
        WHERE NOT EXISTS (SELECT 1 FROM heard h WHERE h.artist_key = p.artist_key)
    ),
    top AS (
        SELECT artist_key, name, popularity, heard
        FROM ranked
        ORDER BY heard DESC, popularity DESC, artist_key
        LIMIT $1
    )
    SELECT top.artist_key, top.name FROM top
    LEFT JOIN artist_photos p USING (artist_key)
    WHERE p.artist_key IS NULL OR (p.path IS NULL AND p.tried_at < now() - $2::interval)
    ORDER BY top.heard DESC, top.popularity DESC, top.artist_key
    """

    async def _todo(self) -> list[tuple[str, str]]:
        conn = await asyncpg.connect(self.database_url)
        try:
            rows = await conn.fetch(self.TODO_SQL, self.limit, RETRY)
        finally:
            await conn.close()
        return [(row["artist_key"], row["name"]) for row in rows]

    async def _untried(
        self, name: str, groups: list[dict[str, Any]]
    ) -> list[tuple[str, str]]:
        """Releases that have active releases and have not been searched yet."""
        albums = [(str(group["id"]), str(group.get("title") or "")) for group in groups]
        if not albums:
            return []
        conn = await asyncpg.connect(self.database_url)
        try:
            plays = await catalog.playable(conn, name, [title for _id, title in albums])
            skip = await tried(conn, [album_id for album_id, _title in albums])
        finally:
            await conn.close()
        return [
            (album_id, title)
            for (album_id, title), play in zip(albums, plays, strict=True)
            if play and album_id not in skip
        ]


# --- page display helpers: read-only local database access -------------------


async def covers_of(conn: asyncpg.Connection, album_ids: list[str]) -> dict[str, str]:
    """album_id -> cover path on local server. Missing image omits key."""
    rows = await conn.fetch(
        "SELECT album_id FROM album_images WHERE album_id = ANY($1::uuid[]) AND path IS NOT NULL",
        album_ids,
    )
    return {str(row["album_id"]): f"/v1/covers/{row['album_id']}" for row in rows}


async def song_covers_of(conn: asyncpg.Connection, recording_ids: list[str]) -> dict[str, str]:
    """Track covers: album first, then earliest release group with cover."""
    ids = []
    for recording_id in recording_ids:
        try:
            ids.append(UUID(recording_id))
        except ValueError:
            continue
    if not ids:
        return {}
    try:
        rows = await conn.fetch(
            """
            SELECT DISTINCT ON (t.recording_mbid) t.recording_mbid, g.mbid AS album_id
            FROM mb_track t
            JOIN mb_medium m ON m.id = t.medium_id
            JOIN mb_release r ON r.mbid = m.release_mbid
            JOIN mb_release_group g ON g.mbid = r.group_mbid
            JOIN album_images i ON i.album_id = g.mbid AND i.path IS NOT NULL
            WHERE t.recording_mbid = ANY($1::uuid[])
            ORDER BY t.recording_mbid,
                     CASE WHEN g.primary_type = 'Album' THEN 0 ELSE 1 END,
                     g.first_date ASC NULLS LAST, g.mbid
            """,
            ids,
            timeout=1.0,
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning("song covers: database failed: %s", type(exc).__name__)
        return {}
    return {str(row["recording_mbid"]): f"/v1/covers/{row['album_id']}" for row in rows}


async def photo_of(conn: asyncpg.Connection, artist_key: str) -> tuple[str, str] | None:
    """(photo URL, attribution) or None. Attribution requires author.

    Photo without attribution is never served: "photo: author, license" attribution
    is a Wikimedia Commons license requirement. Guarded here as well as during save
    to prevent legacy uncredited rows from being exposed.
    """
    row = await conn.fetchrow(
        "SELECT mbid, path, author, license FROM artist_photos WHERE artist_key = $1",
        artist_key,
    )
    if row is None or row["path"] is None or not row["author"] or not row["license"]:
        return None
    return f"/v1/photos/{row['mbid']}", f"{row['author']}, {row['license']}"


async def cover_file(conn: asyncpg.Connection, album_id: Any) -> str | None:
    """Cover path and access timestamp update.

    Least recently opened covers are evicted based on `opened_at` (FT-544). Timestamp
    is throttled to at most once per hour per cover to avoid DB writes on scroll.
    """
    return await conn.fetchval(
        """
        WITH opened AS (
            UPDATE album_images SET opened_at = now()
            WHERE album_id = $1 AND path IS NOT NULL
              AND (opened_at IS NULL OR opened_at < now() - interval '1 hour')
        )
        SELECT path FROM album_images WHERE album_id = $1 AND path IS NOT NULL
        """,
        album_id,
    )


async def photo_file(conn: asyncpg.Connection, mbid: Any) -> str | None:
    return await conn.fetchval(
        "SELECT path FROM artist_photos WHERE mbid = $1 AND path IS NOT NULL "
        "AND author <> '' AND license <> '' LIMIT 1",
        mbid,
    )


async def tried(conn: asyncpg.Connection, album_ids: list[str]) -> set[str]:
    """Albums already queried: either have image or recent "not found" record."""
    rows = await conn.fetch(
        "SELECT album_id FROM album_images WHERE album_id = ANY($1::uuid[]) "
        "AND (path IS NOT NULL OR tried_at > now() - $2::interval)",
        album_ids,
        RETRY,
    )
    return {str(row["album_id"]) for row in rows}


def cover_quota(env: Mapping[str, str]) -> int:
    """Cover storage quota from environment.

    Same as `env_float` in `app/main.py`: unset and empty string are equivalent,
    typos in environment variables do not crash the server.
    """
    raw = str(env.get("COVER_QUOTA_BYTES", "") or "").strip()
    if not raw:
        return COVER_QUOTA
    try:
        return int(raw)
    except ValueError:
        logger.warning("bad COVER_QUOTA_BYTES, using default")
        return COVER_QUOTA


def images_from_env(env: Mapping[str, str], database_url: str | None) -> Images | None:
    """Image storage from environment. Without DB or image dir, images are disabled."""
    root = str(env.get("IMAGE_DIR", "")).strip()
    if not root or not database_url:
        return None
    return Images(
        Path(root),
        database_url,
        proxy=str(env.get("MUSICBRAINZ_PROXY", "") or "").strip() or None,
        contact=str(env.get("MUSICBRAINZ_CONTACT") or "").strip() or DEFAULT_CONTACT,
        cover_quota_bytes=cover_quota(env),
    )
