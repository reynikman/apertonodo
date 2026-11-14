from __future__ import annotations

import asyncio
import time
from collections import OrderedDict
from typing import Any, Protocol

import httpx

from app.matching import BLACKLIST, fold_query
from app.names import norm

MB_RECORDING_URL = "https://musicbrainz.org/ws/2/recording"
# musicbrainz.org asks for no more than one request per second per IP and requires
# a meaningful User-Agent. Without it, responds with 403.
MIN_INTERVAL_S = 1.05
# Fallback when MUSICBRAINZ_CONTACT is empty: the project page, a real contact MusicBrainz accepts.
DEFAULT_CONTACT = "https://github.com/reynikman/apertonodo"
# In addition to BLACKLIST from matching: tribute in MusicBrainz output
# occurs frequently and means specifically not the desired recording.
DERIVATIVE_WORDS = (*BLACKLIST, "tribute", "tributes", "remixed", "remixes", "rerecorded")


class HttpJson(Protocol):
    async def get_json(self, url: str, params: dict[str, str]) -> dict[str, Any]: ...


class MetadataCache:
    """MusicBrainz responses by query text.

    With a limit: previously the dictionary grew without bound, and every new search
    stayed in process memory forever. Evicts least recently accessed entries.
    """

    def __init__(self, max_entries: int = 1000) -> None:
        self._data: OrderedDict[str, Any] = OrderedDict()
        self._max = max_entries

    async def get(self, key: str) -> Any | None:
        value = self._data.get(key)
        if value is not None:
            self._data.move_to_end(key)
        return value

    async def set(self, key: str, value: Any) -> None:
        self._data[key] = value
        self._data.move_to_end(key)
        while len(self._data) > self._max:
            self._data.popitem(last=False)


ATTEMPTS = 3


def _retry_after(response: httpx.Response, fallback: float) -> float:
    """How long to wait before retry: their header first, then own pause."""
    raw = str(response.headers.get("retry-after", "")).strip()
    try:
        return max(float(raw), 0.0)
    except ValueError:
        return fallback


class ThrottledHttpJson:
    """httpx with mandatory User-Agent and one request per second.

    Maintains interval shared across client rather than per request: MusicBrainz measures
    rate limit by egress IP, so concurrent searches must still queue up.
    """

    def __init__(
        self,
        *,
        contact: str = DEFAULT_CONTACT,
        timeout: float = 6.0,
        min_interval_s: float = MIN_INTERVAL_S,
        client: httpx.AsyncClient | None = None,
        proxy: str | None = None,
    ) -> None:
        # proxy — internet access not direct. Needed where musicbrainz.org
        # cannot be reached: on the prod server TLS to this host is cut by SNI
        # (without SNI the same connection succeeds), and the catalog times out
        # with ConnectTimeout. Via proxy the same request gives 200 in 1.2s.
        # The value comes from the environment and is not kept in the repository.
        self.proxy = proxy
        self._client = client or httpx.AsyncClient(
            timeout=timeout,
            headers={"User-Agent": f"apertonodo/0.1 ( {contact} )"},
            proxy=proxy,
        )
        self._min_interval = min_interval_s
        self._lock = asyncio.Lock()
        self._last = 0.0

    async def aclose(self) -> None:
        await self._client.aclose()

    async def get_json(self, url: str, params: dict[str, str]) -> dict[str, Any]:
        # 503 is the documented MusicBrainz response on exceeding the rate limit,
        # not a service outage. They track rate by source IP, and we egress via
        # a shared proxy — measurement on prod gave 3 failures out of 6 even
        # with 1s pause between requests.
        # Therefore 3 attempts, not 2: with 1 retry half of the searches returned
        # empty. Pause comes from their Retry-After header when present (now
        # zero — "retry immediately"), otherwise own pause.
        for attempt in range(ATTEMPTS):
            async with self._lock:
                wait = self._min_interval - (time.monotonic() - self._last)
                if wait > 0:
                    await asyncio.sleep(wait)
                response = await self._client.get(url, params=params)
                self._last = time.monotonic()
            if response.status_code == 503 and attempt < ATTEMPTS - 1:
                await asyncio.sleep(_retry_after(response, self._min_interval))
                continue
            break
        response.raise_for_status()
        return dict(response.json())


class MusicBrainzClient:
    def __init__(self, *, http: HttpJson, cache: MetadataCache) -> None:
        self._http = http
        self._cache = cache

    async def search_recordings(self, query: str) -> dict[str, Any]:
        cache_key = f"mb:{query.casefold().strip()}"
        cached = await self._cache.get(cache_key)
        if cached is not None:
            return cached
        payload = await self._http.get_json(
            MB_RECORDING_URL,
            {"query": query, "fmt": "json"},
        )
        await self._cache.set(cache_key, payload)
        return payload


_LUCENE_SPECIAL = r'+-&|!(){}[]^"~*?:\\/'


def lucene_escape(value: str) -> str:
    """Escape Lucene special characters.

    Without this, "AC/DC" or "Blink-182" break query syntax, and MusicBrainz
    responds with an error instead of results.
    """
    out: list[str] = []
    for char in value:
        if char in _LUCENE_SPECIAL:
            out.append("\\")
        out.append(char)
    return "".join(out)


def fielded_query(text: str) -> str:
    """Query where every word must match in at least one of the fields.

    MusicBrainz unfielded full-text ranks poorly: for "slipknot duality" out of
    5625 matches, the original is not even in the top 25, because covers have the
    band name right in the recording title, generating more matches.

    Previously this used `artist:(entire query) AND recording:(entire query)`,
    meaning every word was searched in both fields simultaneously. That requirement
    was superfluous and skewed results: measurement on Sep 18, 2026 for "pink floyd time"
    gave 1473 matches topped by "Pink Floyd Rehearsal", "Floyd's Blues", and interviews.
    They have the band name in both artist and title, thus accumulating more matches
    than the real "Time", which only has the word "time" in the title. The song itself
    was absent from top 25 and top 100 — meaning it could not be found at all.

    Splitting words across fields removes this asymmetry: 383 matches with
    "Pink Floyd — Time" as the first result. On queries that already worked
    ("metallica enter sandman", "slipknot duality", "ac dc thunderstruck",
    "metallica nothing else matters", "nirvana smells like teen spirit"),
    the top result did not change.
    """
    words = [word for word in text.split() if word]
    if not words:
        return lucene_escape(text)
    return " AND ".join(
        f"(artist:{lucene_escape(word)} OR recording:{lucene_escape(word)})" for word in words
    )


def _artist_of(recording: dict[str, Any]) -> str:
    credits = recording.get("artist-credit") or []
    parts: list[str] = []
    for credit in credits:
        if isinstance(credit, str):
            parts.append(credit)
            continue
        name = credit.get("name") or (credit.get("artist") or {}).get("name") or ""
        parts.append(str(name))
        parts.append(str(credit.get("joinphrase") or ""))
    return "".join(parts).strip()


def recording_to_track(recording: dict[str, Any]) -> dict[str, Any] | None:
    """MusicBrainz recording → track in our catalog.

    Only core fields (CC0) are used. Artwork is not populated: Cover Art Archive
    images remain with rights holders, and the client shows its neutral placeholder.
    """
    mbid = str(recording.get("id") or "")
    title = str(recording.get("title") or "").strip()
    artist = _artist_of(recording)
    if not mbid or not title or not artist:
        return None
    length = recording.get("length")
    return {
        "id": mbid,
        "title": title,
        "artist": artist,
        "duration_ms": int(length) if isinstance(length, (int, float)) else 0,
        "artwork_url": "",
    }



def is_derivative(track: dict[str, Any]) -> bool:
    """Cover, tribute, live or remix — not the recording being searched for."""
    blob = set(fold_query(f"{track['artist']} {track['title']}").split())
    return any(word in blob for word in DERIVATIVE_WORDS)



def rank_key(
    query: str, track: dict[str, Any], mb_score: int
) -> tuple[int, float, int, int, int, int]:
    """MusicBrainz result sorting key, descending.

    MusicBrainz's native relevance on free-form query is mostly useless:
    for "metallica nothing else matters" it ranks covers first, because a cover
    has the original band name in the recording title, getting more matches
    than the original.

    First coverage: how many query words matched at all. Then `split` —
    did words split between artist and title. It is `split` that distinguishes
    original from cover at equal coverage: the original has the band name in
    the artist field, the cover has it in the title with a third-party artist.

    Order of these two matters. Reversed, "smells like teen spirit" loses:
    "Teen Daze — Spirit" had words split across fields (split=1) at coverage 0.5,
    beating Nirvana with full coverage but zero split.
    """
    wanted = {token for token in fold_query(query).split() if token}
    artist = {token for token in fold_query(str(track["artist"])).split() if token}
    title = {token for token in fold_query(str(track["title"])).split() if token}
    if not wanted:
        return (0, 0.0, 0, 0, 0, mb_score)
    in_artist = wanted & artist
    in_title = wanted & title
    split = 1 if in_artist and in_title else 0
    coverage = len(in_artist | in_title) / len(wanted)
    # Artist is exactly the requested one, without extra names. Thus "Portishead —
    # Glory Box" beats "Portishead + Epigones — Toy Box (Glory Box remixed by
    # Portishead)": the remix also has full coverage, but includes artists
    # not in the query.
    exact_artist = 1 if artist and artist <= wanted else 0
    # Extra words in title are almost always decorative fluff over the wanted track:
    # "(edit)", "(single version)", mashup "Around the World vs. Bust a Move".
    # All else equal, the simplest version wins.
    extras = -len(title - wanted)
    return (
        0 if is_derivative(track) else 1,
        round(coverage, 3),
        exact_artist,
        extras,
        split,
        mb_score,
    )


class MusicBrainzCatalog:
    """Catalog search on top of MusicBrainz."""

    def __init__(
        self, client: MusicBrainzClient, *, database_url: str | None = None
    ) -> None:
        self._client = client
        self.database_url = database_url

    @property
    def http(self) -> HttpJson:
        """Same client with 1-second pause — page catalog uses it too."""
        return self._client._http

    def _scored(
        self, text: str, payload: dict[str, Any]
    ) -> list[tuple[tuple[int, float, int, int, int, int], dict[str, Any]]]:
        rows: list[tuple[tuple[int, float, int, int, int, int], dict[str, Any]]] = []
        for recording in payload.get("recordings") or []:
            if not isinstance(recording, dict):
                continue
            track = recording_to_track(recording)
            # Without duration, matcher cannot distinguish wanted recording from
            # a namesake, and emitting such a track promises audio that will not exist.
            if track is None or track["duration_ms"] <= 0:
                continue
            raw_score = recording.get("score")
            mb_score = int(raw_score) if isinstance(raw_score, (int, float)) else 0
            rows.append((rank_key(text, track, mb_score), track))
        return rows

    async def search(self, query: str, limit: int) -> list[dict[str, Any]]:
        text = query.strip()
        if not text:
            return []
        if self.database_url:
            import asyncpg
            published = False
            try:
                conn = await asyncpg.connect(self.database_url)
                try:
                    published = bool(await conn.fetchval("SELECT EXISTS (SELECT 1 FROM mb_loads)"))
                finally:
                    if not published:
                        await conn.close()
            except Exception:
                published = False
            if published:
                try:
                    from app import local_search
                    results = await local_search.search(conn, text, limit=limit)
                    return [
                        {
                            "id": str(r["id"]),
                            "title": str(r["title"]),
                            "artist": str(r["artist"]),
                            "duration_ms": int(r["duration_ms"]),
                            "artwork_url": "",
                        }
                        for r in results
                        if r.get("id") and int(r.get("duration_ms") or 0) > 0
                    ]
                finally:
                    await conn.close()
        rows = self._scored(text, await self._client.search_recordings(fielded_query(text)))
        if not rows or max(row[0][1] for row in rows) < 1.0:
            # Strict query requires every word, so it yields nothing where
            # spelling differs from MusicBrainz: typos, different punctuation casing,
            # "AC/DC" vs "ac dc". Empty or incomplete result is not "no such song",
            # and returning empty is unacceptable. Free text covers these cases, so we
            # fetch both and rank them together.
            rows.extend(self._scored(text, await self._client.search_recordings(text)))
        seen: set[str] = set()
        unique: list[tuple[tuple[int, float, int, int, int, int], dict[str, Any]]] = []
        for key, track in sorted(rows, key=lambda row: row[0], reverse=True):
            if track["id"] in seen:
                continue
            seen.add(track["id"])
            unique.append((key, track))
        return [track for _key, track in unique[:limit]]


def exact_artist(payload: dict[str, Any], key: str) -> dict[str, Any] | None:
    """MusicBrainz artist with this exact name (`key` is `norm(name)`).

    Precision is more important than score match: "Kino" by free match includes
    "Kant Kino" and "Kino Oko". First namesake with the matching name is taken,
    and MusicBrainz output is already sorted by score.

    Rule lives here, not on the artist page: nightly image robot (`app/images.py`)
    uses the same rule, and they must not drift apart.
    """
    for artist in payload.get("artists") or []:
        names = [artist.get("name"), artist.get("sort-name")]
        names += [alias.get("name") for alias in artist.get("aliases") or []]
        if any(norm(str(item or "")) == key for item in names):
            return {"id": str(artist["id"]), "name": str(artist["name"])}
    return None


def studio_groups(groups: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Studio albums and EPs: without compilations, concerts, remixes."""
    return [
        group
        for group in groups
        if group.get("primary-type") in ("Album", "EP") and not group.get("secondary-types")
    ]


def http_from_env(env: dict[str, str]) -> ThrottledHttpJson:
    """MusicBrainz client from environment: contact and proxy if set."""
    return ThrottledHttpJson(
        contact=str(env.get("MUSICBRAINZ_CONTACT") or "").strip() or DEFAULT_CONTACT,
        proxy=str(env.get("MUSICBRAINZ_PROXY", "") or "").strip() or None,
    )


def catalog_from_env(env: dict[str, str]) -> MusicBrainzCatalog | None:
    if env.get("MUSICBRAINZ_ENABLED", "").strip() not in {"1", "true", "yes"}:
        return None
    return MusicBrainzCatalog(
        MusicBrainzClient(http=http_from_env(env), cache=MetadataCache()),
        database_url=env.get("DATABASE_URL", "").strip() or None,
    )
