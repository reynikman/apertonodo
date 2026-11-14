"""FT-654 (Р-A93, block B-5): podcast feed parsing.

The news feed (`app/news_rss.py`) extracts text and an image from RSS. A podcast needs
different data: each episode has an audio URL (`<enclosure>`), duration, and an ID
(`guid`) used to track playback progress. Feeds are authored by arbitrary third parties,
so parsing must never crash and must not allow URLs that the server should not access.

Contract of the `app/podcast_feed.py` module:
- `parse_podcast(raw: bytes) -> Podcast | None` — `None` if not an RSS feed
  with a title; never raises exceptions outwardly;
- `Podcast(title, author, description, image, link, episodes)`;
- `Episode(guid, title, description, audio_url, audio_type, audio_bytes,
  duration_ms, published, image, season, number, explicit)`;
- `parse_duration(raw: str) -> int | None` — milliseconds;
- constants `MAX_EPISODES = 2000`, `MAX_TITLE = 500`.
"""

from __future__ import annotations

import dataclasses
from datetime import datetime, timedelta, timezone

import pytest

from app import podcast_feed
from app.podcast_feed import Episode, Podcast, parse_duration, parse_podcast

ITUNES = 'xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"'
CONTENT = 'xmlns:content="http://purl.org/rss/1.0/modules/content/"'


def item(
    title: str = "Выпуск",
    *,
    guid: str | None = "g1",
    url: str | None = "https://cdn.example.org/a/ep1.mp3",
    mime: str | None = "audio/mpeg",
    length: str | None = "1234567",
    extra: str = "",
) -> str:
    enclosure = ""
    if url is not None:
        attrs = f'url="{url}"'
        if mime is not None:
            attrs += f' type="{mime}"'
        if length is not None:
            attrs += f' length="{length}"'
        enclosure = f"<enclosure {attrs}/>"
    guid_tag = f"<guid>{guid}</guid>" if guid is not None else ""
    return f"<item><title>{title}</title>{guid_tag}{enclosure}{extra}</item>"


def feed(*items: str, head: str = "<title>Подкаст</title>") -> bytes:
    body = "".join(items)
    return (
        f'<?xml version="1.0" encoding="UTF-8"?><rss version="2.0" {ITUNES} {CONTENT}>'
        f"<channel>{head}{body}</channel></rss>"
    ).encode()


def only(raw: bytes) -> Episode:
    podcast = parse_podcast(raw)
    assert podcast is not None
    assert len(podcast.episodes) == 1
    return podcast.episodes[0]


def episodes(raw: bytes) -> list[Episode]:
    podcast = parse_podcast(raw)
    assert podcast is not None
    return podcast.episodes


# --- podcast itself -----------------------------------------------------------


def test_channel_fields() -> None:
    head = (
        "<title> Мой подкаст </title><link>https://pod.example.org/</link>"
        "<description>&lt;p&gt;Про &lt;b&gt;музыку&lt;/b&gt;&lt;/p&gt;</description>"
        "<itunes:author> Автор </itunes:author>"
        '<itunes:image href="https://pod.example.org/cover.jpg"/>'
    )
    podcast = parse_podcast(feed(item(), head=head))
    assert podcast is not None
    assert podcast.title == "Мой подкаст"
    assert podcast.author == "Автор"
    assert podcast.link == "https://pod.example.org/"
    assert podcast.image == "https://pod.example.org/cover.jpg"
    assert "музыку" in podcast.description
    assert "<" not in podcast.description


def test_channel_image_falls_back_to_rss_image() -> None:
    head = "<title>П</title><image><url>https://pod.example.org/rss.png</url></image>"
    podcast = parse_podcast(feed(item(), head=head))
    assert podcast is not None
    assert podcast.image == "https://pod.example.org/rss.png"


def test_channel_description_falls_back_to_itunes_summary() -> None:
    head = "<title>П</title><itunes:summary>Кратко</itunes:summary>"
    podcast = parse_podcast(feed(item(), head=head))
    assert podcast is not None
    assert podcast.description == "Кратко"


def test_feed_without_episodes_is_still_a_podcast() -> None:
    podcast = parse_podcast(feed())
    assert podcast == Podcast(
        title="Подкаст", author="", description="", image=None, link=None, episodes=[]
    )


@pytest.mark.parametrize(
    "raw",
    [
        b"",
        b"not xml at all",
        b"<html><body>404</body></html>",
        b'<feed xmlns="http://www.w3.org/2005/Atom"><title>Atom</title></feed>',
        b"<rss><nochannel/></rss>",
        b"<rss><channel><item><title>x</title></item></channel></rss>",
        b"<rss><channel><title>   </title></channel></rss>",
        b"<rss><channel><title>broken",
    ],
)
def test_not_a_podcast_is_none(raw: bytes) -> None:
    assert parse_podcast(raw) is None


def test_entity_declarations_are_refused() -> None:
    bomb = (
        b'<?xml version="1.0"?><!DOCTYPE rss [<!ENTITY a "aaaaaaaaaa">'
        b'<!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;">]>'
        b"<rss><channel><title>&b;</title></channel></rss>"
    )
    assert parse_podcast(bomb) is None


def test_channel_title_is_cut() -> None:
    podcast = parse_podcast(feed(head=f"<title>{'я' * 900}</title>"))
    assert podcast is not None
    assert podcast.title == "я" * podcast_feed.MAX_TITLE == "я" * 500


@pytest.mark.parametrize(
    "link",
    [
        "javascript:alert(1)",
        "ftp://pod.example.org/",
        "/relative",
        "https://u:p@x.org/",
    ],
)
def test_channel_link_and_image_only_http(link: str) -> None:
    head = f'<title>П</title><link>{link}</link><itunes:image href="{link}"/>'
    podcast = parse_podcast(feed(head=head))
    assert podcast is not None
    assert podcast.link is None
    assert podcast.image is None


# --- episode ------------------------------------------------------------------


def test_episode_fields() -> None:
    extra = (
        "<pubDate>Mon, 05 Oct 2026 10:00:00 +0300</pubDate>"
        "<description>&lt;p&gt;Гость &amp;amp; ведущий&lt;/p&gt;</description>"
        "<itunes:duration>01:02:03</itunes:duration>"
        "<itunes:season>2</itunes:season><itunes:episode>17</itunes:episode>"
        "<itunes:explicit>yes</itunes:explicit>"
        '<itunes:image href="https://cdn.example.org/ep.jpg"/>'
    )
    episode = only(feed(item(" Первый ", guid=" abc-1 ", extra=extra)))
    assert episode.guid == "abc-1"
    assert episode.title == "Первый"
    assert episode.audio_url == "https://cdn.example.org/a/ep1.mp3"
    assert episode.audio_type == "audio/mpeg"
    assert episode.audio_bytes == 1234567
    assert episode.duration_ms == 3723000
    assert episode.published == datetime(2026, 10, 5, 7, 0, tzinfo=timezone.utc)
    assert episode.published.tzinfo is not None
    assert episode.image == "https://cdn.example.org/ep.jpg"
    assert episode.season == 2
    assert episode.number == 17
    assert episode.explicit is True
    assert "Гость" in episode.description and "<" not in episode.description


def test_episode_defaults() -> None:
    episode = only(feed(item(mime=None, length=None)))
    assert dataclasses.asdict(episode) == {
        "guid": "g1",
        "title": "Выпуск",
        "description": "",
        "audio_url": "https://cdn.example.org/a/ep1.mp3",
        "audio_type": None,
        "audio_bytes": None,
        "duration_ms": None,
        "published": None,
        "image": None,
        "season": None,
        "number": None,
        "explicit": False,
    }


def test_guid_missing_or_blank_is_audio_url() -> None:
    assert only(feed(item(guid=None))).guid == "https://cdn.example.org/a/ep1.mp3"
    assert only(feed(item(guid="   "))).guid == "https://cdn.example.org/a/ep1.mp3"


def test_duplicate_guid_keeps_first() -> None:
    got = episodes(feed(item("Первый", guid="same"), item("Второй", guid="same")))
    assert [e.title for e in got] == ["Первый"]


def test_item_without_title_is_skipped_but_itunes_title_counts() -> None:
    blank = "<item><title> </title><guid>a</guid><enclosure url='https://x.org/a.mp3'/></item>"
    named = (
        "<item><itunes:title>Из iTunes</itunes:title><guid>b</guid>"
        "<enclosure url='https://x.org/b.mp3'/></item>"
    )
    got = episodes(feed(blank, named))
    assert [e.title for e in got] == ["Из iTunes"]


def test_episode_title_is_cut() -> None:
    assert only(feed(item("э" * 900))).title == "э" * 500


def test_description_prefers_full_text_and_is_bounded() -> None:
    extra = (
        "<itunes:summary>коротко</itunes:summary><description>средне</description>"
        "<content:encoded>&lt;p&gt;полный текст&lt;/p&gt;</content:encoded>"
    )
    assert only(feed(item(extra=extra))).description == "полный текст"
    extra = "<description> </description><itunes:summary>коротко</itunes:summary>"
    assert only(feed(item(extra=extra))).description == "коротко"
    long = only(feed(item(extra=f"<description>{'д' * 9000}</description>")))
    assert 0 < len(long.description) <= 4000


# --- audio --------------------------------------------------------------------


def test_item_without_enclosure_is_skipped() -> None:
    assert episodes(feed(item(url=None))) == []


@pytest.mark.parametrize("mime", ["video/mp4", "image/jpeg", "text/html", "VIDEO/MP4"])
def test_not_audio_enclosure_is_skipped_even_with_audio_extension(mime: str) -> None:
    assert episodes(feed(item(mime=mime))) == []


@pytest.mark.parametrize(
    "url",
    [
        "https://x.org/ep.MP3",
        "https://x.org/ep.m4a?token=1",
        "https://x.org/ep.opus",
        "https://x.org/ep.ogg",
        "https://x.org/ep.flac",
    ],
)
@pytest.mark.parametrize("mime", [None, "", "application/octet-stream"])
def test_unknown_type_is_judged_by_extension(url: str, mime: str | None) -> None:
    episode = only(feed(item(url=url, mime=mime)))
    assert episode.audio_url == url
    assert episode.audio_type is None


@pytest.mark.parametrize(
    "url",
    ["https://x.org/ep.mp4", "https://x.org/download?file=ep.mp3", "https://x.org/ep"],
)
def test_unknown_type_without_audio_extension_is_skipped(url: str) -> None:
    assert episodes(feed(item(url=url, mime=None))) == []


def test_audio_type_decides_without_extension() -> None:
    episode = only(feed(item(url="https://x.org/stream/123", mime=" Audio/MP4 ")))
    assert episode.audio_type == "audio/mp4"


@pytest.mark.parametrize(
    "url",
    [
        "file:///etc/passwd",
        "ftp://x.org/ep.mp3",
        "//x.org/ep.mp3",
        "/ep.mp3",
        "javascript:alert(1)//.mp3",
        "https:///ep.mp3",
        "https://user:pass@x.org/ep.mp3",
        "",
    ],
)
def test_audio_url_only_plain_http(url: str) -> None:
    assert episodes(feed(item(url=url))) == []


def test_first_audio_enclosure_wins_over_video() -> None:
    raw = feed(
        "<item><title>Два файла</title><guid>g</guid>"
        '<enclosure url="https://x.org/v.mp4" type="video/mp4"/>'
        '<enclosure url="https://x.org/a.mp3" type="audio/mpeg" length="10"/>'
        '<enclosure url="https://x.org/b.mp3" type="audio/mpeg" length="20"/>'
        "</item>"
    )
    episode = only(raw)
    assert episode.audio_url == "https://x.org/a.mp3"
    assert episode.audio_bytes == 10


@pytest.mark.parametrize("length", ["0", "-5", "abc", "", "12.5", "１２３", "9" * 30])
def test_bad_length_is_unknown(length: str) -> None:
    assert only(feed(item(length=length))).audio_bytes is None


# --- duration -----------------------------------------------------------------


@pytest.mark.parametrize(
    ("raw", "ms"),
    [
        ("90", 90_000),
        ("1:30", 90_000),
        ("01:30", 90_000),
        ("1:00:00", 3_600_000),
        ("0:00:07", 7_000),
        ("100:00", 6_000_000),
        ("1234.5", 1_234_500),
        (" 45 ", 45_000),
        ("48:00:00", 172_800_000),
    ],
)
def test_duration_forms(raw: str, ms: int) -> None:
    assert parse_duration(raw) == ms


@pytest.mark.parametrize(
    "raw",
    [
        "",
        "0",
        "0:00",
        "-5",
        "abc",
        "1:2:3:4",
        "0:1:2:3",
        "1:75",
        "1:60:00",
        ":30",
        "30:",
        "1h30m",
        "１２３",
        "48:00:01",
        "9" * 12,
        "1e5",
        "nan",
        "inf",
    ],
)
def test_bad_duration_is_unknown(raw: str) -> None:
    assert parse_duration(raw) is None


def test_duration_in_feed() -> None:
    extra = "<itunes:duration>25:10</itunes:duration>"
    assert only(feed(item(extra=extra))).duration_ms == 1_510_000
    assert (
        only(feed(item(extra="<itunes:duration>скоро</itunes:duration>"))).duration_ms
        is None
    )


# --- other fields -------------------------------------------------------------


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("yes", True),
        ("TRUE", True),
        ("explicit", True),
        ("no", False),
        ("clean", False),
        ("", False),
    ],
)
def test_explicit(raw: str, expected: bool) -> None:
    extra = f"<itunes:explicit>{raw}</itunes:explicit>"
    assert only(feed(item(extra=extra))).explicit is expected


@pytest.mark.parametrize("raw", ["0", "-1", "x", "1.5", ""])
def test_bad_season_and_number_are_unknown(raw: str) -> None:
    extra = (
        f"<itunes:season>{raw}</itunes:season><itunes:episode>{raw}</itunes:episode>"
    )
    episode = only(feed(item(extra=extra)))
    assert episode.season is None
    assert episode.number is None


def test_bad_date_is_unknown_and_date_without_zone_is_utc() -> None:
    assert only(feed(item(extra="<pubDate>вчера</pubDate>"))).published is None
    got = only(feed(item(extra="<pubDate>2026-10-05T10:00:00</pubDate>"))).published
    assert got == datetime(2026, 10, 5, 10, 0, tzinfo=timezone.utc)


def test_episode_image_only_http() -> None:
    extra = '<itunes:image href="data:image/png;base64,AAAA"/>'
    assert only(feed(item(extra=extra))).image is None


# --- order and volume ---------------------------------------------------------


def test_newest_first_undated_last_in_feed_order() -> None:
    def dated(guid: str, day: int) -> str:
        return item(
            guid, guid=guid, extra=f"<pubDate>2026-10-{day:02d}T00:00:00Z</pubDate>"
        )

    raw = feed(
        item("u1", guid="u1"),
        dated("d3", 3),
        dated("d9", 9),
        item("u2", guid="u2"),
        dated("d5", 5),
    )
    assert [e.guid for e in episodes(raw)] == ["d9", "d5", "d3", "u1", "u2"]


def test_same_date_keeps_feed_order() -> None:
    extra = "<pubDate>2026-10-05T00:00:00Z</pubDate>"
    raw = feed(*(item(g, guid=g, extra=extra) for g in ("a", "b", "c")))
    assert [e.guid for e in episodes(raw)] == ["a", "b", "c"]


def test_only_the_newest_episodes_are_kept() -> None:
    start = datetime(2020, 1, 1, tzinfo=timezone.utc)
    items = [
        item(
            f"e{n}",
            guid=f"e{n}",
            url=f"https://x.org/{n}.mp3",
            extra=f"<pubDate>{(start + timedelta(days=n)).isoformat()}</pubDate>",
        )
        for n in range(2100)
    ]
    got = episodes(feed(*items))
    assert len(got) == podcast_feed.MAX_EPISODES == 2000
    assert got[0].guid == "e2099"
    assert got[-1].guid == "e100"


def test_one_broken_item_does_not_lose_the_rest(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    real = podcast_feed._parse_date

    def flaky(value: str | None):  # noqa: ANN202
        if value and "boom" in value:
            raise RuntimeError("boom")
        return real(value)

    monkeypatch.setattr(podcast_feed, "_parse_date", flaky)
    raw = feed(
        item("плохой", guid="bad", extra="<pubDate>boom</pubDate>"),
        item("хороший", guid="ok"),
    )
    assert [e.guid for e in episodes(raw)] == ["ok"]


def test_items_outside_channel_are_ignored() -> None:
    raw = (
        f"<rss {ITUNES}><channel><title>П</title></channel>"
        '<item><title>чужой</title><enclosure url="https://x.org/a.mp3"/></item></rss>'
    ).encode()
    assert episodes(raw) == []


def test_values_are_plain_and_frozen() -> None:
    episode = only(feed(item()))
    with pytest.raises(dataclasses.FrozenInstanceError):
        episode.title = "x"  # type: ignore[misc]
    podcast = parse_podcast(feed(item()))
    assert podcast is not None
    with pytest.raises(dataclasses.FrozenInstanceError):
        podcast.title = "x"  # type: ignore[misc]


def test_module_does_no_io() -> None:
    source = open(podcast_feed.__file__, encoding="utf-8").read()
    for word in (
        "httpx",
        "requests",
        "urllib.request",
        "socket",
        "open(",
        "logging",
        "print(",
    ):
        assert word not in source, word


# --- added by lead during review (second look, FT-654) ---

MEDIA = 'xmlns:media="http://search.yahoo.com/mrss/"'
ATOM = 'xmlns:atom="http://www.w3.org/2005/Atom"'


def wide(body: str) -> bytes:
    return (
        f'<?xml version="1.0"?><rss version="2.0" {ITUNES} {MEDIA} {ATOM}>'
        f"<channel>{body}</channel></rss>"
    ).encode()


@pytest.mark.parametrize("encoding", ["utf-16", "utf-16-le", "utf-16-be", "utf-8"])
def test_entity_declaration_is_refused_in_any_encoding(encoding: str) -> None:
    # Byte search for "<!ENTITY" is blind to UTF-16: there are null bytes between characters.
    text = (
        f'<?xml version="1.0" encoding="{encoding.upper()[:6]}"?>'
        '<!DOCTYPE rss [<!ENTITY a "aaaaaaaaaa">]>'
        "<rss><channel><title>T&a;</title></channel></rss>"
    )
    bom = "﻿" if encoding in ("utf-16-le", "utf-16-be") else ""
    assert parse_podcast((bom + text).encode(encoding)) is None


def test_doctype_without_entities_is_fine() -> None:
    raw = b'<?xml version="1.0"?><!DOCTYPE rss><rss><channel><title>T</title></channel></rss>'
    assert parse_podcast(raw) is not None


def test_channel_link_is_the_site_not_the_feed_itself() -> None:
    podcast = parse_podcast(
        wide(
            "<title>T</title>"
            '<atom:link rel="self" href="https://feeds.example.org/rss"/>'
            "<link>https://site.example.org</link>"
        )
    )
    assert podcast is not None
    assert podcast.link == "https://site.example.org"
    alone = parse_podcast(
        wide(
            '<title>T</title><atom:link rel="self" href="https://feeds.example.org/rss"/>'
        )
    )
    assert alone is not None
    assert alone.link is None


@pytest.mark.parametrize(
    "url",
    [
        "https://cdn.example.org/a b.mp3",
        "https://cdn.exa mple.org/a.mp3",
        "https://cdn.example.org/a&#9;b.mp3",
        "https://cdn.example.org/a b.mp3",
        "https://cdn.example.org/‮b.mp3",
        "https://cdn.example.org:99999/a.mp3",
        "https://cdn.example.org:port/a.mp3",
        "https://cdn.example.org/" + "a" * 2100 + ".mp3",
    ],
)
def test_audio_url_with_blanks_bad_port_or_huge_is_refused(url: str) -> None:
    assert episodes(feed(item(url=url))) == []


def test_link_and_image_with_a_line_break_inside_are_refused() -> None:
    podcast = parse_podcast(
        feed(
            head="<title>T</title><link>https://site.example.org/a&#10;b</link>"
            '<itunes:image href="https://cdn.example.org/i&#10;.png"/>'
            "<image><url>https://cdn.example.org/i&#10;2.png</url></image>"
        )
    )
    assert podcast is not None
    assert podcast.link is None
    assert podcast.image is None


@pytest.mark.parametrize("raw", ["9" * 5000, "9" * 400 + ".5", "1" * 5000 + ":00"])
def test_endless_duration_is_unknown_not_an_error(raw: str) -> None:
    assert parse_duration(raw) is None
    episode = only(feed(item(extra=f"<itunes:duration>{raw}</itunes:duration>")))
    assert episode.duration_ms is None


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("Best of R&amp;B", "Best of R&B"),
        (
            "см. https://x.example.org/?a=1&amp;b=2",
            "см. https://x.example.org/?a=1&b=2",
        ),
    ],
)
def test_description_ending_with_an_ampersand_word_is_not_lost(
    text: str, expected: str
) -> None:
    episode = only(feed(item(extra=f"<description>{text}</description>")))
    assert episode.description == expected
    podcast = parse_podcast(
        feed(head=f"<title>T</title><description>{text}</description>")
    )
    assert podcast is not None
    assert podcast.description == expected


def test_titles_of_other_namespaces_are_not_the_title() -> None:
    podcast = parse_podcast(
        wide(
            "<media:title>Чужое</media:title><title>Подкаст</title>"
            "<item><media:title>Картинка</media:title><title>Выпуск</title>"
            '<enclosure url="https://cdn.example.org/a.mp3" type="audio/mpeg"/></item>'
            "<item><media:title>Только чужое</media:title>"
            '<enclosure url="https://cdn.example.org/b.mp3" type="audio/mpeg"/></item>'
        )
    )
    assert podcast is not None
    assert podcast.title == "Подкаст"
    assert [e.title for e in podcast.episodes] == ["Выпуск"]
    assert parse_podcast(wide("<media:title>Чужое</media:title>")) is None


def test_pub_date_wins_over_atom_dates() -> None:
    episode = only(
        wide(
            "<title>T</title><item><title>a</title>"
            "<atom:updated>2020-01-01T00:00:00Z</atom:updated>"
            "<pubDate>Mon, 05 Oct 2026 10:00:00 +0000</pubDate>"
            '<enclosure url="https://cdn.example.org/a.mp3" type="audio/mpeg"/></item>'
        )
    )
    assert episode.published == datetime(2026, 10, 5, 10, tzinfo=timezone.utc)


def test_sizes_are_bounded() -> None:
    episode = only(
        feed(
            item(
                guid="g" * 1001,
                mime="audio/" + "x" * 200,
                extra="<itunes:season>100000</itunes:season>"
                "<itunes:episode>99999999999</itunes:episode>",
            ),
            head=f"<title>T</title><itunes:author>{'а' * 600}</itunes:author>",
        )
    )
    assert episode.guid == episode.audio_url
    assert episode.audio_type is None
    assert episode.season is None
    assert episode.number is None
    podcast = parse_podcast(
        feed(head=f"<title>T</title><itunes:author>{'а' * 600}</itunes:author>")
    )
    assert podcast is not None
    assert len(podcast.author) == podcast_feed.MAX_TITLE
    kept = only(feed(item(extra="<itunes:season>99999</itunes:season>")))
    assert kept.season == 99999
