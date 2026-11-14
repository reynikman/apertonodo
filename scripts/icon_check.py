#!/usr/bin/env python3
"""Android icon and splash screen (P4, step 9; Р-A34, Р-A42).

Icon is white "a" and amber "β" on black (`apertono-beta-icon-imagegen-v2.png`),
label under icon is Apertono. Script verifies what phone shows before
first Flutter frame and what no app test can see:

- adaptive icon: background in app color, foreground layer and monochrome layer
  (themed icons Android 13+) in all five densities;
- graphic entirely inside safe circle of 66 out of 108 dp: otherwise launcher mask
  (circle, teardrop, squircle) will clip "β";
- monochrome layer is single-colored: Android tints it automatically and only uses alpha;
- legacy icon for Android before 8 — in all densities;
- Apertono label in production build, "Apertono D" and "Apertono S" in dev and staging;
- `applicationId` preserved: with a new one phone would install a second application;
- splash screen and background before first frame match app color, not white
  `?android:colorBackground` of light theme (white flash upon launch).

Images are read with custom PNG parser: `layout` job has python3 without
third-party libraries.

    python3 scripts/icon_check.py
"""

from __future__ import annotations

import re
import struct
import sys
import xml.etree.ElementTree as ET
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "mobile" / "android" / "app"
RES = APP / "src" / "main" / "res"
ANDROID = "{http://schemas.android.com/apk/res/android}"

DENSITIES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
BACKGROUND = "#07090C"  # FlowtuneColors.background
LABELS = {"main": "Apertono", "prod": "Apertono", "dev": "Apertono D", "staging": "Apertono S"}

errors: list[str] = []


def fail(message: str) -> None:
    errors.append(message)


# ── PNG ──────────────────────────────────────────────────────────────────


class Png:
    def __init__(self, path: Path):
        data = path.read_bytes()
        if data[:8] != b"\x89PNG\r\n\x1a\n":
            raise ValueError("not PNG")
        pos, idat, palette, trns = 8, b"", None, None
        while pos < len(data):
            (length,) = struct.unpack(">I", data[pos : pos + 4])
            kind = data[pos + 4 : pos + 8]
            body = data[pos + 8 : pos + 8 + length]
            pos += 12 + length
            if kind == b"IHDR":
                self.width, self.height, depth, color, _, _, interlace = struct.unpack(">IIBBBBB", body)
                if depth != 8 or interlace:
                    raise ValueError(f"depth {depth}, interlace {interlace}: need 8 bit without interlace")
                self.color = color
            elif kind == b"PLTE":
                palette = body
            elif kind == b"tRNS":
                trns = body
            elif kind == b"IDAT":
                idat += body
        channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[self.color]
        raw = zlib.decompress(idat)
        stride = self.width * channels
        rows, prev, i = [], bytearray(stride), 0
        for _ in range(self.height):
            kind, line = raw[i], bytearray(raw[i + 1 : i + 1 + stride])
            i += 1 + stride
            for x in range(stride):
                a = line[x - channels] if x >= channels else 0
                b = prev[x]
                c = prev[x - channels] if x >= channels else 0
                if kind == 1:
                    line[x] = (line[x] + a) & 255
                elif kind == 2:
                    line[x] = (line[x] + b) & 255
                elif kind == 3:
                    line[x] = (line[x] + (a + b) // 2) & 255
                elif kind == 4:
                    p = a + b - c
                    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                    line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
            rows.append(bytes(line))
            prev = line
        self.pixels: list[list[tuple[int, int, int, int]]] = []
        for line in rows:
            out = []
            for x in range(self.width):
                px = line[x * channels : (x + 1) * channels]
                if self.color == 6:
                    out.append(tuple(px))
                elif self.color == 2:
                    out.append((*px, 255))
                elif self.color == 4:
                    out.append((px[0], px[0], px[0], px[1]))
                elif self.color == 0:
                    out.append((px[0], px[0], px[0], 255))
                else:
                    k = px[0]
                    alpha = trns[k] if trns and k < len(trns) else 255
                    out.append((*palette[k * 3 : k * 3 + 3], alpha))
            self.pixels.append(out)

    def at(self, x: int, y: int) -> tuple[int, int, int, int]:
        return self.pixels[y][x]

    def all(self):
        for y, row in enumerate(self.pixels):
            for x, px in enumerate(row):
                yield x, y, px


def is_white(px) -> bool:
    return px[3] > 200 and min(px[:3]) >= 225


def is_amber(px) -> bool:
    # #E5A93B with tolerance: antialiasing and density scaling.
    r, g, b, a = px
    return a > 200 and r >= 200 and 140 <= g <= 195 and b <= 110


def load(path: Path) -> Png | None:
    if not path.is_file():
        fail(f"missing file {path.relative_to(ROOT)}")
        return None
    try:
        return Png(path)
    except Exception as exc:  # noqa: BLE001 - any PNG damage is a failure
        fail(f"{path.relative_to(ROOT)} cannot be read: {exc}")
        return None


# ── adaptive icon ──────────────────────────────────────────────────────────


def check_adaptive() -> None:
    for name in ("ic_launcher.xml", "ic_launcher_round.xml"):
        path = RES / "mipmap-anydpi-v26" / name
        if name == "ic_launcher_round.xml" and not path.exists():
            continue
        if not path.is_file():
            fail(f"missing {path.relative_to(ROOT)} — no adaptive icon, launcher will show old picture in frame")
            continue
        root = ET.parse(path).getroot()
        if root.tag != "adaptive-icon":
            fail(f"{name}: root {root.tag}, need adaptive-icon")
            continue
        layers = {child.tag: child.get(f"{ANDROID}drawable") for child in root}
        want = {
            "background": "@color/ic_launcher_background",
            "foreground": "@mipmap/ic_launcher_foreground",
            "monochrome": "@mipmap/ic_launcher_monochrome",
        }
        for tag, ref in want.items():
            if layers.get(tag) != ref:
                fail(f"{name}: <{tag}> = {layers.get(tag)!r}, need {ref}")

    colors = {}
    for xml in (RES / "values").glob("*.xml"):
        for item in ET.parse(xml).getroot().iter("color"):
            colors[item.get("name")] = (item.text or "").strip()
    color = colors.get("ic_launcher_background", "")
    if color.upper() not in (BACKGROUND, "#FF" + BACKGROUND[1:]):
        fail(f"@color/ic_launcher_background = {color!r}, need {BACKGROUND} — app background")


def check_layers() -> None:
    for density, scale in DENSITIES.items():
        size = round(108 * scale)
        safe = 33 * scale + 1  # safe circle radius 66 dp plus one pixel for anti-aliasing
        centre = (size - 1) / 2
        for layer in ("ic_launcher_foreground", "ic_launcher_monochrome"):
            path = RES / f"mipmap-{density}" / f"{layer}.png"
            png = load(path)
            if png is None:
                continue
            where = f"{layer} {density}"
            if (png.width, png.height) != (size, size):
                fail(f"{where}: {png.width}×{png.height}, need {size}×{size} (108 dp)")
                continue
            if png.color not in (4, 6) and not (png.color == 3):
                fail(f"{where}: no transparency — layer must be transparent around drawing")
            corners = [png.at(0, 0), png.at(size - 1, 0), png.at(0, size - 1), png.at(size - 1, size - 1)]
            if any(px[3] != 0 for px in corners):
                fail(f"{where}: corners are not transparent — background drawn in foreground layer, mask will show square")
            outside = 0
            xs, ys, white, amber, shades = [], [], 0, 0, set()
            for x, y, px in png.all():
                if px[3] <= 16:
                    continue
                if ((x - centre) ** 2 + (y - centre) ** 2) ** 0.5 > safe:
                    outside += 1
                xs.append(x)
                ys.append(y)
                white += is_white(px)
                amber += is_amber(px)
                if px[3] > 200:
                    shades.add(px[:3])
            if outside:
                fail(f"{where}: {outside} drawing pixels outside safe 66 dp circle — mask will cut them")
            if not xs:
                fail(f"{where}: layer is empty")
                continue
            span = max(max(xs) - min(xs), max(ys) - min(ys)) + 1
            if span < 0.4 * size:
                fail(f"{where}: drawing {span} pixels of {size} — icon is tiny (need ≥ 40 % of layer)")
            if layer == "ic_launcher_foreground":
                if white < 0.02 * size * size:
                    fail(f"{where}: white 'a' almost missing ({white} pixels)")
                if amber < 0.004 * size * size:
                    fail(f"{where}: amber 'β' almost missing ({amber} pixels)")
            else:
                if any(min(c) < 235 for c in shades):
                    fail(f"{where}: monochrome layer is not white — Android tints it itself, need single white color with alpha")
                if amber:
                    fail(f"{where}: amber in monochrome layer")


def check_legacy() -> None:
    for density, scale in DENSITIES.items():
        size = round(48 * scale)
        png = load(RES / f"mipmap-{density}" / "ic_launcher.png")
        if png is None:
            continue
        where = f"ic_launcher {density}"
        if (png.width, png.height) != (size, size):
            fail(f"{where}: {png.width}×{png.height}, need {size}×{size} (48 dp)")
            continue
        white = sum(is_white(px) for _, _, px in png.all())
        amber = sum(is_amber(px) for _, _, px in png.all())
        if white < 0.02 * size * size or amber < 0.003 * size * size:
            fail(f"{where}: not Apertono icon (white {white}, amber {amber} pixels)")


# ── labels, applicationId, splash ──────────────────────────────────────────


def check_labels() -> None:
    def label(flavor: str) -> str | None:
        path = APP / "src" / flavor / "res" / "values" / "strings.xml"
        if not path.is_file():
            return None
        for item in ET.parse(path).getroot().iter("string"):
            if item.get("name") == "app_name":
                return (item.text or "").strip()
        return None

    main = label("main")
    for flavor, want in LABELS.items():
        got = label(flavor) or main
        if got != want:
            fail(f"label {flavor}: {got!r}, need {want!r}")


def check_application_id() -> None:
    gradle = next((p for p in (APP / "build.gradle.kts", APP / "build.gradle") if p.is_file()), None)
    text = gradle.read_text(encoding="utf-8") if gradle else ""
    ids = re.findall(r'applicationId\s*=?\s*"([^"]+)"', text)
    if ids != ["app.apertono.player"]:
        fail(f"applicationId {ids}, need exactly ['app.apertono.player'] — otherwise second app on phone")


def styles(folder: str) -> dict[str, dict[str, str]]:
    path = RES / folder / "styles.xml"
    if not path.is_file():
        return {}
    out = {}
    for style in ET.parse(path).getroot().iter("style"):
        out[style.get("name")] = {item.get("name"): (item.text or "").strip() for item in style.iter("item")}
    return out


def check_splash() -> None:
    color = "@color/ic_launcher_background"
    for folder in ("values", "values-night"):
        found = styles(folder)
        normal = found.get("NormalTheme", {}).get("android:windowBackground")
        if normal != color:
            fail(f"{folder}/styles.xml NormalTheme: windowBackground {normal!r}, need {color} — flash before first frame")
    for folder in ("values-v31", "values-night-v31"):
        found = styles(folder)
        launch = found.get("LaunchTheme")
        if launch is None:
            fail(f"missing LaunchTheme in {folder}/styles.xml — Android 12+ splash will take white theme background")
            continue
        if launch.get("android:windowSplashScreenBackground") != color:
            fail(f"{folder} LaunchTheme: windowSplashScreenBackground {launch.get('android:windowSplashScreenBackground')!r}, need {color}")
    for folder in ("drawable", "drawable-v21"):
        path = RES / folder / "launch_background.xml"
        text = path.read_text(encoding="utf-8") if path.is_file() else ""
        if color not in text:
            fail(f"{folder}/launch_background.xml: background is not {color}")
        if "@mipmap/ic_launcher_foreground" not in text:
            fail(f"{folder}/launch_background.xml: no center emblem (@mipmap/ic_launcher_foreground)")


def main() -> int:
    check_adaptive()
    check_layers()
    check_legacy()
    check_labels()
    check_application_id()
    check_splash()
    if errors:
        for message in errors:
            print(f"FAIL: {message}")
        print(f"ICON CHECK FAILED ({len(errors)})")
        return 1
    print("ICON CHECK OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
