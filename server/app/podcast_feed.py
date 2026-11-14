"""FT-654 (Р-A93, block B-5): podcast feed parser."""

from __future__ import annotations

import re
import xml.etree.ElementTree as ET
import xml.parsers.expat as expat
from dataclasses import dataclass
from datetime import datetime, timezone
from urllib.parse import urlsplit

from app.news_rss import _clean_html, _parse_date
from app.podcast_lang import language_of

MAX_EPISODES = 2000
MAX_TITLE = 500
MAX_URL = 2048
MAX_GUID = 1000
MAX_AUDIO_TYPE = 100
MAX_NUMBER = 99999

AUDIO_EXTENSIONS = (
    ".mp3",
    ".m4a",
    ".aac",
    ".ogg",
    ".oga",
    ".opus",
    ".flac",
    ".wav",
)


@dataclass(frozen=True)
class Episode:
    guid: str
    title: str
    description: str
    audio_url: str
    audio_type: str | None
    audio_bytes: int | None
    duration_ms: int | None
    published: datetime | None
    image: str | None
    season: int | None
    number: int | None
    explicit: bool


@dataclass(frozen=True)
class Podcast:
    title: str
    author: str
    description: str
    image: str | None
    link: str | None
    episodes: list[Episode]
    language: str | None = None


class _EpisodeSortKey:
    __slots__ = ("idx", "published")

    def __init__(self, published: datetime, idx: int) -> None:
        self.published = published
        self.idx = idx

    def __lt__(self, other: _EpisodeSortKey) -> bool:
        if self.published != other.published:
            return self.published > other.published
        return self.idx < other.idx


def _local(tag: str) -> str:
    return tag.split("}")[-1]


def _namespace(tag: str) -> str:
    return tag[1:].split("}")[0].lower() if tag.startswith("{") else ""


class _EntityDeclared(Exception):
    pass


def _refuse_entity(*_: object) -> None:
    raise _EntityDeclared


def _declares_entities(raw: bytes) -> bool:
    # Byte search for "<!ENTITY" is blind to UTF-16, so the parser itself
    # catches declarations — before the entity has a chance to expand.
    parser = expat.ParserCreate()
    parser.EntityDeclHandler = _refuse_entity
    try:
        parser.Parse(bytes(raw), True)
    except _EntityDeclared:
        return True
    except Exception:
        return False
    return False


def _clean_text(raw_html: str) -> str:
    # Space at the end: without it, `_clean_html` expects a continuation after "&B"
    # and drops the trailing text.
    text, _ = _clean_html(raw_html + " ")
    return text.strip()


def _is_valid_http_url(url: str | None) -> bool:
    if not url or not isinstance(url, str):
        return False
    s = url.strip()
    if not s or len(s) > MAX_URL:
        return False
    if any(ch.isspace() or not ch.isprintable() for ch in s):
        return False
    try:
        parsed = urlsplit(s)
        parsed.port  # noqa: B018 — malformed port raises exception
    except Exception:
        return False
    if parsed.scheme.lower() not in ("http", "https"):
        return False
    if not parsed.hostname:
        return False
    if parsed.username or parsed.password or "@" in parsed.netloc:
        return False
    return True


def _clean_url(url: str | None) -> str | None:
    if not url or not isinstance(url, str):
        return None
    s = url.strip()
    if _is_valid_http_url(s):
        return s
    return None


def _parse_audio_bytes(raw: str | None) -> int | None:
    if not raw or not isinstance(raw, str):
        return None
    s = raw.strip()
    if not s.isascii() or not s.isdigit():
        return None
    try:
        val = int(s)
        if 0 < val < (1 << 53):
            return val
    except Exception:
        pass
    return None


def _parse_positive_int(raw: str | None) -> int | None:
    if not raw or not isinstance(raw, str):
        return None
    s = raw.strip()
    if not s.isascii() or not s.isdigit() or len(s) > 5:
        return None
    try:
        val = int(s)
        if 0 < val <= MAX_NUMBER:
            return val
    except Exception:
        pass
    return None


def _is_valid_enclosure(url: str, mime: str | None) -> tuple[bool, str | None]:
    if not _is_valid_http_url(url):
        return False, None

    mime_clean = "".join(mime.split()).lower() if mime else ""
    if mime_clean.startswith(("video/", "image/", "text/")):
        return False, None

    if mime_clean.startswith("audio/"):
        return True, mime_clean if len(mime_clean) <= MAX_AUDIO_TYPE else None

    try:
        path = urlsplit(url).path.lower()
    except Exception:
        return False, None

    if path.endswith(AUDIO_EXTENSIONS):
        return True, None

    return False, None


def parse_duration(raw: str) -> int | None:
    if not isinstance(raw, str) or not raw.isascii():
        return None
    s = raw.strip()
    if not s or len(s) > 12:
        return None

    max_ms = 48 * 3600 * 1000

    if ":" not in s:
        if s.isdigit():
            val = int(s)
            ms = val * 1000
            if 0 < ms <= max_ms:
                return ms
            return None
        if "." in s:
            dot_parts = s.split(".")
            if (
                len(dot_parts) == 2
                and dot_parts[0].isdigit()
                and dot_parts[1].isdigit()
            ):
                val_float = float(s)
                ms = int(round(val_float * 1000))
                if 0 < ms <= max_ms:
                    return ms
        return None

    parts = s.split(":")
    if len(parts) == 2:
        p0, p1 = parts
        if not (1 <= len(p0) <= 4 and p0.isdigit()):
            return None
        if not (len(p1) == 2 and p1.isdigit() and int(p1) <= 59):
            return None
        total_seconds = int(p0) * 60 + int(p1)
        ms = total_seconds * 1000
        if 0 < ms <= max_ms:
            return ms
        return None

    if len(parts) == 3:
        p0, p1, p2 = parts
        if not (1 <= len(p0) <= 4 and p0.isdigit()):
            return None
        if not (len(p1) == 2 and p1.isdigit() and int(p1) <= 59):
            return None
        if not (len(p2) == 2 and p2.isdigit() and int(p2) <= 59):
            return None
        total_seconds = int(p0) * 3600 + int(p1) * 60 + int(p2)
        ms = total_seconds * 1000
        if 0 < ms <= max_ms:
            return ms
        return None

    return None


def _parse_item(item_elem: ET.Element, seen_guids: set[str]) -> Episode | None:
    item_title = ""
    itunes_title = ""
    guid_raw: str | None = None
    content_encoded = ""
    description_raw = ""
    itunes_summary = ""
    duration_raw = ""
    season_raw = ""
    number_raw = ""
    explicit_raw = ""
    image_raw = ""
    pub_date_raw = ""
    other_date_raw = ""
    enclosures: list[ET.Element] = []

    for child in item_elem:
        ltag = _local(child.tag).lower()
        if ltag == "title":
            namespace = _namespace(child.tag)
            val = (child.text or "").strip()
            if "itunes" in namespace:
                if not itunes_title and val:
                    itunes_title = val
            elif not namespace:
                if not item_title and val:
                    item_title = val
        elif ltag == "guid":
            if guid_raw is None:
                guid_raw = child.text
        elif ltag == "enclosure":
            enclosures.append(child)
        elif ltag == "encoded":
            if not content_encoded:
                content_encoded = child.text or ""
        elif ltag == "description":
            if not description_raw:
                description_raw = child.text or ""
        elif ltag == "summary":
            if not itunes_summary:
                itunes_summary = child.text or ""
        elif ltag == "duration":
            if not duration_raw:
                duration_raw = child.text or ""
        elif ltag == "season":
            if not season_raw:
                season_raw = child.text or ""
        elif ltag in ("episode", "number"):
            if not number_raw:
                number_raw = child.text or ""
        elif ltag == "explicit":
            if not explicit_raw:
                explicit_raw = child.text or ""
        elif ltag == "image":
            href = child.attrib.get("href", "").strip()
            if href and not image_raw:
                image_raw = href
        elif ltag == "pubdate":
            if not pub_date_raw:
                pub_date_raw = child.text or ""
        elif ltag in ("published", "updated"):
            if not other_date_raw:
                other_date_raw = child.text or ""

    title = item_title or itunes_title
    if not title:
        return None
    title = title[:MAX_TITLE]

    chosen_enc = None
    chosen_audio_type = None
    for enc in enclosures:
        url = enc.attrib.get("url", "").strip()
        mime = enc.attrib.get("type")
        valid, audio_type = _is_valid_enclosure(url, mime)
        if valid:
            chosen_enc = enc
            chosen_audio_type = audio_type
            break

    if chosen_enc is None:
        return None

    audio_url = chosen_enc.attrib.get("url", "").strip()
    audio_bytes = _parse_audio_bytes(chosen_enc.attrib.get("length"))

    guid = (guid_raw or "").strip()
    if not guid or len(guid) > MAX_GUID:
        guid = audio_url

    if guid in seen_guids:
        return None
    seen_guids.add(guid)

    description = ""
    for cand in (content_encoded, description_raw, itunes_summary):
        if cand.strip():
            clean_text = _clean_text(cand)
            if clean_text:
                description = clean_text
                break

    duration_ms = parse_duration(duration_raw) if duration_raw else None

    pub_date_raw = pub_date_raw or other_date_raw
    published = _parse_date(pub_date_raw) if pub_date_raw else None
    if published is not None and published.tzinfo is None:
        published = published.replace(tzinfo=timezone.utc)

    image = _clean_url(image_raw)
    season = _parse_positive_int(season_raw)
    number = _parse_positive_int(number_raw)
    explicit = explicit_raw.strip().lower() in ("yes", "true", "explicit")

    return Episode(
        guid=guid,
        title=title,
        description=description,
        audio_url=audio_url,
        audio_type=chosen_audio_type,
        audio_bytes=audio_bytes,
        duration_ms=duration_ms,
        published=published,
        image=image,
        season=season,
        number=number,
        explicit=explicit,
    )


def _parse_podcast_impl(raw: bytes) -> Podcast | None:
    if not isinstance(raw, (bytes, bytearray)) or not raw:
        return None

    if re.search(rb"<!\s*entity", raw, re.IGNORECASE) or _declares_entities(raw):
        return None

    try:
        root = ET.fromstring(raw)
    except Exception:
        return None

    if _local(root.tag).lower() != "rss":
        return None

    channel = None
    for child in root:
        if _local(child.tag).lower() == "channel":
            channel = child
            break

    if channel is None:
        return None

    channel_title = ""
    channel_author = ""
    channel_desc_raw = ""
    channel_summary_raw = ""
    channel_itunes_image = ""
    channel_rss_image = ""
    channel_link_raw = ""
    channel_language_raw: str | None = None

    for child in channel:
        ltag = _local(child.tag).lower()
        if ltag == "title":
            if not channel_title and not _namespace(child.tag):
                channel_title = (child.text or "").strip()
        elif ltag == "author":
            if not channel_author:
                channel_author = (child.text or "").strip()[:MAX_TITLE]
        elif ltag == "description":
            if not channel_desc_raw:
                channel_desc_raw = child.text or ""
        elif ltag == "summary":
            if not channel_summary_raw:
                channel_summary_raw = child.text or ""
        elif ltag == "language":
            if channel_language_raw is None:
                # Strip whitespace before length check (FT-737 review).
                channel_language_raw = (child.text or "").strip()
        elif ltag == "link":
            # Only native `<link>`: `atom:link rel="self"` is the feed's own URL.
            if not channel_link_raw and not _namespace(child.tag):
                channel_link_raw = (child.text or "").strip()
        elif ltag == "image":
            href = child.attrib.get("href", "").strip()
            if href and not channel_itunes_image:
                channel_itunes_image = href
            for img_child in child:
                if _local(img_child.tag).lower() == "url":
                    url_val = (img_child.text or "").strip()
                    if url_val and not channel_rss_image:
                        channel_rss_image = url_val

    if not channel_title:
        return None
    channel_title = channel_title[:MAX_TITLE]

    channel_desc = ""
    if channel_desc_raw.strip():
        clean_text = _clean_text(channel_desc_raw)
        if clean_text:
            channel_desc = clean_text
    if not channel_desc and channel_summary_raw.strip():
        clean_text = _clean_text(channel_summary_raw)
        if clean_text:
            channel_desc = clean_text

    channel_image = _clean_url(channel_itunes_image)
    if channel_image is None:
        channel_image = _clean_url(channel_rss_image)

    channel_link = _clean_url(channel_link_raw)

    raw_episodes: list[tuple[int, Episode]] = []
    seen_guids: set[str] = set()
    feed_idx = 0

    for child in channel:
        if _local(child.tag).lower() != "item":
            continue
        try:
            ep = _parse_item(child, seen_guids)
            if ep is not None:
                raw_episodes.append((feed_idx, ep))
                feed_idx += 1
        except Exception:
            continue

    dated_items: list[tuple[int, Episode]] = []
    undated_items: list[Episode] = []

    for idx, ep in raw_episodes:
        if ep.published is not None:
            dated_items.append((idx, ep))
        else:
            undated_items.append(ep)

    dated_items.sort(key=lambda item: _EpisodeSortKey(item[1].published, item[0]))  # type: ignore[arg-type]

    episodes = [ep for _, ep in dated_items] + undated_items
    episodes = episodes[:MAX_EPISODES]

    return Podcast(
        title=channel_title,
        author=channel_author,
        description=channel_desc,
        image=channel_image,
        link=channel_link,
        episodes=episodes,
        language=language_of(channel_language_raw),
    )


def parse_podcast(raw: bytes) -> Podcast | None:
    try:
        return _parse_podcast_impl(raw)
    except Exception:
        return None
