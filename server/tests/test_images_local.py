"""FT-542: cover worker fetches artist and albums from its own MusicBrainz replica.

Prior to FT-542 the worker queried online MusicBrainz twice or more for each
artist: "who is this" and "what are their albums" — each with a 1-second pause through
the shared proxy. In a week in production this accumulated to 1.7k covers per day, even though
its own MusicBrainz replica (42 GB) sits nearby and knows both. Now
the worker goes outside only for the image itself (and artist photo).
Owner decision — Р-A65.
"""

from __future__ import annotations

import asyncio
from pathlib import Path

from fakes import FakeWeb, photo_routes, pictures
from test_catalog_browse import ARTIST, JPEG, LOW_TIDE, PAPER
from test_images import _alone, _rows, built  # noqa: F401 — fixture

DEAD = "0e0f1a9c-5f2c-4b4f-9d44-3a1d2f7a0003"  # Winter Keys: no live release


def test_robot_asks_its_own_copy_not_musicbrainz_online(built: str, tmp_path: Path) -> None:  # noqa: F811
    _alone(built, "glass harbor")
    # Online MusicBrainz for artist and album lookup does not respond:
    # 503 would halt the worker on the very first artist.
    web = FakeWeb(
        {
            "/ws/2/artist?": 503,
            "/ws/2/release-group?": 503,
            "coverartarchive.org": JPEG,
            **photo_routes(ARTIST, JPEG),
        }
    )
    shelf = pictures(tmp_path, built, web, limit=1)
    done, covers = shelf.crawl()
    shelf.queue.join()
    assert not [url for url in web.asked if "/ws/2/artist?" in url or "/ws/2/release-group" in url], (
        "worker queried online MusicBrainz even though own replica is loaded"
    )
    assert done == 1
    kept = asyncio.run(_rows(built, "SELECT album_id FROM album_images WHERE path IS NOT NULL"))
    kept_ids = {str(row["album_id"]) for row in kept}
    assert {LOW_TIDE, PAPER} <= kept_ids, "album covers from own replica were not fetched"
    assert DEAD not in kept_ids
    assert not any(DEAD in url for url in web.asked), "worker requested cover for album without release"
    assert covers == len(kept_ids)


def test_without_own_copy_the_robot_still_asks_online(built: str, tmp_path: Path) -> None:  # noqa: F811
    # Replica not loaded (new user on day one) — previous path
    # through online MusicBrainz remains.
    _alone(built, "glass harbor")
    asyncio.run(_rows(built, "DELETE FROM mb_loads"))
    web = FakeWeb(
        {
            "/ws/2/artist?": {"artists": [{"id": ARTIST, "name": "Glass Harbor"}]},
            "/ws/2/release-group?": {
                "release-group-count": 1,
                "release-groups": [
                    {"id": LOW_TIDE, "title": "Low Tide", "primary-type": "Album", "secondary-types": []},
                ],
            },
            "coverartarchive.org": JPEG,
            **photo_routes(ARTIST, JPEG),
        }
    )
    shelf = pictures(tmp_path, built, web, limit=1)
    assert shelf.crawl() == (1, 1)
    shelf.queue.join()
    assert any("/ws/2/release-group?" in url for url in web.asked)
