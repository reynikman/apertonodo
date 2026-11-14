"""Second look on FT-866: the artist page keeps its length and does not grey out before the catalog copy loads."""

import asyncio
import json

from app import catalog, lastfm


class FakeConn:
    def __init__(self, copy_loaded: bool):
        self.copy_loaded = copy_loaded

    async def fetchval(self, *args):
        return self.copy_loaded

    async def execute(self, *args):
        return None


def row(titles, ids):
    return {"top_tracks": titles, "top_track_ids": json.dumps(ids)}


def attach(monkeypatch, titles, ids, *, limit=None, copy_loaded=True):
    async def playable(conn, name, top):
        return [True] * len(top)

    monkeypatch.setattr(catalog, "playable", playable)
    return asyncio.run(
        lastfm._attach_top_tracks(
            FakeConn(copy_loaded), "artist", "Artist", row(titles, ids), limit=limit
        )
    )


def test_two_spellings_of_one_song_do_not_shorten_the_page(monkeypatch):
    titles = ["Adagio: 2.", "Adagio: II."] + [f"Song {n}" for n in range(1, 11)]
    ids = {
        "$rule": lastfm.TOP_IDS_RULE,
        lastfm.norm("Adagio: 2."): {"id": "rec-a"},
        lastfm.norm("Adagio: II."): {"id": "rec-a"},
    }
    ids.update({lastfm.norm(f"Song {n}"): {"id": f"rec-{n}"} for n in range(1, 11)})
    tracks = attach(monkeypatch, titles, ids, limit=10)
    assert len(tracks) == 10
    assert [t["id"] for t in tracks].count("rec-a") == 1


def test_songs_are_not_greyed_out_before_numbers_were_ever_looked_up(monkeypatch):
    # No catalog copy yet: numbers could not be looked up, so "no number" says nothing about the song.
    tracks = attach(monkeypatch, ["Song 1", "Song 2"], {}, copy_loaded=False)
    assert [t["playable"] for t in tracks] == [True, True]


def test_song_without_a_number_after_lookup_stays_greyed_out(monkeypatch):
    tracks = attach(monkeypatch, ["Song 1"], {"$rule": lastfm.TOP_IDS_RULE})
    assert tracks[0]["playable"] is False
