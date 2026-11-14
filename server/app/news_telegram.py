"""FT-576 (Р-A83): parsing public Telegram channels (pages https://t.me/s/<channel>).

Extracts posts:
- title: first line of text, up to 120 characters
- text: clean full text (line breaks preserved, up to 4000 characters)
- link: post link (https://t.me/<channel>/<number>)
- published: publication datetime with timezone or None
- image: URL of the first image or None
"""

from __future__ import annotations

import re
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from html.parser import HTMLParser
from typing import Any

MAX_TEXT_LEN = 4000
MAX_TITLE_LEN = 120

VOID_ELEMENTS = frozenset({
    "area",
    "base",
    "br",
    "col",
    "embed",
    "hr",
    "img",
    "input",
    "link",
    "meta",
    "param",
    "source",
    "track",
    "wbr",
})

_BG_IMAGE_RE = re.compile(
    r"background-image\s*:\s*url\(\s*['\"]?(https?://[^'\")]+)['\"]?\s*\)",
    re.IGNORECASE,
)
_POST_LINK_RE = re.compile(r"^https://t\.me/[^/]+/\d+$")


def _parse_date(val: str | None) -> datetime | None:
    if not val or not val.strip():
        return None
    s = val.strip()
    try:
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt
    except Exception:
        pass
    try:
        dt = parsedate_to_datetime(s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt
    except Exception:
        pass
    return None


class _TelegramParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.posts: list[dict[str, Any]] = []
        self.cur: dict[str, Any] | None = None
        self.depth = 0
        self.msg_depth = 0
        self.msg_tag = ""
        self.in_text = False
        self.text_depth = 0
        self.text_tag = ""
        self.text_pieces: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        tag_lower = tag.lower()
        is_void = tag_lower in VOID_ELEMENTS
        if not is_void:
            self.depth += 1

        adict: dict[str, str] = {k.lower(): (v or "") for k, v in attrs}
        classes = adict.get("class", "").split()
        data_post = adict.get("data-post")

        is_msg = bool(data_post) or "tgme_widget_message" in classes
        if is_msg:
            self._finish_cur()
            link = ""
            if data_post:
                dp = data_post.strip()
                link = dp if dp.startswith("http") else f"https://t.me/{dp}"
            self.cur = {
                "link": link,
                "image": None,
                "published": None,
            }
            self.msg_depth = self.depth
            self.msg_tag = tag_lower
            self.text_pieces = []
            self.in_text = False
            self.text_depth = 0
            self.text_tag = ""

        if self.cur is not None:
            if not self.cur.get("link"):
                href = adict.get("href", "").strip()
                if href and _POST_LINK_RE.match(href):
                    self.cur["link"] = href
                elif "tgme_widget_message_date" in classes and href:
                    self.cur["link"] = href if href.startswith("http") else f"https://t.me/{href.lstrip('/')}"

            if not self.cur.get("image"):
                is_avatar = any(c in classes for c in ("tgme_widget_message_user_photo", "tgme_page_photo_image"))
                if not is_avatar:
                    style = adict.get("style", "")
                    if "background-image" in style:
                        m = _BG_IMAGE_RE.search(style)
                        if m:
                            self.cur["image"] = m.group(1)
                    if tag_lower == "img" and not self.cur.get("image"):
                        src = adict.get("src", "").strip()
                        if src.startswith(("http://", "https://")):
                            self.cur["image"] = src

            if tag_lower == "time" and not self.cur.get("published"):
                dt_str = adict.get("datetime", "")
                if dt_str:
                    self.cur["published"] = _parse_date(dt_str)

            if any("tgme_widget_message_text" in c for c in classes):
                self.in_text = True
                self.text_depth = self.depth
                self.text_tag = tag_lower
            elif self.in_text:
                if tag_lower == "br":
                    self.text_pieces.append("\n")
                elif tag_lower in ("p", "div"):
                    if self.text_pieces and not self.text_pieces[-1].endswith("\n"):
                        self.text_pieces.append("\n")

    def handle_endtag(self, tag: str) -> None:
        tag_lower = tag.lower()
        if self.in_text and tag_lower == self.text_tag and self.depth == self.text_depth:
            self.in_text = False
            self.text_depth = 0
            self.text_tag = ""

        if self.cur is not None and tag_lower == self.msg_tag and self.depth == self.msg_depth:
            self._finish_cur()

        if tag_lower not in VOID_ELEMENTS:
            self.depth -= 1

    def handle_data(self, data: str) -> None:
        if self.in_text and data:
            self.text_pieces.append(data)

    def _finish_cur(self) -> None:
        if self.cur is not None and self.cur.get("link"):
            raw_text = "".join(self.text_pieces).strip()
            text = raw_text[:MAX_TEXT_LEN]
            lines = [line.strip() for line in text.splitlines() if line.strip()]
            title = lines[0][:MAX_TITLE_LEN] if lines else ""
            self.posts.append({
                "title": title,
                "text": text,
                "link": self.cur["link"],
                "published": self.cur.get("published"),
                "image": self.cur.get("image"),
            })
        self.cur = None
        self.text_pieces = []
        self.in_text = False
        self.text_depth = 0
        self.text_tag = ""
        self.msg_depth = 0
        self.msg_tag = ""

    def close(self) -> None:
        super().close()
        self._finish_cur()


def parse_channel(raw: bytes | str) -> list[dict[str, Any]]:
    """Parse HTML of a public Telegram channel (t.me/s/<channel>).

    Returns list of posts with dicts:
    - title: str (up to 120 characters)
    - text: str (up to 4000 characters, line breaks preserved)
    - link: str (https://t.me/<channel>/<number>)
    - published: datetime with timezone or None
    - image: str or None
    """
    if not raw:
        return []
    if isinstance(raw, bytes):
        try:
            content = raw.decode("utf-8")
        except UnicodeDecodeError:
            content = raw.decode("utf-8", errors="replace")
    else:
        content = str(raw)

    parser = _TelegramParser()
    try:
        parser.feed(content)
        parser.close()
    except Exception:
        return []
    return parser.posts
