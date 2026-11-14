"""FT-683: the /admin page is three fixed static files with strict headers.

What a browser does with the script is not exercised here; these tests hold
the properties that keep the page safe and on-design: no inline code, no
outside addresses, no markup built from server text, colors only from
DESIGN.md, both languages complete, and only addresses the server has.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app import admin, admin_web

ROOT = Path(__file__).resolve().parents[2]
DIR = ROOT / "server" / "app" / "data" / "admin"
HTML = (DIR / "index.html").read_text(encoding="utf-8")
CSS = (DIR / "admin.css").read_text(encoding="utf-8")
JS = (DIR / "admin.js").read_text(encoding="utf-8")


@pytest.fixture
def client() -> TestClient:
    app = FastAPI()
    admin_web.install_admin_web(app)
    return TestClient(app)


@pytest.mark.parametrize(
    ("path", "kind", "body"),
    [
        ("/admin", "text/html; charset=utf-8", HTML),
        ("/admin/", "text/html; charset=utf-8", HTML),
        ("/admin/admin.css", "text/css; charset=utf-8", CSS),
        ("/admin/admin.js", "text/javascript; charset=utf-8", JS),
    ],
)
def test_each_file_is_served_as_is(
    client: TestClient, path: str, kind: str, body: str
) -> None:
    r = client.get(path, follow_redirects=False)
    assert r.status_code == 200
    assert r.headers["content-type"] == kind
    assert r.text == body


@pytest.mark.parametrize(
    "path", ["/admin", "/admin/", "/admin/admin.css", "/admin/admin.js"]
)
def test_every_reply_carries_the_strict_headers(client: TestClient, path: str) -> None:
    h = client.get(path).headers
    assert h["cache-control"] == "no-store"
    assert h["x-content-type-options"] == "nosniff"
    assert h["x-frame-options"] == "DENY"
    assert h["referrer-policy"] == "no-referrer"
    policy = {
        part.split()[0]: part.split()[1:]
        for part in h["content-security-policy"].split(";")
        if part.strip()
    }
    assert policy == {
        "default-src": ["'none'"],
        "script-src": ["'self'"],
        "style-src": ["'self'"],
        "connect-src": ["'self'"],
        "base-uri": ["'none'"],
        "form-action": ["'none'"],
        "frame-ancestors": ["'none'"],
    }


@pytest.mark.parametrize(
    "path",
    [
        "/admin/index.html",
        "/admin/admin.py",
        "/admin/../admin.py",
        "/admin/%2e%2e/main.py",
        "/admin/..%2f..%2fmain.py",
        "/admin/admin.css.map",
        "/admin//admin.js",
        "/admin/data",
    ],
)
def test_nothing_else_is_served(client: TestClient, path: str) -> None:
    assert client.get(path, follow_redirects=False).status_code in (404, 307)
    assert client.get(path).text != JS or path == "/admin//admin.js"


@pytest.mark.parametrize("method", ["post", "put", "delete", "patch"])
def test_the_page_only_answers_get(client: TestClient, method: str) -> None:
    assert getattr(client, method)("/admin").status_code == 405


def test_the_directory_holds_exactly_three_files() -> None:
    assert sorted(p.name for p in DIR.iterdir()) == [
        "admin.css",
        "admin.js",
        "index.html",
    ]


def test_page_has_no_inline_code_or_style() -> None:
    assert re.findall(r"<script(?![^>]*\bsrc=)", HTML) == []
    assert "<style" not in HTML
    assert re.findall(r"\sstyle\s*=", HTML) == []
    assert re.findall(r"\son[a-z]+\s*=", HTML) == []
    assert "javascript:" not in HTML.lower()


def test_page_loads_only_its_own_two_files() -> None:
    assert re.findall(r'(?:src|href)="([^"]*)"', HTML) == [
        "/admin/admin.css",
        "/admin/admin.js",
    ]


@pytest.mark.parametrize("text", [HTML, CSS, JS])
def test_no_outside_address_anywhere(text: str) -> None:
    assert re.findall(r"(?:https?:)?//[A-Za-z0-9]", text) == []
    assert "url(" not in text
    assert "@import" not in text


def test_script_never_builds_markup_or_code_from_text() -> None:
    for word in (
        "innerHTML",
        "outerHTML",
        "insertAdjacentHTML",
        "document.write",
        "eval(",
        "new Function",
    ):
        assert word not in JS, word
    assert re.findall(r"set(?:Timeout|Interval)\(\s*[\"'`]", JS) == []


def test_token_is_kept_in_memory_only() -> None:
    for word in ("localStorage", "sessionStorage", "document.cookie", "indexedDB"):
        assert word not in JS, word
    assert 'credentials: "omit"' in JS
    assert "console." not in JS


def test_leaving_the_page_ends_the_login_and_presses_do_not_double() -> None:
    assert '"pagehide"' in JS
    assert "keepalive: Boolean(keepalive)" in JS
    assert JS.count("once(") >= 5
    listeners = re.findall(r'addEventListener\("(?:submit|click)", (.*)', JS)
    assert len(listeners) == 4
    assert all(
        "once(" in line or line.rstrip().endswith("=> {") or line.rstrip() == "() =>"
        for line in listeners
    )
    assert "font: 600" not in CSS


def test_script_runs_in_strict_mode() -> None:
    code = [
        line for line in JS.splitlines() if line.strip() and not line.startswith("//")
    ]
    assert code[0] == '"use strict";'


def test_script_calls_only_addresses_the_server_has() -> None:
    served = {route.path for route in admin.router.routes}  # type: ignore[attr-defined]
    called = set(re.findall(r'"(/v1/[A-Za-z/_]*)"', JS))
    assert called == {
        "/v1/auth/login",
        "/v1/auth/logout",
        "/v1/admin/state",
        "/v1/admin/users",
        "/v1/admin/users/",
    }
    assert {"/v1/admin/state", "/v1/admin/users"} <= served
    for tail in ("/invite", "/active", "/admin", "/devices"):
        assert f'"{tail}"' in JS
        assert "/v1/admin/users/{user_id}" + tail in served
    assert '"/revoke"' in JS
    assert "/v1/admin/users/{user_id}/devices/{device_id}/revoke" in served


def _texts(language: str) -> dict[str, str]:
    block = re.search(rf"\n  {language}: \{{\n(.*?)\n  \}},", JS, re.S)
    assert block is not None
    return dict(re.findall(r'^\s{4}(\w+): "(.*)",$', block.group(1), re.M))


def test_both_languages_have_the_same_complete_keys() -> None:
    en, ru = _texts("en"), _texts("ru")
    assert len(en) > 30
    assert en.keys() == ru.keys()
    assert all(v.strip() for v in en.values()) and all(v.strip() for v in ru.values())
    assert re.findall(r"[А-Яа-яЁё]", "".join(en.values())) == []
    same = {k for k in en if en[k] == ru[k]}
    assert same == {"title"}


def test_every_text_used_exists_and_every_text_is_used() -> None:
    keys = set(_texts("en"))
    code = JS.split("\n};\n", 1)[1]
    named = set(re.findall(r'data-t="(\w+)"', HTML))
    named |= set(re.findall(r'\bt\("(\w+)"\)', code))
    named |= set(re.findall(r'say\("[\w-]+", "(\w+)"', code))
    named |= set(re.findall(r'leave\("(\w+)"\)', code))
    assert named - keys == set()
    mentioned = set(re.findall(r'"(\w+)"', code)) | named
    assert keys - mentioned == set()


def test_page_names_the_server_and_no_old_name() -> None:
    assert "<title>Apertonodo</title>" in HTML
    for text in (HTML, CSS, JS):
        assert "flowtune" not in text.lower()


def _design_colors() -> set[str]:
    head = (ROOT / "DESIGN.md").read_text(encoding="utf-8").split("---")[1]
    return {c.upper() for c in re.findall(r"#[0-9A-Fa-f]{6,8}\b", head)}


def test_every_color_is_a_design_token() -> None:
    used = {c.upper() for c in re.findall(r"#[0-9A-Fa-f]{3,8}\b", CSS)}
    assert used
    assert used <= _design_colors()
    assert re.findall(r"\b(?:rgb|rgba|hsl|hsla)\(", CSS) == []
    body = CSS.split("}", 1)[1]
    assert re.findall(r"#[0-9A-Fa-f]{3,8}\b", body) == [], (
        "colors only through the variables"
    )


def test_every_color_variable_is_defined_once_and_used() -> None:
    defined = re.findall(r"--(\w+):", CSS)
    assert len(defined) == len(set(defined))
    used = set(re.findall(r"var\(--(\w+)\)", CSS))
    assert used == set(defined)


def test_radii_and_touch_targets_follow_the_design() -> None:
    assert set(re.findall(r"border-radius: (\d+)px", CSS)) <= {"26", "22", "16", "10"}
    assert "Onest" in CSS and "JetBrains Mono" in CSS
    for selector in ("button {", "input:not([type=checkbox]) {"):
        rule = CSS.split(selector, 1)[1].split("}", 1)[0]
        assert "min-height: 48px" in rule


def test_form_fields_let_a_password_manager_work() -> None:
    assert 'autocomplete="username"' in HTML
    assert 'autocomplete="current-password"' in HTML
    # FT-856: only the admin's own sign-in has a password; a person is added by name.
    assert HTML.count('type="password"') == 1
    assert 'id="add-password"' not in HTML
    assert 'name="robots" content="noindex"' in HTML


def test_notes_are_announced_to_screen_readers() -> None:
    assert HTML.count('role="alert"') == 2
    assert 'lang="en"' in HTML
