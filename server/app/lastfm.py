"""Last.fm for artist page: top tracks, similar artists, biography.

Enabled only via `LASTFM_API_KEY` in server environment. Without key —
no crawler, no blocks in responses, not a single outbound request.

Privacy is paramount here. Last.fm must never learn which artist the user
views, so the artist page never queries Last.fm directly: it reads
`lastfm_artists` table. The crawler, and only the crawler, populates the table —
processing all popular catalog artists sequentially in order of catalog popularity,
identical for every user. If an artist was not crawled, no blocks are returned.
Catalog browsing (genres, letters, lists) wakes the crawler, just like Play wakes cleanup —
not artist page views. Guard test: `tests/test_lastfm.py`.

Last.fm terms (last.fm/api/tos): non-commercial use, storing at most 100 MB of
their data locally, rapid bursts can cause key bans.
Therefore rate limit is at most one request per second, and initial population spans several nights.
Only names, titles, short text, and one number are kept — listener count,
MusicBrainz studio recording ID for top tracks (`top_track_ids`), and `artist.getinfo` tag names (no URLs).
Recording ID is looked up by the crawler, one query per track. The artist page reads the
pre-populated table. Cover images, links, and individual track play counts are still absent.

The key is passed in URL (`api_key=`), so no log line ever prints the URL
or the httpx exception message (which includes the URL). Log lines also exclude artist names.

From the production server Last.fm responds directly with `403 error 11 Access
Denied`, but works via residential exit (verified 19.09.2026). Solution:
`LASTFM_PROXY`, set to the same address as MusicBrainz proxy in compose.
"""

from __future__ import annotations

import asyncio
import html
import json
import logging
import re
import statistics
import threading
import time
from collections.abc import Callable, Mapping
from datetime import timedelta
from typing import Any

import asyncpg
import httpx

from app import catalog
from app.musicbrainz import DEFAULT_CONTACT, MB_RECORDING_URL, lucene_escape, recording_to_track
from app.names import norm

logger = logging.getLogger("apertonodo")
# httpx at INFO level logs entire request line, including `api_key=`.
# Without this line the key would leak into logs on the very first request
# as soon as someone sets INFO for everything (`python -m app.catalog` does that).
logging.getLogger("httpx").setLevel(logging.WARNING)

API_ROOT = "https://ws.audioscrobbler.com/2.0/"
# How many artists the crawler visits: first by catalog popularity.
# Benchmark 19.09 on full list (apertonodo_probe): 351,324 artists; at
# position 20,000 there are still real names (Apollo 440, Salieri, Art Zoyd),
# the top 20,000 account for 42% of all catalog popularity. Live sample 19.09 (first 50,
# residential uplink): 151 requests in 235s — 4.7s per artist, at most
# 0.78 req/s. 20,000 takes about 26 hours: several nights.
CRAWL_ARTISTS = 20_000
# Bios and top tracks change slowly; refresh once per quarter.
REFRESH = timedelta(days=90)
PAUSE_S = 1.0
TIMEOUT_S = 20.0
TOP_TRACKS = 10
TOP_STORED = 50
# Internal key "$rule" cannot collide with norm(title).
TOP_IDS_RULE = 4
SIMILAR_ASKED = 30
BIO_CHARS = 600
# Crawler wakes up at most once per hour; active crawl is not re-entered.
CHECK_INTERVAL_S = 3600.0
NOT_FOUND = 6

TAG = re.compile(r"<[^>]*>")
READ_MORE = re.compile(r"<a\b[^>]*>\s*Read more on Last\.fm\s*</a>\.?", re.IGNORECASE)
URL = re.compile(r"\b(?:https?://|www\.)\S+", re.IGNORECASE)
LICENSE = re.compile(r"User-contributed text is available under.*$", re.IGNORECASE | re.DOTALL)
SPACE = re.compile(r"\s+")
# Biography is arbitrary third-party text. A sentence containing a forbidden word
# from the source-word boundaries of the client API
# is discarded entirely: boundaries hold even on text not written by us.
BOUNDARY = re.compile(r"torrent|magnet|tracker|seeder|info_?hash", re.IGNORECASE)
SENTENCE = re.compile(r"(?<=[.!?])\s+")
# Disambiguation page rather than biography: "There are multiple artists that share the
# name Arkadia. 1) Full On Psytrance producer… 2) Metal…" (response 19.09).
NAMESAKES = re.compile(r"^there (?:are|is) (?:multiple|more than one|several|many) artists?", re.IGNORECASE)

QUEUE_SQL = """
WITH top AS (
    SELECT artist_key, (array_agg(name ORDER BY popularity DESC))[1] AS name,
           sum(popularity) AS popularity
    FROM catalog_artists GROUP BY artist_key
    ORDER BY sum(popularity) DESC, artist_key
    LIMIT $1
)
SELECT top.name FROM top LEFT JOIN lastfm_artists l USING (artist_key)
WHERE l.artist_key IS NULL OR l.fetched_at < now() - $2::interval
   OR (l.found AND (l.top_track_ids IS NULL OR l.top_stored IS NULL OR l.top_stored < $3))
ORDER BY top.popularity DESC, top.artist_key
"""

SAVE_SQL = """
INSERT INTO lastfm_artists
    (artist_key, found, bio, top_tracks, similar_artists, listeners, top_track_ids, tags, top_stored, fetched_at)
VALUES ($1, $2, $3, $4, $5, $6, $7::jsonb, $8, $9, now())
ON CONFLICT (artist_key) DO UPDATE SET found = EXCLUDED.found, bio = EXCLUDED.bio,
    top_tracks = EXCLUDED.top_tracks, similar_artists = EXCLUDED.similar_artists,
    listeners = EXCLUDED.listeners, top_track_ids = EXCLUDED.top_track_ids,
    tags = EXCLUDED.tags, top_stored = EXCLUDED.top_stored, fetched_at = EXCLUDED.fetched_at
"""

# In disambiguation and title: live, demo, rehearsal is not a studio recording.
VERSION_WORDS = ("live", "demo", "karaoke", "remix", "instrumental", "rehearsal")
# "My Sweet Lord (2014 Remaster)", "My Sweet Lord - Remastered 2014": Last.fm holds reissues
# as separate top rows. It is the same song, but with the suffix it was not found in MusicBrainz replica —
# the row stayed dark and led to search fallback.
REMASTER_TAIL = re.compile(
    r"\s*(?:[\(\[][^\)\]]*\bremaster(?:ed)?\b[^\)\]]*[\)\]]|\s[-–]\s[^-–]*\bremaster(?:ed)?\b.*)$",
    re.IGNORECASE,
)


class LastFmStop(Exception):
    """Crawl interrupted: network, key, rate limit. Will resume next time from the same place."""


def clean_bio(text: str) -> str | None:
    """Short text without links or HTML; up to `BIO_CHARS` characters, sentence-bounded."""
    text = READ_MORE.sub("", text or "")
    text = html.unescape(TAG.sub(" ", text))
    text = LICENSE.sub("", text)
    text = SPACE.sub(" ", text).strip()
    if NAMESAKES.match(text):
        return None
    # Sentence with bare URL without address is unreadable ("See for more.").
    text = " ".join(
        part for part in SENTENCE.split(text) if not URL.search(part) and not BOUNDARY.search(part)
    )
    return whole_sentences(text[: BIO_CHARS + 1]) or None


def whole_sentences(text: str) -> str:
    """Text up to the end of the last complete sentence.

    Last.fm truncates short `summary` mid-word: on 30.09, 2229 out of 4876
    bios were cut this way ("This band created its own").
    """
    text = text.strip()
    if len(text) <= BIO_CHARS and (not text or text[-1] in ".!?…»\")"):
        return text
    head = text[: BIO_CHARS + 1]
    end = max(head.rfind(mark) for mark in (". ", "! ", "? ", "… ", "» "))
    if end > 0:
        return text[: end + 1]
    return text[:BIO_CHARS].rsplit(" ", 1)[0] + "…"


def _bio(info: dict[str, Any]) -> str | None:
    bio = (info.get("artist") or {}).get("bio") or {}
    # Full text before summary: summary is cut mid-word by Last.fm.
    return clean_bio(str(bio.get("content") or "")) or clean_bio(str(bio.get("summary") or ""))


def _listeners(info: dict[str, Any]) -> int | None:
    """How many listeners the artist has. Last.fm returns this as string.

    None — number absent in response: such artist weight remains popularity-only,
    and zero instead of None would falsely claim listener count is exactly zero.
    """
    raw = ((info.get("artist") or {}).get("stats") or {}).get("listeners")
    text = str(raw or "").strip()
    return int(text) if text.isdigit() else None


def _tags(info: dict[str, Any]) -> list[str]:
    """Tag names from artist.getinfo, without URL and duplicates."""
    raw = ((info.get("artist") or {}).get("tags") or {}).get("tag") or []
    if isinstance(raw, dict):
        raw = [raw]
    seen: set[str] = set()
    names: list[str] = []
    for item in raw:
        if not isinstance(item, dict):
            continue
        name = str(item.get("name") or "").strip()
        key = name.casefold()
        if not name or key in seen:
            continue
        seen.add(key)
        names.append(name)
    return names


def _plain(title: str) -> str:
    """Song title without "remaster" suffix."""
    return REMASTER_TAIL.sub("", title).strip() or title


def _unique(names: list[str], limit: int) -> list[str]:
    seen: set[str] = set()
    kept = []
    for name in names:
        key = norm(name)
        if key and key not in seen:
            seen.add(key)
            kept.append(name.strip())
    return kept[:limit]


def _versioned(title: str, disambiguation: str) -> bool:
    blob = f"{title} {disambiguation}".casefold()
    return any(word in blob for word in VERSION_WORDS)


def _studio_release(recording: dict[str, Any]) -> bool:
    """Has official studio album or EP, without live/compilation in secondary types."""
    for release in recording.get("releases") or []:
        if not isinstance(release, dict) or str(release.get("status") or "") != "Official":
            continue
        group = release.get("release-group") or {}
        if not isinstance(group, dict):
            continue
        if group.get("primary-type") not in ("Album", "EP"):
            continue
        if group.get("secondary-types"):
            continue
        return True
    return False


def studio_recording(payload: dict[str, Any], title: str) -> dict[str, Any] | None:
    """MusicBrainz studio recording with matching title.

    Last.fm mbid in top tracks is often broken (sample: 404 on recording/release/track).
    Lucene `NOT secondarytype:*` drops the original if it also appears on
    a live album. Therefore filtering is in Python: exact title, not live/demo,
    not video, has official studio release. Among survivors — prefer ISRC
    (studio tracks usually have one), duration closest to median.
    """
    wanted = norm(title)
    if not wanted:
        return None
    picked: list[dict[str, Any]] = []
    for recording in payload.get("recordings") or []:
        if not isinstance(recording, dict):
            continue
        name = str(recording.get("title") or "")
        if norm(name) != wanted:
            continue
        if _versioned(name, str(recording.get("disambiguation") or "")):
            continue
        if recording.get("video") is True:
            continue
        if not _studio_release(recording):
            continue
        track = recording_to_track(recording)
        if track is None or int(track["duration_ms"]) <= 0:
            continue
        track["_isrc"] = bool(recording.get("isrcs"))
        picked.append(track)
    if any(item["_isrc"] for item in picked):
        picked = [item for item in picked if item["_isrc"]]
    if not picked:
        return None
    median = statistics.median(int(item["duration_ms"]) for item in picked)
    best = min(picked, key=lambda item: abs(int(item["duration_ms"]) - median))
    best.pop("_isrc", None)
    return best


class LastFm:
    def __init__(
        self,
        api_key: str,
        database_url: str,
        *,
        proxy: str | None = None,
        client: Callable[[], httpx.Client] | None = None,
        mb_client: Callable[[], httpx.Client] | None = None,
        pause_s: float = PAUSE_S,
        limit: int = CRAWL_ARTISTS,
    ) -> None:
        self.api_key = api_key
        self.database_url = database_url
        self.proxy = proxy
        # Tests inject client with recorded responses.
        self.client = client or self._client
        self.mb_client = mb_client
        self.pause_s = pause_s
        self.limit = limit
        self.last_check = float("-inf")
        self.thread: threading.Thread | None = None

    def _client(self) -> httpx.Client:
        return httpx.Client(
            timeout=TIMEOUT_S, proxy=self.proxy or None, headers={"User-Agent": "apertonodo/1"}
        )

    # --- crawler ---------------------------------------------------------

    def soon(self) -> None:
        """Start background crawl if due and not already running."""
        if self.thread is not None and self.thread.is_alive():
            return
        if time.monotonic() - self.last_check < CHECK_INTERVAL_S:
            return
        self.last_check = time.monotonic()
        # Daemon thread rather than asyncio.to_thread: crawl takes hours, and server
        # shutdown should not wait for it. An interrupted crawl resumes next time
        # from the same place — completed items are already in the database.
        self.thread = threading.Thread(target=self._crawl_safely, name="lastfm", daemon=True)
        self.thread.start()

    def _crawl_safely(self) -> None:
        try:
            asyncio.run(self.crawl())
        except Exception as exc:  # noqa: BLE001
            logger.warning("lastfm: crawl failed: %s", type(exc).__name__)

    def ask(self, client: httpx.Client, method: str, artist: str, **extra: str) -> dict[str, Any] | None:
        """Single request. None — Last.fm does not know this artist."""
        if self.pause_s:
            time.sleep(self.pause_s)
        params = {"method": method, "artist": artist, "autocorrect": "1", **extra}
        try:
            response = client.get(API_ROOT, params={**params, "api_key": self.api_key, "format": "json"})
            payload = response.json()
        except (httpx.HTTPError, ValueError) as exc:
            # Name only: httpx exception message contains URL with the key.
            raise LastFmStop(type(exc).__name__) from None
        error = payload.get("error") if isinstance(payload, dict) else None
        if error == NOT_FOUND:
            return None
        if error:
            raise LastFmStop(f"error {error}")
        if response.status_code != 200 or not isinstance(payload, dict):
            raise LastFmStop(f"http {response.status_code}")
        return payload

    def fetch(
        self, client: httpx.Client, name: str, *, limit: int = TOP_TRACKS
    ) -> tuple[bool, str | None, list[str], list[str], int | None, list[str]]:
        """(is known to Last.fm, bio, top tracks, similar, listeners, tags)."""
        # Russian first; if no Russian bio — Last.fm returns empty text with a single
        # "Read more" link (19.09: Metallica and Kino present, Arkadia absent),
        # requiring one extra request for English bio.
        info = self.ask(client, "artist.getinfo", name, lang="ru")
        if info is None:
            return False, None, [], [], None, []
        # Listener count is retrieved from the same response as the bio.
        listeners = _listeners(info)
        tags = _tags(info)
        bio = _bio(info)
        if bio is None:
            bio = _bio(self.ask(client, "artist.getinfo", name) or {})
        similar = self.ask(client, "artist.getsimilar", name, limit=str(SIMILAR_ASKED)) or {}
        asked_limit = max(TOP_STORED, limit * 2)
        top = self.ask(client, "artist.gettoptracks", name, limit=str(asked_limit)) or {}
        similar_names = [
            str(item.get("name") or "") for item in (similar.get("similarartists") or {}).get("artist") or []
        ]
        top_names = [str(item.get("name") or "") for item in (top.get("toptracks") or {}).get("track") or []]
        return (
            True,
            bio,
            _unique([_plain(title) for title in top_names], limit),
            _unique(similar_names, SIMILAR_ASKED),
            listeners,
            tags,
        )

    def ask_recording(self, client: httpx.Client, title: str, artist: str) -> dict[str, Any] | None:
        """Single recording lookup. MusicBrainz failure does not stop Last.fm crawl."""
        if self.pause_s:
            time.sleep(self.pause_s)
        query = (
            f'recording:"{lucene_escape(title)}" AND artist:"{lucene_escape(artist)}"'
            f" AND status:official AND NOT comment:live AND NOT comment:demo"
        )
        try:
            response = client.get(MB_RECORDING_URL, params={"query": query, "fmt": "json", "limit": "100"})
            payload = response.json()
        except (httpx.HTTPError, ValueError):
            return None
        if response.status_code != 200 or not isinstance(payload, dict):
            return None
        return payload

    def resolve_top(self, client: httpx.Client, artist: str, titles: list[str]) -> dict[str, Any]:
        """Studio recording IDs for top track titles. Key is norm(title)."""
        found: dict[str, Any] = {}
        for title in titles:
            track = studio_recording(self.ask_recording(client, title, artist) or {}, title)
            if track is None:
                continue
            found[norm(title)] = {"id": track["id"], "duration_ms": int(track["duration_ms"])}
        return found

    async def crawl(self) -> tuple[int, int]:
        """Crawl the queue: missing entries or data older than `REFRESH`.

        Order is catalog popularity, identical for any user:
        it reveals nothing about who is listening to whom. Returns (saved,
        of which unknown to Last.fm).
        """
        began = time.monotonic()
        saved = unknown = 0
        conn = await asyncpg.connect(self.database_url)
        try:
            try:
                published = bool(await conn.fetchval("SELECT EXISTS (SELECT 1 FROM mb_loads)"))
            except Exception:
                published = False
            queue = [row["name"] for row in await conn.fetch(QUEUE_SQL, self.limit, REFRESH, TOP_STORED)]
            mb = None if published else (self.mb_client() if self.mb_client is not None else None)
            try:
                with self.client() as client:
                    for name in queue:
                        try:
                            found, bio, top, similar, listeners, tags = self.fetch(
                                client, name, limit=TOP_STORED
                            )
                        except LastFmStop as stop:
                            logger.info("lastfm: stopped after %d artists: %s", saved, stop)
                            break
                        if published and found:
                            from app import local_search
                            recordings: dict[str, Any] = await local_search.top_track_ids(conn, name, top)
                            recordings["$rule"] = TOP_IDS_RULE
                        else:
                            recordings = self.resolve_top(mb, name, top) if found and mb is not None else {}
                        await conn.execute(
                            SAVE_SQL,
                            norm(name),
                            found,
                            bio,
                            top,
                            similar,
                            listeners,
                            json.dumps(recordings),
                            tags,
                            TOP_STORED,
                        )
                        saved += 1
                        unknown += not found
            finally:
                if mb is not None:
                    mb.close()
        finally:
            await conn.close()
        logger.info(
            "lastfm: %d artists in %d s, %d unknown, %d queued",
            saved,
            int(time.monotonic() - began),
            unknown,
            len(queue),
        )
        return saved, unknown


# --- artist page: own table only -------------------------------------------


async def _attach_top_tracks(
    conn: asyncpg.Connection,
    key: str,
    name: str,
    row: asyncpg.Record,
    *,
    limit: int | None = None,
) -> list[dict[str, Any]]:
    # Rows saved before rule was applied are cleaned up on display: strip suffix and duplicate tracks.
    raw_top = list(row["top_tracks"])
    top = _unique([_plain(title) for title in raw_top], len(raw_top))
    if limit is not None:
        # With a margin: two spellings of one song collapse below, the page must not get shorter.
        top = top[: limit * 2]
    if not top:
        return []
    plays = await catalog.playable(conn, name, top)
    result_tracks = [{"title": title, "playable": play} for title, play in zip(top, plays, strict=True)]
    raw_ids = row["top_track_ids"]
    if isinstance(raw_ids, str):
        raw_ids = json.loads(raw_ids)
    ids = dict(raw_ids) if isinstance(raw_ids, dict) else {}
    # Legacy top is recalculated once as a whole, even already resolved IDs.
    # IDs unknown to own replica from legacy HTTP search remain intact.
    if ids.get("$rule") != TOP_IDS_RULE and await conn.fetchval("SELECT EXISTS (SELECT 1 FROM mb_loads)"):
        from app import local_search

        ids.update(await local_search.top_track_ids(conn, name, top))
        ids["$rule"] = TOP_IDS_RULE
        await conn.execute(
            "UPDATE lastfm_artists SET top_track_ids = $2::jsonb WHERE artist_key = $1",
            key,
            json.dumps(ids),
        )
    attached = []
    shown: set[str] = set()
    for item in result_tracks:
        rec = ids.get(norm(str(item["title"])))
        if not isinstance(rec, dict) or not rec.get("id"):
            # No recording number after a lookup: the tap would go to search, so not playable (FT-866).
            # Before any lookup (no catalog copy yet) "no number" says nothing about the song.
            looked_up = ids.get("$rule") == TOP_IDS_RULE
            attached.append({**item, "playable": item["playable"] and not looked_up})
            continue
        if rec["id"] in shown:
            continue  # another spelling of a song already in the list
        shown.add(rec["id"])
        attached.append(
            {
                "id": rec["id"],
                "title": item["title"],
                "artist": name,
                "duration_ms": int(rec.get("duration_ms") or 0),
                "artwork_url": "",
                "playable": item["playable"],
            }
        )
    return attached if limit is None else attached[:limit]


async def songs(conn: asyncpg.Connection, name: str, *, limit: int | None = None) -> list[dict[str, Any]]:
    """All stored top tracks of the artist from own table (FT-553)."""
    key = norm(name)
    row = await conn.fetchrow(
        "SELECT top_tracks, top_track_ids FROM lastfm_artists "
        "WHERE artist_key = $1 AND found",
        key,
    )
    if row is None:
        return []
    return await _attach_top_tracks(conn, key, name, row, limit=limit)


async def blocks(conn: asyncpg.Connection, name: str) -> dict[str, Any]:
    """Top tracks, similar artists, and bio from own table. No outbound requests.

    Similar artists — catalog matches only: catalog contains only artists
    with live assets, otherwise phone UI would show dead buttons.
    Top tracks carry `playable` flag following the same rule as albums (`catalog.playable`).
    """
    key = norm(name)
    row = await conn.fetchrow(
        "SELECT bio, top_tracks, similar_artists, top_track_ids FROM lastfm_artists "
        "WHERE artist_key = $1 AND found",
        key,
    )
    if row is None:
        return {}
    result: dict[str, Any] = {}
    top = await _attach_top_tracks(conn, key, name, row, limit=TOP_TRACKS)
    if top:
        result["top_tracks"] = top
    wanted = [norm(item) for item in row["similar_artists"]]
    known = {
        found["artist_key"]: found["name"]
        for found in await conn.fetch(
            "SELECT DISTINCT ON (artist_key) artist_key, name FROM catalog_artists "
            "WHERE artist_key = ANY($1::text[]) ORDER BY artist_key, popularity DESC",
            wanted,
        )
    }
    similar = [{"name": known[item]} for item in dict.fromkeys(wanted) if item in known and item != key]
    if similar:
        result["similar"] = similar
    if row["bio"]:
        # Bios saved prior to 30.09 were truncated mid-word; crawler
        # will refresh them over the quarter, in the meantime truncate on output.
        result["bio"] = whole_sentences(row["bio"])
    return result


def lastfm_from_env(env: Mapping[str, str], database_url: str | None) -> LastFm | None:
    key = str(env.get("LASTFM_API_KEY", "")).strip()
    if not key or not database_url:
        return None
    contact = str(env.get("MUSICBRAINZ_CONTACT") or "").strip() or DEFAULT_CONTACT
    mb_proxy = str(env.get("MUSICBRAINZ_PROXY", "")).strip() or None

    def mb_client() -> httpx.Client:
        return httpx.Client(
            timeout=TIMEOUT_S,
            proxy=mb_proxy,
            headers={"User-Agent": f"apertonodo/0.1 ( {contact} )"},
        )

    return LastFm(
        key,
        database_url,
        proxy=str(env.get("LASTFM_PROXY", "")).strip() or None,
        mb_client=mb_client,
    )


def wake(app: Any) -> None:
    """Wake up crawler if enabled. Called during catalog browsing."""
    robot = getattr(app.state, "lastfm", None)
    if robot is not None:
        robot.soon()
