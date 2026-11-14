from __future__ import annotations

import asyncio
import json
import time
from pathlib import Path
from typing import Any

import httpx
import pytest
from fastapi.testclient import TestClient

from app.main import create_app
from app.musicbrainz import (
    MetadataCache,
    MusicBrainzCatalog,
    MusicBrainzClient,
    ThrottledHttpJson,
    catalog_from_env,
    recording_to_track,
)

ROOT = Path(__file__).resolve().parents[2]
CATALOG = json.loads((ROOT / "contracts" / "fixtures" / "catalog.json").read_text())["tracks"]
DUALITY_MBID = "b9ad642e-b012-41c7-b1a2-1f5d3a4f5bfe"


def _recording(**overrides: Any) -> dict[str, Any]:
    payload = {
        "id": DUALITY_MBID,
        "title": "Duality",
        "length": 252000,
        "artist-credit": [{"name": "Slipknot"}],
    }
    payload.update(overrides)
    return payload


class _FakeCatalog:
    def __init__(self, tracks: list[dict[str, Any]]) -> None:
        self.tracks = tracks
        self.queries: list[str] = []

    async def search(self, query: str, limit: int) -> list[dict[str, Any]]:
        self.queries.append(query)
        return self.tracks[:limit]


class _BrokenCatalog:
    async def search(self, query: str, limit: int) -> list[dict[str, Any]]:
        raise httpx.ConnectError("indexer down")


def test_recording_maps_to_core_fields_only() -> None:
    track = recording_to_track(_recording())
    assert track == {
        "id": DUALITY_MBID,
        "title": "Duality",
        "artist": "Slipknot",
        "duration_ms": 252000,
        "artwork_url": "",
    }


def test_joinphrase_builds_full_artist_credit() -> None:
    track = recording_to_track(
        _recording(
            **{
                "artist-credit": [
                    {"name": "Slipknot", "joinphrase": " feat. "},
                    {"name": "Corey Taylor"},
                ]
            }
        )
    )
    assert track is not None
    assert track["artist"] == "Slipknot feat. Corey Taylor"


@pytest.mark.parametrize(
    "recording",
    [
        {"title": "Duality", "artist-credit": [{"name": "Slipknot"}]},
        {"id": DUALITY_MBID, "artist-credit": [{"name": "Slipknot"}]},
        {"id": DUALITY_MBID, "title": "Duality"},
    ],
    ids=["no-mbid", "no-title", "no-artist"],
)
def test_incomplete_recording_is_dropped(recording: dict[str, Any]) -> None:
    assert recording_to_track(recording) is None


def test_recording_without_length_never_reaches_search() -> None:
    class Http:
        async def get_json(self, url: str, params: dict[str, str]) -> dict[str, Any]:
            return {"recordings": [_recording(length=None), _recording()]}

    catalog = MusicBrainzCatalog(MusicBrainzClient(http=Http(), cache=MetadataCache()))
    tracks = asyncio.run(catalog.search("duality", 20))
    assert [track["duration_ms"] for track in tracks] == [252000]


def test_live_catalog_results_become_playable() -> None:
    mb_track = {
        "id": DUALITY_MBID,
        "title": "Psychosocial",
        "artist": "Slipknot",
        "duration_ms": 284000,
        "artwork_url": "",
    }
    port = _FakeCatalog([mb_track])
    app = create_app(catalog=CATALOG, catalog_port=port)
    with TestClient(app) as client:
        found = client.get("/v1/search", params={"q": "psychosocial"}).json()["tracks"]
        assert [track["title"] for track in found] == ["Psychosocial"]
        # Track is not in fixture catalog, and playback did not know it before search.
        played = client.post("/v1/playback", json={"track_id": DUALITY_MBID})

    assert port.queries == ["psychosocial"]
    # No source for it, but 404 "track not found" must no longer occur:
    # catalog knows it, only source is missing.
    assert played.status_code == 409
    assert played.json() == {"state": "unresolved"}


def test_unknown_track_is_still_not_found() -> None:
    app = create_app(catalog=CATALOG, catalog_port=_FakeCatalog([]))
    with TestClient(app) as client:
        response = client.post(
            "/v1/playback", json={"track_id": "00000000-0000-0000-0000-000000000000"}
        )
    assert response.status_code == 404


def test_live_record_is_not_shadowed_by_a_fixture_namesake() -> None:
    """Live catalog is enabled — song is served by it, not by fixture with same name.

    Previously it was the opposite, and the test enforced it: fixture "Duality" came
    first, `collapse_tracks` dropped MusicBrainz record, and Play served
    a 4-second test file. For "Nothing Else Matters" the same
    yielded 90 seconds of test tone — owner heard it from the phone.
    """
    live = {
        "id": DUALITY_MBID,
        "title": "Duality",
        "artist": "Slipknot",
        "duration_ms": 252000,
        "artwork_url": "",
    }
    app = create_app(catalog=CATALOG, catalog_port=_FakeCatalog([live]))
    with TestClient(app) as client:
        tracks = client.get("/v1/search", params={"q": "duality slipknot"}).json()["tracks"]

    ids = [track["id"] for track in tracks]
    assert ids == [DUALITY_MBID], ids


def test_test_tones_stay_searchable_next_to_the_live_catalog() -> None:
    """Device checks need audio independent of any source — test tones.

    Named so as not to collide with any real song.
    """
    app = create_app(catalog=CATALOG, catalog_port=_FakeCatalog([]))
    with TestClient(app) as client:
        tracks = client.get("/v1/search", params={"q": "flowtune test tone"}).json()["tracks"]

    assert sorted(track["title"] for track in tracks) == ["Test Tone Long", "Test Tone Short"]


def test_broken_catalog_says_so_instead_of_finding_nothing() -> None:
    """Catalog crash is 503, not empty result.

    Empty result on phone is read as "no such song", although there was
    simply nobody to ask.
    """
    app = create_app(catalog=CATALOG, catalog_port=_BrokenCatalog())
    with TestClient(app) as client:
        response = client.get("/v1/search", params={"q": "duality slipknot"})
        tones = client.get("/v1/search", params={"q": "flowtune test tone"})

    assert response.status_code == 503
    assert response.json() == {"status": "catalog_unavailable"}
    # Local items are still served when matching the query.
    assert tones.status_code == 200
    assert len(tones.json()["tracks"]) == 2


def test_catalog_is_off_unless_the_environment_turns_it_on() -> None:
    assert catalog_from_env({}) is None
    assert catalog_from_env({"MUSICBRAINZ_ENABLED": "0"}) is None
    assert catalog_from_env({"MUSICBRAINZ_ENABLED": "1"}) is not None


def test_http_client_sends_user_agent_and_spaces_requests() -> None:
    seen: list[str] = []
    stamps: list[float] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request.headers.get("user-agent", ""))
        stamps.append(time.monotonic())
        return httpx.Response(200, json={"recordings": []})

    http = ThrottledHttpJson(
        contact="https://example.invalid",
        min_interval_s=0.25,
        client=httpx.AsyncClient(
            transport=httpx.MockTransport(handler),
            headers={"User-Agent": "apertonodo/0.1 ( https://example.invalid )"},
        ),
    )

    async def run() -> None:
        await asyncio.gather(
            http.get_json("https://musicbrainz.invalid/x", {}),
            http.get_json("https://musicbrainz.invalid/y", {}),
        )
        await http.aclose()

    asyncio.run(run())

    assert len(seen) == 2
    assert all("apertonodo/0.1" in agent and "example.invalid" in agent for agent in seen)
    assert stamps[1] - stamps[0] >= 0.25, "MusicBrainz rate limit of one query per second not respected"


def test_search_does_not_log_the_query(caplog: pytest.LogCaptureFixture) -> None:
    app = create_app(catalog=CATALOG, catalog_port=_BrokenCatalog())
    with caplog.at_level("INFO"), TestClient(app) as client:
        client.get("/v1/search", params={"q": "очень личный запрос"})

    assert "очень личный запрос" not in caplog.text


# --- MusicBrainz search ranking ----------------------------------------------
# Cases below are taken from real musicbrainz.org responses, not invented.
# On free-text query "slipknot duality" the service returns 5625 matches, among
# the first 25 there is no original: for covers, band name is in recording title.


def _t(artist: str, title: str) -> dict[str, Any]:
    return {"id": "x", "artist": artist, "title": title, "duration_ms": 1, "artwork_url": ""}


@pytest.mark.parametrize(
    ("query", "winner", "loser", "why"),
    [
        (
            "metallica nothing else matters",
            _t("Metallica", "Nothing Else Matters"),
            _t("Jon Crosby", "Metallica-Nothing Else Matters"),
            "cover puts band name into title",
        ),
        (
            "smells like teen spirit",
            _t("Nirvana", "Smells Like Teen Spirit"),
            _t("Teen Daze", "Spirit"),
            "full coverage matters more than words being split across fields",
        ),
        (
            "slipknot duality",
            _t("Slipknot", "Duality"),
            _t("Slipknot", "Slipknot"),
            "half of query not found",
        ),
        (
            "slipknot duality",
            _t("Slipknot", "Duality"),
            _t("Radio Tapok", "Duality (cover Slipknot)"),
            "cover is discarded by word cover",
        ),
        (
            "кино группа крови",
            _t("Кино", "Группа крови"),
            _t("Денис Майданов", "Группа крови"),
            "wrong artist",
        ),
        (
            "portishead glory box",
            _t("Portishead", "Glory Box"),
            _t("Portishead + Epigones", "Toy Box (Glory Box remixed by Portishead)"),
            "full coverage for both, but remix has extra name in artists",
        ),
    ],
)
def test_original_recording_outranks_the_lookalike(
    query: str, winner: dict[str, Any], loser: dict[str, Any], why: str
) -> None:
    from app.musicbrainz import rank_key

    # We give foreign record max MusicBrainz score, own record — low score.
    assert rank_key(query, winner, 10) > rank_key(query, loser, 100), why


def test_fielded_query_escapes_lucene_syntax() -> None:
    from app.musicbrainz import fielded_query, lucene_escape

    assert lucene_escape("AC/DC") == r"AC\/DC"
    assert lucene_escape("Blink-182") == r"Blink\-182"
    # Without escaping, such query breaks syntax and MusicBrainz returns an error.
    assert fielded_query("AC/DC") == r"(artist:AC\/DC OR recording:AC\/DC)"


def test_fielded_query_does_not_demand_every_word_in_both_fields() -> None:
    """Each word is searched in artist OR in title, not in both at once.

    Query of the form `artist:(pink floyd time) AND recording:(pink floyd time)`
    looks stricter, but in practice surfaces recordings where band name appears
    in both fields: "Pink Floyd Rehearsal", interviews, radio shows. Real
    "Pink Floyd — Time" in such output was neither in top 25 nor top 100.
    """
    from app.musicbrainz import fielded_query

    assert fielded_query("pink floyd") == (
        "(artist:pink OR recording:pink) AND (artist:floyd OR recording:floyd)"
    )


def test_free_text_is_a_fallback_only_when_fielded_misses_words() -> None:
    class Http:
        def __init__(self) -> None:
            self.queries: list[str] = []

        async def get_json(self, url: str, params: dict[str, str]) -> dict[str, Any]:
            self.queries.append(params["query"])
            if "recording:" in params["query"]:
                return {
                    "recordings": [
                        {
                            "id": "full",
                            "title": "Duality",
                            "length": 252000,
                            "score": 100,
                            "artist-credit": [{"name": "Slipknot"}],
                        }
                    ]
                }
            raise AssertionError("free text should not have been needed")

    http = Http()
    catalog = MusicBrainzCatalog(MusicBrainzClient(http=http, cache=MetadataCache()))
    tracks = asyncio.run(catalog.search("slipknot duality", 5))

    assert [track["id"] for track in tracks] == ["full"]
    assert len(http.queries) == 1, "full coverage should not cost a second query"


def test_partial_coverage_triggers_the_free_text_query() -> None:
    class Http:
        def __init__(self) -> None:
            self.queries: list[str] = []

        async def get_json(self, url: str, params: dict[str, str]) -> dict[str, Any]:
            self.queries.append(params["query"])
            if "recording:" in params["query"]:
                # This is what "bohemian rhapsody" looks like without artist: fielded
                # query catches artists named Bohemian and never reaches Queen.
                return {
                    "recordings": [
                        {
                            "id": "wrong",
                            "title": "Bohemian love stories",
                            "length": 610000,
                            "score": 100,
                            "artist-credit": [{"name": "BoHemian"}],
                        }
                    ]
                }
            return {
                "recordings": [
                    {
                        "id": "right",
                        "title": "Bohemian Rhapsody",
                        "length": 354000,
                        "score": 100,
                        "artist-credit": [{"name": "Queen"}],
                    }
                ]
            }

    http = Http()
    catalog = MusicBrainzCatalog(MusicBrainzClient(http=http, cache=MetadataCache()))
    tracks = asyncio.run(catalog.search("bohemian rhapsody", 5))

    assert len(http.queries) == 2
    assert [track["id"] for track in tracks] == ["right", "wrong"]


def test_retries_once_on_musicbrainz_rate_limit() -> None:
    calls: list[int] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(1)
        if len(calls) == 1:
            # Documented MusicBrainz response on rate limiting.
            return httpx.Response(503, text="rate limited")
        return httpx.Response(200, json={"recordings": []})

    http = ThrottledHttpJson(
        min_interval_s=0.01,
        client=httpx.AsyncClient(transport=httpx.MockTransport(handler)),
    )

    async def run() -> dict[str, Any]:
        payload = await http.get_json("https://musicbrainz.invalid/x", {})
        await http.aclose()
        return payload

    assert asyncio.run(run()) == {"recordings": []}
    assert len(calls) == 2


def test_app_logger_is_visible_and_carries_no_query() -> None:
    """Catalog failure should be visible in log, but without query text.

    Without its own entry in uvicorn config, app logger is silent, and empty
    output due to MusicBrainz failure looks identical to "nothing
    found". There would be no way to distinguish them in prod.
    """
    from app.log_config import LOGGING_CONFIG

    assert LOGGING_CONFIG["loggers"]["apertonodo"]["handlers"] == ["default"]
    assert LOGGING_CONFIG["loggers"]["apertonodo"]["propagate"] is False


def test_failed_catalog_logs_the_error_class_only(caplog: pytest.LogCaptureFixture) -> None:
    app = create_app(catalog=CATALOG, catalog_port=_BrokenCatalog())
    with caplog.at_level("WARNING"), TestClient(app) as client:
        client.get("/v1/search", params={"q": "секретный запрос"})

    assert "ConnectError" in caplog.text
    assert "секретный запрос" not in caplog.text
