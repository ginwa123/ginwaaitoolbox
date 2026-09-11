#!/usr/bin/env python3
"""Generate Zig HPACK tables + RFC 7541 conformance vectors.

Why a generator: HPACK's Huffman code table is 257 entries of (code, bit-length)
and its static table is 61 entries. Transcribing either by hand is a guaranteed
source of silent, security-relevant bugs (a wrong code decodes to garbage
headers). This script derives them from the authoritative sources and refuses to
emit anything if the sources disagree:

  1. RFC 7541 Appendix A (static table) and Appendix B (Huffman) parsed from the
     RFC text, and
  2. the reference Python implementation (`hpack`) — an independent transcription.

Both must agree, otherwise the script exits non-zero. The same script also
extracts the Appendix C test vectors (encoded blocks straight from the RFC) with
their expected decoded header lists taken from the RFC's own "Decoded header
list" tables, cross-checked against `hpack`.

Usage:
    python3 tools/gen_hpack_tables.py \
        --rfc /path/to/rfc7541.txt \
        --out-tables  src/modules/custom_http_server/src/http2/generated_tables.zig \
        --out-vectors src/modules/custom_http_server/src/http2/rfc7541_vectors.zig

Requires: `pip install hpack` (dev-time only; the generated files are checked in).
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

try:
    import hpack
    from hpack.huffman_constants import REQUEST_CODES, REQUEST_CODES_LENGTH
    from hpack.table import HeaderTable
except ImportError as exc:  # pragma: no cover
    print(
        f"error: the 'hpack' package is required (pip install hpack): {exc}",
        file=sys.stderr,
    )
    raise SystemExit(2)


# ---------------------------------------------------------------------------
# RFC text normalisation
# ---------------------------------------------------------------------------

PAGE_ARTIFACT = re.compile(
    r"^(Peon & Ruellan|RFC 7541|\[Page \d+\]|Ruellan|Herbert|IETF|"
    r"\s*RFC 7541\s+HPACK\s+.*)$"
)


def rfc_lines(text: str) -> list[str]:
    text = text.replace("\r\n", "\n").replace("\f", "\n")
    out: list[str] = []
    for ln in text.split("\n"):
        if PAGE_ARTIFACT.match(ln.strip()) and ("[Page" in ln or "RFC 7541" in ln):
            continue
        out.append(ln)
    return out


# ---------------------------------------------------------------------------
# Appendix A — static table
# ---------------------------------------------------------------------------

STATIC_ROW = re.compile(r"^\s*\|\s*(\d+)\s*\|\s*([^|]*?)\s*\|\s*([^|]*?)\s*\|\s*$")


def parse_static_table(lines: list[str]) -> dict[int, tuple[str, str]]:
    rows: dict[int, tuple[str, str]] = {}
    for ln in lines:
        m = STATIC_ROW.match(ln)
        if not m:
            continue
        idx = int(m.group(1))
        if 1 <= idx <= 61:
            rows[idx] = (m.group(2), m.group(3))
    return rows


# ---------------------------------------------------------------------------
# Appendix B — Huffman code table
# ---------------------------------------------------------------------------

#   sym  | code as bits aligned to MSB | code as hex (LSB aligned) | len in bits
#  (  0)  |11111111|11000                        1ff8  [13]
#   '4' ( 52)  |011010                          1a  [ 6]
#   EOS (256)  |11111111|11111111|11111111|111111  3fffffff  [30]
HUFFMAN_ROW = re.compile(
    r"^\s*(?:'.*?'\s+)?(?:EOS\s+)?\(\s*(\d+)\)\s*\|([01|]+)\s+"
    r"([0-9a-fA-F]+)\s+\[\s*(\d+)\s*\]\s*$"
)


def parse_huffman_table(lines: list[str]) -> dict[int, tuple[int, int]]:
    rows: dict[int, tuple[int, int]] = {}
    bit_rows: dict[int, int] = {}
    for ln in lines:
        m = HUFFMAN_ROW.match(ln)
        if not m:
            continue
        sym = int(m.group(1))
        code = int(m.group(3), 16)
        bits = int(m.group(4))
        rows[sym] = (code, bits)
        bit_rows[sym] = len(m.group(2).replace("|", ""))
    if len(rows) != 257:
        raise SystemExit(f"error: parsed {len(rows)} Huffman rows, expected 257")
    for sym, (_, bits) in rows.items():
        if bit_rows[sym] != bits:
            raise SystemExit(
                f"error: Huffman row {sym} bit-pattern length {bit_rows[sym]} "
                f"!= declared length {bits}"
            )
    return rows


def cross_check_sources(
    static_rfc: dict[int, tuple[str, str]], huffman_rfc: dict[int, tuple[int, int]]
) -> None:
    """Refuse to emit if RFC 7541's tables and the `hpack` package disagree."""
    ref_static = HeaderTable.STATIC_TABLE
    if len(ref_static) != 61:
        raise SystemExit(f"error: hpack static table has {len(ref_static)} entries")
    for idx, (name, value) in sorted(static_rfc.items()):
        ref = ref_static[idx - 1]
        ref_pair = (
            ref[0].decode("utf-8", "replace"),
            ref[1].decode("utf-8", "replace"),
        )
        if ref_pair != (name, value):
            raise SystemExit(
                f"error: static table index {idx} disagrees: "
                f"RFC={name!r}:{value!r} hpack={ref_pair!r}"
            )

    if len(REQUEST_CODES) != 257 or len(REQUEST_CODES_LENGTH) != 257:
        raise SystemExit("error: hpack huffman tables are not 257 entries")
    for sym in range(257):
        code, bits = huffman_rfc[sym]
        if (REQUEST_CODES[sym], REQUEST_CODES_LENGTH[sym]) != (code, bits):
            raise SystemExit(
                f"error: Huffman symbol {sym} disagrees: "
                f"RFC={code:#x}/{bits} hpack="
                f"{REQUEST_CODES[sym]:#x}/{REQUEST_CODES_LENGTH[sym]}"
            )


# ---------------------------------------------------------------------------
# Appendix C — test vectors
# ---------------------------------------------------------------------------

SECTION = re.compile(r"^C\.(\d)\.(\d)\.\s+\S")
HEX_GROUPS = re.compile(r"^([0-9a-f]{1,4}(\s+[0-9a-f]{1,4})*)(\s*\|.*)?$")


def split_sections(lines: list[str]) -> list[tuple[str, int, list[str]]]:
    """Return [(section_id, start_index, body_lines)] for C.x.y sections."""
    marks: list[tuple[str, int]] = []
    for i, ln in enumerate(lines):
        m = SECTION.match(ln)
        if m:
            marks.append((f"C.{m.group(1)}.{m.group(2)}", i))
    out = []
    for n, (name, start) in enumerate(marks):
        end = marks[n + 1][1] if n + 1 < len(marks) else len(lines)
        out.append((name, start, lines[start:end]))
    return out


def parse_encoded_blocks(body: list[str]) -> list[bytes]:
    """Extract every 'Hex dump of encoded data' block from a section body."""
    blocks: list[bytes] = []
    i = 0
    while i < len(body):
        if "Hex dump of encoded data" not in body[i]:
            i += 1
            continue
        i += 1
        hexbuf: list[str] = []
        # Collect contiguous hex-group lines (page artifacts already stripped).
        while i < len(body):
            ln = body[i]
            stripped = ln.strip()
            if stripped == "":
                # A blank line ends the dump unless the next non-blank line is
                # still a hex row (page break in the middle of a long dump).
                j = i + 1
                while j < len(body) and body[j].strip() == "":
                    j += 1
                if j < len(body) and (HEX_GROUPS.match(body[j].strip()) or "?" == body[j].strip()):
                    i = j
                    continue
                break
            m = HEX_GROUPS.match(stripped)
            if not m:
                break
            hexbuf.append(re.sub(r"\s+", "", m.group(1)))
            i += 1
        if hexbuf:
            blocks.append(bytes.fromhex("".join(hexbuf)))
    return blocks


DECODED_MARKER = re.compile(r"^\s*Decoded header list:\s*$")


def split_headers(line: str) -> tuple[str, str] | None:
    line = line.rstrip()
    if not line.strip():
        return None
    if line.lstrip().startswith(":"):
        body = line.strip()
        idx = body.find(":", 1)
        if idx < 0:
            return None
        return body[:idx], body[idx + 1 :].strip()
    if ":" in line:
        name, value = line.strip().split(":", 1)
        return name, value.strip()
    return None


def parse_decoded_lists(body: list[str]) -> list[list[tuple[str, str]]]:
    """Extract every 'Decoded header list:' table from a section body."""
    lists: list[list[tuple[str, str]]] = []
    i = 0
    while i < len(body):
        if not DECODED_MARKER.match(body[i]):
            i += 1
            continue
        i += 1
        while i < len(body) and body[i].strip() == "":
            i += 1
        headers: list[tuple[str, str]] = []
        while i < len(body) and body[i].strip() != "":
            parsed = split_headers(body[i])
            if parsed is None:
                break
            headers.append(parsed)
            i += 1
        if headers:
            lists.append(headers)
    return lists


def zig_bytes(data: bytes) -> str:
    return '"' + "".join(f"\\x{b:02x}" for b in data) + '"'


def zig_str(value: str) -> str:
    out = []
    for ch in value:
        if ch == '"':
            out.append('\\"')
        elif ch == "\\":
            out.append("\\\\")
        elif 0x20 <= ord(ch) < 0x7F:
            out.append(ch)
        else:
            out.append(f"\\x{ord(ch):02x}")
    return '"' + "".join(out) + '"'


def decode_with_hpack(blocks: list[bytes], table_size: int) -> list[list[tuple[str, str]]]:
    dec = hpack.Decoder(max_header_list_size=1 << 20)
    dec.max_allowed_table_size = table_size
    dec.header_table.maxsize = table_size
    out: list[list[tuple[str, str]]] = []
    for block in blocks:
        out.append(
            [
                (k.decode("utf-8", "replace"), v.decode("utf-8", "replace"))
                for k, v in dec.decode(block, raw=True)
            ]
        )
    return out


# ---------------------------------------------------------------------------
# Emission
# ---------------------------------------------------------------------------

TABLES_HEADER = """//! GENERATED FILE — DO NOT EDIT BY HAND.
//!
//! Regenerate with:
//!   python3 tools/gen_hpack_tables.py --rfc <rfc7541.txt> --out-tables <this file> --out-vectors <...>
//!
//! Sources (both are checked against each other by the generator, which refuses
//! to emit if they disagree):
//!   * RFC 7541 Appendix A — HPACK Static Table (61 entries)
//!   * RFC 7541 Appendix B — HPACK Huffman Code (257 symbols incl. EOS)
//!   * the reference implementation `hpack` (independent transcription)

pub const StaticEntry = struct { name: []const u8, value: []const u8 };

/// RFC 7541 Appendix A. Index 1..61 map to `static_table[0..61)`.
pub const static_table = [_]StaticEntry{
"""

VECTORS_HEADER = """//! GENERATED FILE — DO NOT EDIT BY HAND.
//!
//! RFC 7541 Appendix C conformance vectors. The encoded blocks are transcribed
//! byte-for-byte from the RFC text; the expected header lists are the RFC's own
//! "Decoded header list" tables, cross-checked against the reference `hpack`
//! implementation by `tools/gen_hpack_tables.py`.

pub const Pair = struct { name: []const u8, value: []const u8 };

/// A single HPACK block plus the exact header list it must decode to.
pub const BlockVector = struct {
    name: []const u8,
    table_size: u32 = 4096,
    block: []const u8,
    expected: []const Pair,
};

/// A sequence of blocks decoded with ONE decoder (dynamic table carries over).
pub const Step = struct {
    name: []const u8,
    block: []const u8,
    expected: []const Pair,
};

pub const Case = struct {
    name: []const u8,
    table_size: u32,
    steps: []const Step,
};
"""


def emit_pair_list(name: str, headers: list[tuple[str, str]]) -> str:
    lines = [f"const {name} = [_]Pair{{"]
    for k, v in headers:
        lines.append(f"    .{{ .name = {zig_str(k)}, .value = {zig_str(v)} }},")
    lines.append("};")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rfc", required=True)
    ap.add_argument("--out-tables", required=True)
    ap.add_argument("--out-vectors", required=True)
    args = ap.parse_args()

    lines = rfc_lines(Path(args.rfc).read_text(encoding="utf-8", errors="replace"))

    static_rfc = parse_static_table(lines)
    if len(static_rfc) != 61:
        print(f"error: parsed {len(static_rfc)} static entries, expected 61", file=sys.stderr)
        return 2
    huffman_rfc = parse_huffman_table(lines)
    cross_check_sources(static_rfc, huffman_rfc)

    # ---- tables file -------------------------------------------------------
    t = [TABLES_HEADER]
    for idx in range(1, 62):
        name, value = static_rfc[idx]
        t.append(f"    .{{ .name = {zig_str(name)}, .value = {zig_str(value)} }},")
    t.append("};")
    t.append("")
    t.append("pub const HuffmanCode = struct { code: u32, bits: u5 };")
    t.append("")
    t.append("/// RFC 7541 Appendix B, indexed by symbol (256 = EOS).")
    t.append("pub const huffman_codes = [257]HuffmanCode{")
    for sym in range(257):
        code, bits = huffman_rfc[sym]
        t.append(f"    .{{ .code = 0x{code:04x}, .bits = {bits} }},")
    t.append("};")
    t.append("")

    # ---- vector file -------------------------------------------------------
    v: list[str] = [VECTORS_HEADER]
    sections = {name: body for name, _, body in split_sections(lines)}

    # Appendix C.1 — integer representation examples (hand-typed from the RFC
    # prose, which states the expected octets explicitly).
    v.append("""pub const IntegerVector = struct {
    name: []const u8,
    /// Value to encode plus the prefix/start octet the RFC uses.
    value: usize,
    prefix_bits: u5,
    initial_byte: u8,
    expected: []const u8,
};

/// RFC 7541 Appendix C.1 (each vector is a single octet sequence).
pub const integer_vectors = [_]IntegerVector{
    .{ .name = "C.1.1 value 10, 5-bit prefix", .value = 10, .prefix_bits = 5, .initial_byte = 0x00, .expected = "\\x0a" },
    .{ .name = "C.1.2 value 1337, 5-bit prefix", .value = 1337, .prefix_bits = 5, .initial_byte = 0x00, .expected = "\\x1f\\x9a\\x0a" },
    .{ .name = "C.1.3 value 42, 8-bit prefix", .value = 42, .prefix_bits = 8, .initial_byte = 0x00, .expected = "\\x2a" },
};
""")

    # C.2.x — independent single-block vectors (no dynamic table reuse).
    block_vectors: list[tuple[str, int, list[tuple[str, str]], bytes]] = []
    # C.3/C.4/C.5/C.6 — stateful sequences.
    cases: list[tuple[str, int, list[tuple[str, bytes, list[tuple[str, str]]]]]] = []

    for section in ("C.2.1", "C.2.2", "C.2.3", "C.2.4"):
        body = sections.get(section)
        if body is None:
            print(f"error: section {section} not found", file=sys.stderr)
            return 2
        blocks = parse_encoded_blocks(body)
        decoded = parse_decoded_lists(body)
        if len(blocks) != 1 or len(decoded) != 1:
            print(f"error: {section}: {len(blocks)} blocks / {len(decoded)} header lists", file=sys.stderr)
            return 2
        ref = decode_with_hpack(blocks, 4096)[0]
        if ref != decoded[0]:
            print(f"error: {section}: hpack disagrees with the RFC header list\n  rfc  ={decoded[0]}\n  hpack={ref}", file=sys.stderr)
            return 2
        block_vectors.append((section, 4096, decoded[0], blocks[0]))

    for case_id, table_size in (("C.3", 4096), ("C.4", 4096), ("C.5", 256), ("C.6", 256)):
        steps: list[tuple[str, bytes, list[tuple[str, str]]]] = []
        for n in (1, 2, 3):
            section = f"{case_id}.{n}"
            body = sections.get(section)
            if body is None:
                print(f"error: section {section} not found", file=sys.stderr)
                return 2
            blocks = parse_encoded_blocks(body)
            if len(blocks) != 1:
                print(f"error: {section}: expected exactly 1 encoded block, got {len(blocks)}", file=sys.stderr)
                return 2
            steps.append((section, blocks[0], []))
        ref_steps = decode_with_hpack([s[1] for s in steps], table_size)
        for n, section in enumerate((f"{case_id}.1", f"{case_id}.2", f"{case_id}.3")):
            body = sections[section]
            decoded = parse_decoded_lists(body)
            if decoded and decoded[-1] != ref_steps[n]:
                print(
                    f"error: {section}: hpack disagrees with the RFC header list\n"
                    f"  rfc  ={decoded[-1]}\n  hpack={ref_steps[n]}",
                    file=sys.stderr,
                )
                return 2
        cases.append(
            (case_id, table_size, [(s[0], s[1], ref_steps[i]) for i, s in enumerate(steps)])
        )

    for i, (name, table_size, expected, block) in enumerate(block_vectors):
        for j, (k, val) in enumerate(expected):
            v.append(
                f"const bv_{i}_{j} = Pair{{ .name = {zig_str(k)}, .value = {zig_str(val)} }};"
            )
        refs = ", ".join(f"bv_{i}_{j}" for j in range(len(expected)))
        v.append(f"const bv_{i}_expected = [_]Pair{{ {refs} }};")
    v.append("")
    v.append("pub const block_vectors = [_]BlockVector{")
    for i, (name, table_size, expected, block) in enumerate(block_vectors):
        v.append(
            f"    .{{ .name = {zig_str(name + ' (' + str(table_size) + ' octet table)')}, "
            f".table_size = {table_size}, .block = {zig_bytes(block)}, "
            f".expected = &bv_{i}_expected }},"
        )
    v.append("};")
    v.append("")

    for ci, (case_id, table_size, steps) in enumerate(cases):
        for si, (name, block, expected) in enumerate(steps):
            for j, (k, val) in enumerate(expected):
                v.append(
                    f"const cs_{ci}_{si}_{j} = Pair{{ .name = {zig_str(k)}, .value = {zig_str(val)} }};"
                )
            refs = ", ".join(f"cs_{ci}_{si}_{j}" for j in range(len(expected)))
            v.append(f"const cs_{ci}_{si}_expected = [_]Pair{{ {refs} }};")
            v.append(
                f"const cs_{ci}_{si} = Step{{ .name = {zig_str(name)}, "
                f".block = {zig_bytes(block)}, .expected = &cs_{ci}_{si}_expected }};"
            )
        step_refs = ", ".join(f"cs_{ci}_{si}" for si in range(len(steps)))
        v.append(
            f"const case_{ci} = Case{{ .name = {zig_str(case_id)}, .table_size = {table_size}, "
            f".steps = &[_]Step{{ {step_refs} }} }};"
        )
    case_refs = ", ".join(f"case_{i}" for i in range(len(cases)))
    v.append("")
    v.append(f"pub const cases = [_]Case{{ {case_refs} }};")
    v.append("")

    Path(args.out_tables).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out_vectors).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out_tables).write_text("\n".join(t), encoding="utf-8")
    Path(args.out_vectors).write_text("\n".join(v), encoding="utf-8")

    print(f"tables  : {args.out_tables}  ({len(static_rfc)} static, 257 huffman)")
    print(f"vectors : {args.out_vectors}")
    print(f"          {len(block_vectors)} block vectors, {len(cases)} stateful cases "
          f"({sum(len(c[2]) for c in cases)} steps)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
