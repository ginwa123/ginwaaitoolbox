---
name: rfc-tables-and-vectors-from-reference-oracle
description: "How to implement a wire protocol's constant tables (HPACK Huffman/static table, compression tables, magic constants) and its conformance tests without transcription errors — generate both from the RFC text PLUS a reference implementation, and refuse to emit when they disagree."
---
---
name: rfc-tables-and-vectors-from-reference-oracle
description: How to implement a wire protocol's constant tables (HPACK Huffman/static table, compression tables, magic constants) and its conformance tests without transcription errors — generate both from the RFC text PLUS a reference implementation, and refuse to emit when they disagree.
tags: [pattern, workflow, protocol, testing, generated-code]
---

## When to Use

Implementing any byte-exact protocol layer that depends on big constant tables or
published test vectors: HPACK/QPACK tables, HPACK Huffman codes, HTTP/3 frame
types, protobuf varint edge cases, TLS cipher tables. Trigger: the spec appendix
contains hundreds of entries you would otherwise hand-transcribe.

## Context

* RFC text is fetchable as plain text: `https://www.rfc-editor.org/rfc/rfc<num>.txt`.
* Python reference implementations exist for most protocols (`pip install hpack h2`
  for HTTP/2; `pip install aioquic` for HTTP/3/QUIC). Dev-time only — the
  generated files are committed, so no runtime dependency is added.

## Procedure

1. Write ONE generator script, committed to the repo (`tools/gen_<x>_tables.py`),
   that takes `--rfc <path>` + output paths so it is reproducible later.
2. Parse the tables from the RFC text with a regex per table, and **assert the
   expected row count** (e.g. `== 257` for HPACK Huffman, `== 61` for the static
   table) — a short parse must be a hard error, never a silent subset.
3. Import the reference implementation in the same script and **cross-check every
   row**; `raise SystemExit` with the disagreeing row on any mismatch. Emit only
   after both sources agree. This turns "did I transcribe it right?" into a
   machine-checked question.
4. Extract the RFC's own conformance vectors (Appendix C-style hex dumps) from the
   text, and take the *expected decoded values* from the RFC's own tables where
   present; where they are not machine-readable, decode the vectors with the
   reference implementation and additionally verify at least one decoded table
   against the RFC prose.
5. Emit two artefacts with a "GENERATED — DO NOT EDIT" header and the exact
   regeneration command: (a) the Zig table(s), (b) a vectors file used only by
   tests (`Pair`/`Step`/`Case` structs so stateful sequences like HPACK's dynamic
   table can be modelled as ordered steps decoded by ONE decoder).
6. Wire the vectors into tests as the acceptance gate, plus property tests
   (encode→decode round-trip over seeded random inputs) and negative tests
   (oversize, truncated, EOS-in-stream, bomb guards).
7. Document regeneration in the protocol doc, and commit both the generator and
   the generated files.

## Pitfalls

* **RFC .txt formatting quirks** (all hit in RFC 7541 Appendix B): table rows for
  printable symbols carry a leading `'x' ` column; the EOS row is labelled
  `EOS (256)` not `( 256)`; long hex dumps are interrupted by page-break artifacts
  (`RFC 7541 ... [Page N]`) that must be stripped *before* line-based parsing.
  Validate the parser by decoding the extracted vectors and comparing to the
  RFC's published decoded header lists — a wrong regex shows up as a mismatch, not
  as garbage output later.
* **Do not trust a prompt's hand-typed test vectors.** In one session two
  "RFC anchors" supplied by the implementer were wrong (one was the Huffman
  payload of a different string). Vectors must come from the RFC/generator, and if
  a hand-written anchor disagrees, trust the RFC and fix the anchor.
* A generator that "succeeds" while emitting fewer rows than the spec requires is
  the most dangerous outcome — hence the hard row-count assertion.
* Reference implementations also have version-specific module layout
  (`hpack.table.HeaderTable.STATIC_TABLE`, `hpack.huffman_constants.REQUEST_CODES`
  in hpack 4.x) — introspect with `dir()` instead of guessing import paths, and
  don't mask the real `ImportError` behind a generic message.

## Verification

* Generator exits non-zero when either source is edited to disagree (test the
  cross-check itself at least once).
* The generated vectors fail loudly against a deliberately broken implementation
  (e.g. flip one Huffman code) — otherwise they are not really gating anything.
* Test suite runs with a leak-checking allocator (`std.testing.allocator`) and
  reports the vector count exercised.

