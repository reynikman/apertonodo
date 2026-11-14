"""FT-573 (Р-A83): parsing RSS 2.0 and Atom.

Extracts title, link, publication date, clean full text (up to 4000 characters)
and URL of the first image.
"""

from __future__ import annotations

import html
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from html.parser import HTMLParser
from typing import Any

MAX_TEXT_LEN = 4000

IMAGE_EXTENSIONS = (".jpg", ".jpeg", ".png", ".webp", ".gif", ".avif")


class _HtmlTextExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.pieces: list[str] = []
        self.image: str | None = None
        self._skip = False

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        tag_lower = tag.lower()
        if tag_lower in ("script", "style"):
            self._skip = True
        elif tag_lower in ("p", "div", "br", "h1", "h2", "h3", "h4", "h5", "h6", "li", "tr"):
            self.pieces.append("\n")
        elif tag_lower == "img" and not self.image:
            for k, v in attrs:
                if k.lower() == "src" and v:
                    val = v.strip()
                    if val.startswith("http://") or val.startswith("https://"):
                        self.image = val
                        break

    def handle_endtag(self, tag: str) -> None:
        tag_lower = tag.lower()
        if tag_lower in ("script", "style"):
            self._skip = False
        elif tag_lower in ("p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "tr"):
            self.pieces.append("\n")

    def handle_data(self, data: str) -> None:
        if not self._skip and data:
            self.pieces.append(data)

    def get_text(self) -> str:
        raw = "".join(self.pieces)
        lines = [line.strip() for line in raw.split("\n")]
        non_empty = [line for line in lines if line]
        return "\n\n".join(non_empty)[:MAX_TEXT_LEN]


def _clean_html(raw_html: str) -> tuple[str, str | None]:
    if not raw_html:
        return "", None
    parser = _HtmlTextExtractor()
    try:
        parser.feed(raw_html)
        return parser.get_text(), parser.image
    except Exception:
        clean = html.unescape(raw_html).strip()[:MAX_TEXT_LEN]
        return clean, None


def _local(tag: str) -> str:
    return tag.split("}")[-1]


def _parse_date(val: str | None) -> datetime | None:
    if not val or not val.strip():
        return None
    s = val.strip()
    try:
        dt = parsedate_to_datetime(s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt
    except Exception:
        pass
    try:
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt
    except Exception:
        pass
    return None


def _is_image_url(url: str) -> bool:
    lower = url.lower()
    return any(lower.endswith(ext) or f"{ext}?" in lower for ext in IMAGE_EXTENSIONS)


def parse_feed(raw: bytes) -> list[dict[str, Any]]:
    """Parse RSS 2.0 or Atom.

    Returns list of dicts:
    - title: str
    - text: str (up to 4000 characters, without HTML)
    - link: str
    - published: datetime with timezone or None
    - image: str (first image URL) or None
    """
    try:
        root = ET.fromstring(raw)
    except Exception:
        return []

    root_tag = _local(root.tag)
    items: list[dict[str, Any]] = []

    published: datetime | None = None
    image: str | None = None

    if root_tag == "feed":
        # Atom
        for entry in root.findall(".//"):
            if _local(entry.tag) != "entry":
                continue
            title = ""
            link = ""
            content_raw = ""
            media_desc = ""
            video_id = ""
            published = None
            image = None

            for child in entry:
                ctag = _local(child.tag)
                if ctag == "title":
                    title = html.unescape((child.text or "").strip())
                elif ctag == "link":
                    rel = child.attrib.get("rel", "alternate")
                    href = child.attrib.get("href", "")
                    mime = child.attrib.get("type", "")
                    if rel == "enclosure" and (mime.startswith("image/") or _is_image_url(href)):
                        if not image and href:
                            image = href
                    elif rel in ("alternate", "") and not link:
                        link = href or (child.text or "").strip()
                elif ctag in ("content", "summary"):
                    if not content_raw or ctag == "content":
                        content_raw = child.text or ""
                elif ctag in ("updated", "published"):
                    if published is None:
                        published = _parse_date(child.text)
                elif ctag == "content":
                    url: str | None = child.attrib.get("url")
                    medium = child.attrib.get("medium", "")
                    mime = child.attrib.get("type", "")
                    if url and (medium == "image" or mime.startswith("image/") or _is_image_url(url)):
                        if not image:
                            image = url
                elif ctag == "thumbnail" and child.attrib.get("url"):
                    if not image:
                        image = child.attrib["url"]
                elif ctag == "description" and not media_desc:
                    media_desc = html.unescape((child.text or "").strip())[:MAX_TEXT_LEN]
                elif ctag == "videoId" and not video_id:
                    video_id = (child.text or "").strip()
                elif ctag == "group":
                    for gchild in child:
                        gctag = _local(gchild.tag)
                        if gctag == "thumbnail" and gchild.attrib.get("url"):
                            if not image:
                                image = gchild.attrib["url"]
                        elif gctag == "description" and not media_desc:
                            media_desc = html.unescape((gchild.text or "").strip())[:MAX_TEXT_LEN]
                        elif gctag == "title" and not title:
                            title = html.unescape((gchild.text or "").strip())
                        elif gctag == "content":
                            url = gchild.attrib.get("url")
                            medium = gchild.attrib.get("medium", "")
                            mime = gchild.attrib.get("type", "")
                            if url and (medium == "image" or mime.startswith("image/") or _is_image_url(url)):
                                if not image:
                                    image = url

            if not link and video_id:
                link = f"https://www.youtube.com/watch?v={video_id}"

            text, img_from_html = _clean_html(content_raw)
            if not image:
                image = img_from_html
            if media_desc:
                text = media_desc

            items.append({
                "title": title,
                "text": text,
                "link": link,
                "published": published,
                "image": image,
            })
    else:
        # RSS 2.0 / RDF
        for item in root.findall(".//"):
            if _local(item.tag) != "item":
                continue
            title = ""
            link = ""
            desc_raw = ""
            media_desc = ""
            published = None
            image = None

            for child in item:
                ctag = _local(child.tag)
                if ctag == "title":
                    title = html.unescape((child.text or "").strip())
                elif ctag == "link":
                    link = (child.text or "").strip()
                elif ctag == "guid" and not link:
                    if child.attrib.get("isPermaLink", "true") == "true":
                        link = (child.text or "").strip()
                elif ctag in ("description", "encoded"):
                    # content:encoded is preferred if present
                    if ctag == "encoded" or not desc_raw:
                        desc_raw = child.text or ""
                elif ctag == "pubDate":
                    published = _parse_date(child.text)
                elif ctag in ("content", "thumbnail"):
                    # media:content, media:thumbnail
                    url = child.attrib.get("url")
                    medium = child.attrib.get("medium", "")
                    mime = child.attrib.get("type", "")
                    if url and (ctag == "thumbnail" or medium == "image" or mime.startswith("image/") or _is_image_url(url) or not image):
                        if not image or medium == "image" or ctag == "thumbnail":
                            image = url
                elif ctag == "enclosure":
                    url = child.attrib.get("url")
                    mime = child.attrib.get("type", "")
                    if url and (mime.startswith("image/") or _is_image_url(url)):
                        if not image:
                            image = url
                elif ctag == "group":
                    for gchild in child:
                        gctag = _local(gchild.tag)
                        if gctag == "thumbnail" and gchild.attrib.get("url"):
                            if not image:
                                image = gchild.attrib["url"]
                        elif gctag == "description" and not media_desc:
                            media_desc = html.unescape((gchild.text or "").strip())[:MAX_TEXT_LEN]
                        elif gctag == "title" and not title:
                            title = html.unescape((gchild.text or "").strip())
                        elif gctag == "content" and gchild.attrib.get("url"):
                            medium = gchild.attrib.get("medium", "")
                            mime = gchild.attrib.get("type", "")
                            url = gchild.attrib["url"]
                            if medium == "image" or mime.startswith("image/") or _is_image_url(url):
                                if not image:
                                    image = url

            text, img_from_html = _clean_html(desc_raw)
            if not image:
                image = img_from_html
            if media_desc and not text:
                text = media_desc

            items.append({
                "title": title,
                "text": text,
                "link": link,
                "published": published,
                "image": image,
            })

    return items
