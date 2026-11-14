"""FT-690: QR code "Connect phone" for /admin page. Tests written by lead before implementation.

Contract:
- `server/app/qr.py` — pure Python without dependencies, network, or logging;
- QR Model 2, versions 1–10, error correction M, byte mode (text in UTF-8), ISO/IEC 18004 standard:
  terminator up to 4 zero bits, pad to byte, then 0xEC/0x11 alternating;
- `make_qr(text, mask=k)` matches bit-for-bit with reference implementation (`qrcode` 8.x library,
  fingerprints below taken by lead on 08.10; library itself is not included in project);
- `make_qr(text)` without mask picks mask with lowest `penalty`, lower number on tie;
- `penalty` — four rules of standard in simple form (see `reference_penalty` below — that is
  the definition);
- empty text, longer than `MAX_BYTES` bytes in UTF-8, or mask not 0–7 — `ValueError`;
- `to_svg` — black on white, quiet zone of `quiet` modules, each dark module — `M{x} {y}h1v1h-1z`.
"""

from __future__ import annotations

import ast
import hashlib
from pathlib import Path
import re
import xml.etree.ElementTree as ET

import pytest

from app import qr

BY_LENGTH = [
    (1, 3, 1, 21, "d0ff08053f8dc1bfdcfb5d5cf3f13f4d0c90c8c4aa0431b8bc81566fbfa4c1f2"),
    (14, 5, 1, 21, "6f2939b373506c8f4e689e8946c9f58cfbaf3543666d324c6d90f85b4a7a81d7"),
    (15, 1, 2, 25, "5505fc24b8722eb99a97cd6aead94a0282959cab0f8fba5611a0ebd21cf1b33a"),
    (26, 7, 2, 25, "e3490e4ee2e29e505791086b0018cc78955255467143ff771bbff1a18a00db7e"),
    (27, 2, 3, 29, "e69d031a85801d4fcd7904360527a713f4ccd1321725c6769301de85fcd69093"),
    (42, 4, 3, 29, "3255412e2d6951f01863e1fc36bf4363ced8433d75e77865b666f4b73b37d582"),
    (43, 6, 4, 33, "8dd79718adced98dd6faf3eb0f3ec0572a183a2aff9327ab025f886b9ae48974"),
    (62, 0, 4, 33, "4a8866e204b44209f4b3b875135d829b540c9562ce997ba735a8f913b2252b52"),
    (63, 5, 5, 37, "bcc5844da814c792f239f720763365f7edaf21c1ba4dd22b019cc77452cec561"),
    (84, 3, 5, 37, "935d0611cb5583fd7d0ea97c1544e5f2cad7a0d65d03e84e9ae7b3b45994eaee"),
    (85, 1, 6, 41, "21133bc2a726b227c88290168d2d8b5713109e69411e5186890cf4caa58960f4"),
    (106, 6, 6, 41, "322bd028551d69938ec6e1879421c38574327dcb377576347304afa4cd9254a8"),
    (107, 2, 7, 45, "01d6e7f5a5319ca5a3d81be136e17763bd575c3abafc9b6122030ee255eac2b6"),
    (122, 4, 7, 45, "18a7818e770925740ec161aa265fe8461006c4269fcc091c50a2945871705216"),
    (123, 0, 8, 49, "c48f135b0941891d6501a8186792c64a4ade213fb2c6a8cf9293e0b24ee6824c"),
    (152, 7, 8, 49, "983c8a8ee347c0d150b0a2bddf108afc79d6ddc03866db5bb20711efae813aa4"),
    (153, 3, 9, 53, "0d8321fcd22be3a8fdc3b9fcbfa32f4aa071fbd8421c643d0e0f28a1c791e3de"),
    (180, 5, 9, 53, "f5945b16834461de8e0c0b83f139634e753e25767e5e800c8071d96f7c75c86d"),
    (
        181,
        1,
        10,
        57,
        "fb91875813661842d3c7f67b5ac18ac9e51edd3f5daf159341916a2ec447842a",
    ),
    (
        213,
        6,
        10,
        57,
        "d2062b93f1e6e3fdddd804a56cbbaacae0071ff4c1b64a28fe1e61161e3e9acd",
    ),
]
FLOWTUNE_MASKS = [
    "38643b0994e21e894c31e79062ca43fa997a5c5a5a695fbe4a7f2966610c3e92",  # 0
    "ab4f8099aaa9f04b157ce347aced9d12cd43305242a6a925b8e64b4f194eff8f",  # 1
    "826dffa5a55512613e087298193ceae396162051036a898672a354255476df30",  # 2
    "f5dd46e28fd2b7b3428677fe7554019dddcc7310bbd542d555b1cb965d7486e9",  # 3
    "d4b38d8a3b26387170bc096bcadb7a0f21ad86ab5944041936d9cfe7a51481ce",  # 4
    "ba1b7546eb92ed86848d6468a8b2ef25439515d5d3436a0c16f85615dc5ffa57",  # 5
    "9fe63df63baf9d132e35c655d38e2a68d0d1feaf91a472982a738e2dd2c2cf6c",  # 6
    "84d2550ad01d342d70e4a05e7a3c74f4303823ae387f91e7e75909b4ea57f334",  # 7
]
CYRILLIC_MASKS = [
    "acd46e95a1980a75c4746886e148d8084e1b83938398ad98238c4eadef962d49",  # 0
    "b9b3557c9cd86498ba83e2a07ee8b45e77fc6d83d9c0ab4bd2b1821105a4e183",  # 1
    "ebb13a8b0243adb75b848c5bc38d0cca5f6d8f1cd3f84b316be98ffb53de4052",  # 2
    "814a513acafd4eaf000fe55262514cccf2e000493846e4d6b50506776fd792c5",  # 3
    "d94de6b045dd0611937b640894a8ca031e9373857500c57913f4d5d28fb8ec86",  # 4
    "1aa55aecc0a455aea2d9a8c2d647a1272888a4271e7f2fa4c168802d3c2d1ece",  # 5
    "6ebfcae667dda057762fa7ba8c465c8404702750c72c0f2c67e165701ca7be77",  # 6
    "954a9017efc7311d8d147323a0df39f1d9ad9e95eb2d20aa1624fea093b59de3",  # 7
]
LONG_MASKS = [
    "83a128bd15f3bc93a863edf84b29b3b840db5b7d44a93ec9d912f4b02aed59c6",  # 0
    "4024b33140dd4a3e7a2764c6590a23c92f82aacd67a0478845904c1727a3038a",  # 1
    "42baddea8588c2e00790b229971777cd232c55943b9f24aa40cbcb0d7391b858",  # 2
    "1ba4c0ce2e3c46d0325a38739e578db744b888ed16d1cec99462955f21216cdd",  # 3
    "3edbe7d3ceb5ee06d39bf07145309c94eb96ddf64a85e4237ffa8bbe9dea7c9d",  # 4
    "fc9356555465b50cdbd54ecdb452753b9f2fc97630ed9498ae88985cd16843c0",  # 5
    "17adba2500e39d4da491ce66660aceb3d17af70cc511a42201deabe291d0076c",  # 6
    "ec45c00a59622b4117bc00ef9acd280a748c3c0e0b2c86dec7d29254bbbb5a6c",  # 7
]


def text(n: int) -> str:
    return ("https://apertono.example/" + "abcdefghij0123456789" * 20)[:n]


def fingerprint(m: list[list[bool]]) -> str:
    bits = "\n".join("".join("1" if x else "0" for x in row) for row in m)
    return hashlib.sha256(bits.encode()).hexdigest()


def reference_penalty(m: list[list[bool]]) -> int:
    size = len(m)
    rows = ["".join("1" if x else "0" for x in row) for row in m]
    cols = ["".join(rows[r][c] for r in range(size)) for c in range(size)]
    score = 0
    for line in rows + cols:
        for run in re.findall(r"0+|1+", line):
            if len(run) >= 5:
                score += len(run) - 2
        for pat in ("10111010000", "00001011101"):
            score += 40 * sum(1 for i in range(size) if line.startswith(pat, i))
    for r in range(size - 1):
        for c in range(size - 1):
            if rows[r][c] == rows[r][c + 1] == rows[r + 1][c] == rows[r + 1][c + 1]:
                score += 3
    dark = sum(row.count("1") for row in rows)
    score += 10 * (abs(dark * 20 - size * size * 10) // (size * size))
    return score


# --- references ----------------------------------------------------------------------------


@pytest.mark.parametrize(("n", "mask", "version", "size", "digest"), BY_LENGTH)
def test_matches_reference_on_every_version_boundary(
    n: int, mask: int, version: int, size: int, digest: str
) -> None:
    t = text(n)
    assert qr.version_for(t) == version
    m = qr.make_qr(t, mask=mask)
    assert len(m) == size
    assert all(len(row) == size for row in m)
    assert fingerprint(m) == digest


@pytest.mark.parametrize(
    ("value", "digests"),
    [
        ("https://music.example.org", FLOWTUNE_MASKS),
        ("Привет, мир", CYRILLIC_MASKS),
        (text(200), LONG_MASKS),
    ],
    ids=["v2", "cyrillic", "v10"],
)
@pytest.mark.parametrize("mask", range(8))
def test_all_eight_masks_match_reference(
    value: str, digests: list[str], mask: int
) -> None:
    assert fingerprint(qr.make_qr(value, mask=mask)) == digests[mask]


def test_cells_are_plain_bools() -> None:
    m = qr.make_qr("a", mask=0)
    assert all(type(x) is bool for row in m for x in row)


# --- version and limits --------------------------------------------------------------------


@pytest.mark.parametrize(
    ("n", "version"),
    [
        (1, 1),
        (14, 1),
        (15, 2),
        (26, 2),
        (27, 3),
        (42, 3),
        (43, 4),
        (62, 4),
        (63, 5),
        (84, 5),
        (85, 6),
        (106, 6),
        (107, 7),
        (122, 7),
        (123, 8),
        (152, 8),
        (153, 9),
        (180, 9),
        (181, 10),
        (213, 10),
    ],
)
def test_smallest_version_that_fits(n: int, version: int) -> None:
    assert qr.version_for(text(n)) == version


def test_version_counts_utf8_bytes_not_letters() -> None:
    assert qr.version_for("я" * 7) == 1  # 14 bytes
    assert qr.version_for("я" * 8) == 2  # 16 bytes
    assert qr.version_for("я" * 106) == 10  # 212 bytes
    with pytest.raises(ValueError):
        qr.version_for("я" * 107)  # 214 bytes


def test_constants() -> None:
    assert qr.MAX_BYTES == 213
    assert qr.MAX_VERSION == 10


@pytest.mark.parametrize("bad", ["", "x" * 214])
def test_empty_or_too_long_is_an_error(bad: str) -> None:
    with pytest.raises(ValueError):
        qr.version_for(bad)
    with pytest.raises(ValueError):
        qr.make_qr(bad)
    with pytest.raises(ValueError):
        qr.make_qr(bad, mask=0)


@pytest.mark.parametrize("mask", [-1, 8, 100])
def test_mask_out_of_range_is_an_error(mask: int) -> None:
    with pytest.raises(ValueError):
        qr.make_qr("a", mask=mask)


# --- mask selection ------------------------------------------------------------------------


@pytest.mark.parametrize(
    "value",
    [
        "a",
        "https://example.org",
        "https://music.example.org",
        "Привет, мир",
        "http://192.0.2.10:18088",
        text(60),
        text(107),
        text(153),
        text(200),
    ],
)
def test_auto_mask_is_lowest_penalty_smallest_on_tie(value: str) -> None:
    variants = [qr.make_qr(value, mask=k) for k in range(8)]
    scores = [reference_penalty(v) for v in variants]
    best = scores.index(min(scores))
    assert qr.make_qr(value) == variants[best]


@pytest.mark.parametrize("value", ["a", text(43), text(122), text(213)])
def test_penalty_follows_the_definition(value: str) -> None:
    for k in range(8):
        m = qr.make_qr(value, mask=k)
        assert qr.penalty(m) == reference_penalty(m)


def test_penalty_small_cases() -> None:
    light = [[False] * 5 for _ in range(5)]
    # 10 lines of 5 → 10×3; 16 2×2 squares → 48; 0 % dark → 10×10
    assert qr.penalty(light) == 30 + 48 + 100
    checker = [[(r + c) % 2 == 0 for c in range(6)] for r in range(6)]
    assert qr.penalty(checker) == 0
    row = [[c in (0, 2, 3, 4, 6) for c in range(11)] for _ in range(1)]
    assert qr.penalty(row) >= 40


def test_same_input_same_matrix() -> None:
    assert qr.make_qr("https://example.org") == qr.make_qr("https://example.org")


# --- symbol structure ----------------------------------------------------------------------


def finder_ok(m: list[list[bool]], r0: int, c0: int) -> bool:
    for dr in range(7):
        for dc in range(7):
            ring = dr in (0, 6) or dc in (0, 6)
            core = 2 <= dr <= 4 and 2 <= dc <= 4
            if m[r0 + dr][c0 + dc] != (ring or core):
                return False
    return True


@pytest.mark.parametrize("n", [1, 15, 27, 43, 63, 85, 107, 123, 153, 181])
def test_finders_timing_dark_module(n: int) -> None:
    m = qr.make_qr(text(n))
    size = len(m)
    assert finder_ok(m, 0, 0)
    assert finder_ok(m, 0, size - 7)
    assert finder_ok(m, size - 7, 0)
    for i in range(8, size - 8):
        assert m[6][i] == (i % 2 == 0)
        assert m[i][6] == (i % 2 == 0)
    assert m[size - 8][8] is True


def read_format(m: list[list[bool]]) -> int:
    bits = [m[i][8] for i in range(6)] + [m[7][8], m[8][8], m[8][7]]
    bits += [m[8][14 - i] for i in range(9, 15)]
    return sum(int(b) << i for i, b in enumerate(bits))


@pytest.mark.parametrize("mask", range(8))
def test_format_info_says_level_m_and_the_mask(mask: int) -> None:
    m = qr.make_qr(text(30), mask=mask)
    raw = read_format(m) ^ 0x5412
    data = raw >> 10
    assert data >> 3 == 0b00  # level M
    assert data & 0b111 == mask


# --- SVG -----------------------------------------------------------------------------------


CELL = re.compile(r"M(\d+) (\d+)h1v1h-1z")


def test_svg_draws_exactly_the_matrix_with_quiet_zone() -> None:
    m = qr.make_qr("https://music.example.org")
    svg = qr.to_svg(m)
    root = ET.fromstring(svg)
    assert root.tag == "{http://www.w3.org/2000/svg}svg"
    assert root.attrib["viewBox"] == "0 0 33 33"
    assert root.attrib["shape-rendering"] == "crispEdges"
    rect = root.find("{http://www.w3.org/2000/svg}rect")
    assert rect is not None
    assert rect.attrib["fill"] == "#fff"
    assert (rect.attrib["width"], rect.attrib["height"]) == ("33", "33")
    path = root.find("{http://www.w3.org/2000/svg}path")
    assert path is not None
    assert path.attrib["fill"] == "#000"
    d = path.attrib["d"]
    cells = {(int(y), int(x)) for x, y in CELL.findall(d)}
    assert CELL.sub("", d) == ""
    want = {(r + 4, c + 4) for r, row in enumerate(m) for c, x in enumerate(row) if x}
    assert cells == want


def test_svg_quiet_zone_is_configurable() -> None:
    m = qr.make_qr("a")
    root = ET.fromstring(qr.to_svg(m, quiet=2))
    assert root.attrib["viewBox"] == "0 0 25 25"
    d = root.find("{http://www.w3.org/2000/svg}path").attrib["d"]  # type: ignore[union-attr]
    assert "M2 2h1v1h-1z" in d


def test_svg_has_no_script_or_external_reference() -> None:
    svg = qr.to_svg(qr.make_qr("javascript:alert(1)<script>"))
    low = svg.lower()
    assert "<script" not in low
    assert "href" not in low
    assert "javascript" not in low
    assert "alert" not in low


# --- module cleanliness --------------------------------------------------------------------


def test_module_has_no_network_logging_or_third_party_imports() -> None:
    src = Path(qr.__file__).read_text(encoding="utf-8")
    tree = ast.parse(src)
    names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            names |= {a.name.split(".")[0] for a in node.names}
        elif isinstance(node, ast.ImportFrom) and node.module:
            names.add(node.module.split(".")[0])
    assert names <= {"__future__", "typing", "collections", "functools", "itertools"}
