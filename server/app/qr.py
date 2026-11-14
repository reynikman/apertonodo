"""QR code generator (Model 2, versions 1–10, error correction level M, byte mode).

ISO/IEC 18004 standard. Zero third-party dependencies.
"""

from __future__ import annotations

import itertools

MAX_VERSION: int = 10
MAX_BYTES: int = 213

# UTF-8 byte capacity for versions 1-10 with error correction level M (byte mode)
_CAPACITIES: tuple[tuple[int, int], ...] = (
    (1, 14),
    (2, 26),
    (3, 42),
    (4, 62),
    (5, 84),
    (6, 106),
    (7, 122),
    (8, 152),
    (9, 180),
    (10, 213),
)

# Reed-Solomon block parameters (V1-10, M):
# (ec_codewords_per_block, ((num_blocks, data_codewords_per_block), ...))
_RS_BLOCK_INFO: dict[int, tuple[int, tuple[tuple[int, int], ...]]] = {
    1: (10, ((1, 16),)),
    2: (16, ((1, 28),)),
    3: (26, ((1, 44),)),
    4: (18, ((2, 32),)),
    5: (24, ((2, 43),)),
    6: (16, ((4, 27),)),
    7: (18, ((4, 31),)),
    8: (22, ((2, 38), (2, 39))),
    9: (22, ((3, 36), (2, 37))),
    10: (26, ((4, 43), (1, 44))),
}

# Alignment pattern center coordinates for versions 1-10
_ALIGNMENT_CENTERS: dict[int, tuple[int, ...]] = {
    1: (),
    2: (6, 18),
    3: (6, 22),
    4: (6, 26),
    5: (6, 30),
    6: (6, 34),
    7: (6, 22, 38),
    8: (6, 24, 42),
    9: (6, 26, 46),
    10: (6, 28, 50),
}

# GF(256) exponent and log tables with generator polynomial 0x11D (285)
_EXP: list[int] = [0] * 512
_LOG: list[int] = [0] * 256

_val = 1
for _i in range(255):
    _EXP[_i] = _val
    _LOG[_val] = _i
    _val <<= 1
    if _val & 0x100:
        _val ^= 0x11D
for _i in range(255, 512):
    _EXP[_i] = _EXP[_i - 255]


def _gf_mul(a: int, b: int) -> int:
    if a == 0 or b == 0:
        return 0
    return _EXP[_LOG[a] + _LOG[b]]


def _rs_poly(k: int) -> list[int]:
    """Reed-Solomon generator polynomial of degree k: prod_{i=0}^{k-1} (x - alpha^i)."""
    poly = [1]
    for i in range(k):
        next_poly = [0] * (len(poly) + 1)
        root = _EXP[i]
        for j, coef in enumerate(poly):
            next_poly[j] ^= coef
            next_poly[j + 1] ^= _gf_mul(coef, root)
        poly = next_poly
    return poly


def _rs_remainder(data: list[int], k: int) -> list[int]:
    """Calculate k Reed-Solomon error correction codewords."""
    gen = _rs_poly(k)
    msg = list(data) + [0] * k
    for i in range(len(data)):
        lead = msg[i]
        if lead != 0:
            for j in range(k + 1):
                msg[i + j] ^= _gf_mul(lead, gen[j])
    return msg[len(data) :]


def version_for(text: str) -> int:
    """Smallest version 1-10 for UTF-8 text."""
    raw = text.encode("utf-8")
    length = len(raw)
    if length == 0 or length > MAX_BYTES:
        raise ValueError(f"Text length {length} out of range 1..{MAX_BYTES}")
    for version, cap in _CAPACITIES:
        if length <= cap:
            return version
    raise ValueError(f"Text length {length} out of range 1..{MAX_BYTES}")


def _get_format_bch(mask: int) -> int:
    """15 format bits: (EC M = 0b00, mask = 3 bits) + 10 BCH bits, XOR 0x5412."""
    val = mask << 10
    poly = 0x537
    for i in range(14, 9, -1):
        if (val >> i) & 1:
            val ^= poly << (i - 10)
    return ((mask << 10) | val) ^ 0x5412


def _get_version_bch(version: int) -> int:
    """18 version bits for versions 7-10: 6 version bits + 12 BCH bits (poly 0x1F25)."""
    val = version << 12
    poly = 0x1F25
    for i in range(17, 11, -1):
        if (val >> i) & 1:
            val ^= poly << (i - 12)
    return (version << 12) | val


def _encode_data(text: str, version: int) -> list[int]:
    """Encode data in byte mode with Reed-Solomon and interleaving."""
    raw = text.encode("utf-8")
    bits: list[int] = [0, 1, 0, 0]  # Byte mode = 0100

    # Character count: 8 bits for versions 1-9, 16 bits for version 10
    count_bits = 16 if version == 10 else 8
    for i in range(count_bits - 1, -1, -1):
        bits.append((len(raw) >> i) & 1)

    for byte in raw:
        for i in range(7, -1, -1):
            bits.append((byte >> i) & 1)

    ec_per_block, block_specs = _RS_BLOCK_INFO[version]
    total_data_cw = sum(num * cw for num, cw in block_specs)
    total_data_bits = total_data_cw * 8

    # Terminator up to 4 zeros
    term_len = min(4, total_data_bits - len(bits))
    bits.extend([0] * term_len)

    # Zero padding to byte boundary
    if len(bits) % 8 != 0:
        bits.extend([0] * (8 - len(bits) % 8))

    codewords: list[int] = []
    for i in range(0, len(bits), 8):
        byte_val = 0
        for bit in bits[i : i + 8]:
            byte_val = (byte_val << 1) | bit
        codewords.append(byte_val)

    # Pad bytes 0xEC and 0x11
    pad_bytes = (0xEC, 0x11)
    pad_idx = 0
    while len(codewords) < total_data_cw:
        codewords.append(pad_bytes[pad_idx % 2])
        pad_idx += 1

    # Split into data blocks and compute Reed-Solomon
    data_blocks: list[list[int]] = []
    ec_blocks: list[list[int]] = []
    offset = 0
    for num_b, cw_per_b in block_specs:
        for _ in range(num_b):
            block_data = codewords[offset : offset + cw_per_b]
            offset += cw_per_b
            data_blocks.append(block_data)
            ec_blocks.append(_rs_remainder(block_data, ec_per_block))

    # Interleave data blocks and error correction blocks
    interleaved: list[int] = []
    max_data_len = max(len(b) for b in data_blocks)
    for i in range(max_data_len):
        for b in data_blocks:
            if i < len(b):
                interleaved.append(b[i])

    for i in range(ec_per_block):
        for b in ec_blocks:
            interleaved.append(b[i])

    return interleaved


def _make_base_matrix(version: int) -> tuple[list[list[bool]], list[list[bool]]]:
    """Construct functional modules (finder patterns, timing, alignment, dark module)."""
    size = 17 + 4 * version
    matrix: list[list[bool]] = [[False] * size for _ in range(size)]
    reserved: list[list[bool]] = [[False] * size for _ in range(size)]

    def set_module(r: int, c: int, val: bool) -> None:
        matrix[r][c] = val
        reserved[r][c] = True

    # 1. Finder patterns (7x7)
    def add_finder(r0: int, c0: int) -> None:
        for dr in range(7):
            for dc in range(7):
                ring = dr in (0, 6) or dc in (0, 6)
                core = 2 <= dr <= 4 and 2 <= dc <= 4
                set_module(r0 + dr, c0 + dc, ring or core)

    add_finder(0, 0)
    add_finder(0, size - 7)
    add_finder(size - 7, 0)

    # Separators (white border around finder patterns)
    for i in range(8):
        set_module(7, i, False)
        set_module(i, 7, False)
        set_module(7, size - 8 + i, False)
        set_module(i, size - 8, False)
        set_module(size - 8, i, False)
        set_module(size - 8 + i, 7, False)

    # 2. Timing patterns
    for i in range(8, size - 8):
        set_module(6, i, i % 2 == 0)
        set_module(i, 6, i % 2 == 0)

    # 3. Alignment patterns
    centers = _ALIGNMENT_CENTERS[version]
    for r in centers:
        for c in centers:
            if (
                (r == 6 and c == 6)
                or (r == 6 and c == centers[-1])
                or (r == centers[-1] and c == 6)
            ):
                continue
            for dr in range(-2, 3):
                for dc in range(-2, 3):
                    dist = max(abs(dr), abs(dc))
                    set_module(r + dr, c + dc, dist != 1)

    # 4. Dark module
    set_module(size - 8, 8, True)

    # 5. Format info area reservation
    for i in range(9):
        reserved[8][i] = True
        reserved[i][8] = True
    for i in range(size - 8, size):
        reserved[8][i] = True
        reserved[i][8] = True

    # 6. Version info area reservation (versions 7-10)
    if version >= 7:
        for r in range(size - 11, size - 8):
            for c in range(6):
                reserved[r][c] = True
        for r in range(6):
            for c in range(size - 11, size - 8):
                reserved[r][c] = True

    return matrix, reserved


def _fill_and_mask(
    base_matrix: list[list[bool]],
    reserved: list[list[bool]],
    data_cw: list[int],
    version: int,
    mask: int,
) -> list[list[bool]]:
    """Zigzag data placement, masking, and format/version bits writing."""
    size = len(base_matrix)
    result = [list(row) for row in base_matrix]

    # Zigzag data placement from right to left in two-column pairs
    col = size - 1
    row = size - 1
    inc = -1
    byte_idx = 0
    bit_idx = 7

    while col > 0:
        if col == 6:
            col -= 1
        for c_offset in range(2):
            c = col - c_offset
            if not reserved[row][c]:
                dark = False
                if byte_idx < len(data_cw):
                    dark = bool((data_cw[byte_idx] >> bit_idx) & 1)
                    bit_idx -= 1
                    if bit_idx < 0:
                        byte_idx += 1
                        bit_idx = 7
                # Check mask condition 0-7
                masked = False
                if mask == 0:
                    masked = (row + c) % 2 == 0
                elif mask == 1:
                    masked = row % 2 == 0
                elif mask == 2:
                    masked = c % 3 == 0
                elif mask == 3:
                    masked = (row + c) % 3 == 0
                elif mask == 4:
                    masked = (row // 2 + c // 3) % 2 == 0
                elif mask == 5:
                    masked = (row * c) % 2 + (row * c) % 3 == 0
                elif mask == 6:
                    masked = ((row * c) % 2 + (row * c) % 3) % 2 == 0
                elif mask == 7:
                    masked = ((row + c) % 2 + (row * c) % 3) % 2 == 0

                if masked:
                    dark = not dark
                result[row][c] = dark
        row += inc
        if row < 0 or row >= size:
            inc = -inc
            row += inc
            col -= 2

    # Write format information (two copies)
    fmt_bits = _get_format_bch(mask)
    for i in range(15):
        mod = bool((fmt_bits >> i) & 1)
        if i < 6:
            result[i][8] = mod
        elif i < 8:
            result[i + 1][8] = mod
        else:
            result[size - 15 + i][8] = mod

    for i in range(15):
        mod = bool((fmt_bits >> i) & 1)
        if i < 8:
            result[8][size - i - 1] = mod
        elif i < 9:
            result[8][15 - i - 1 + 1] = mod
        else:
            result[8][15 - i - 1] = mod

    # Write version information (two copies for versions 7-10)
    if version >= 7:
        ver_bits = _get_version_bch(version)
        for i in range(18):
            mod = bool((ver_bits >> i) & 1)
            result[i // 3][size - 11 + i % 3] = mod
            result[size - 11 + i % 3][i // 3] = mod

    return result


def penalty(matrix: list[list[bool]]) -> int:
    """Evaluate mask penalty according to standard four rules."""
    size = len(matrix)
    rows = ["".join("1" if x else "0" for x in row) for row in matrix]
    cols = ["".join(rows[r][c] for r in range(size)) for c in range(size)]
    score = 0
    for line in rows + cols:
        for _, group in itertools.groupby(line):
            run_len = len(list(group))
            if run_len >= 5:
                score += run_len - 2
        for pat in ("10111010000", "00001011101"):
            score += 40 * sum(1 for i in range(size) if line.startswith(pat, i))
    for r in range(size - 1):
        for c in range(size - 1):
            if rows[r][c] == rows[r][c + 1] == rows[r + 1][c] == rows[r + 1][c + 1]:
                score += 3
    dark = sum(row.count("1") for row in rows)
    score += 10 * (abs(dark * 20 - size * size * 10) // (size * size))
    return score


def make_qr(text: str, *, mask: int | None = None) -> list[list[bool]]:
    """Create QR code matrix without quiet zone (elements strictly bool)."""
    if mask is not None and (not isinstance(mask, int) or mask < 0 or mask > 7):
        raise ValueError(f"Mask must be in range 0..7, got {mask}")

    version = version_for(text)
    base_matrix, reserved = _make_base_matrix(version)
    data_cw = _encode_data(text, version)

    if mask is not None:
        return _fill_and_mask(base_matrix, reserved, data_cw, version, mask)

    # Automatically choose mask with lowest penalty
    best_matrix: list[list[bool]] | None = None
    best_penalty: int | None = None
    for k in range(8):
        candidate = _fill_and_mask(base_matrix, reserved, data_cw, version, k)
        sc = penalty(candidate)
        if best_penalty is None or sc < best_penalty:
            best_penalty = sc
            best_matrix = candidate
    assert best_matrix is not None
    return best_matrix


def to_svg(matrix: list[list[bool]], *, quiet: int = 4) -> str:
    """Generate SVG image of QR code with quiet zone."""
    size = len(matrix)
    total = size + 2 * quiet
    d = "".join(
        f"M{c + quiet} {r + quiet}h1v1h-1z"
        for r, row in enumerate(matrix)
        for c, cell in enumerate(row)
        if cell
    )
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {total} {total}" '
        f'shape-rendering="crispEdges">'
        f'<rect fill="#fff" width="{total}" height="{total}"/>'
        f'<path fill="#000" d="{d}"/>'
        f"</svg>"
    )
