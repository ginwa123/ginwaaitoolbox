# show_preview `path` parameter — render local image files

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `path` parameter to `show_preview` so the agent can hand the server an absolute path to a local image file. The server reads the file, MIME-sniffs via magic bytes, base64-encodes the bytes, and emits the same `<show_preview>` envelope that a hand-written data URL would produce. Frontend unchanged — the existing `imageSrc` computed in `PreviewContentRenderer.vue` already renders `data:` URLs.

**Architecture:** Extend the Zig tool's `ShowPreviewInput` struct with one optional `path` field. New helper `resolveImageContentFromPath` handles the read + MIME sniff + base64 encode. Cross-validate `path` against `content_type` (must be `"image"`) and `content` (must be empty). Reuse the existing render path — no frontend changes.

**Tech Stack:** Zig 0.16 (existing `show_preview.zig`), Zig `std.testing` (existing `show_preview_test.zig`), `std.base64.standard.Encoder` for base64 encoding, `std.Io.Dir.cwd().readFileAlloc` for file reading (same pattern as `read_file.zig`).

## Global Constraints

- **NO static-contract tests** — user rule (2026-07-29). All new tests are behavioural: call `resolveImageContentFromPath` and assert the return; call `executeShowPreviewToString` and assert the envelope. The pre-existing schema-test pattern (`.name = "..."` grep) IS allowed because the file already has 6 of them; we add 1 new schema check for the new `path` property.
- **Surgical patches only** — don't refactor `show_preview.zig`. Add the new `path` field, the new `resolveImageContentFromPath` helper, and a small cross-validation block in `executeShowPreviewToString`.
- **MIME detection via magic bytes only** — never trust the file extension. The agent could rename `/etc/passwd` to `passwd.png` and try to preview it; magic-byte sniffing rejects it because the actual bytes don't match PNG/JPEG/GIF/WebP signatures.
- **Same threat model as `read_file`** — the LLM can read any file the `nalar` process can read. No sandboxing added (would require a separate allow-list work).
- **1 MiB cap already covers the data URL output** — `MAX_CONTENT_BYTES = 1024 * 1024` is the cap on the resulting `data:image/...;base64,...` string. Raw files >~750 KB are rejected so the SSE payload stays under the limit.
- **Cross-platform** — Zig paths work identically on Linux/macOS/Windows. `std.Io.Dir.cwd().readFileAlloc` is cross-platform (works on Windows since Zig 0.16).

## File Structure

### Files to modify (surgical patches only)

| File | Why |
|---|---|
| `src/modules/agent/tools/show_preview.zig` | Add `path: ?[]const u8 = null` to `ShowPreviewInput`; add `detectImageMime` helper; add `pub fn resolveImageContentFromPath`; cross-validate `path` vs `content_type` vs `content` in `executeShowPreviewToString`; update tool description + schema to mention the new field. |
| `src/modules/agent/tools/show_preview_test.zig` | Add 12 new tests: 7 for `resolveImageContentFromPath` (PNG/JPEG/GIF/WebP detection, unknown format, missing file, too-large), 4 for `executeShowPreviewToString` (path-only success, both content + path error, wrong content_type error, content-only back-compat), 1 schema check for the new `path` property. |
| `AGENTS.md` | Add changelog entry under "Recent changes (2026-08-06)". |
| `docs/SPEC.md` §10.2.1 (PR index) — add a new PR entry for this feature once merged. |

### Files NOT to modify (intentionally out of scope)

- `src/apps/desktop/src/components/preview/PreviewContentRenderer.vue` — the existing `imageSrc` computed already handles `data:` URLs. No change needed.
- `src/apps/desktop/src/components/tool_outputs/ShowPreview.vue` — passes the args straight through to the renderer. No change needed.
- `src/ai_workflow/tui/agentic_loop/tools_exec_show_preview.zig` — generic executor; no per-content_type branch needed.
- `src/modules/agent/tools/schemas.zig` — `AgentTool` schema is generic; no per-tool changes.
- The `path` could be added to the system prompt's `show_preview` description (currently the tool description is the only prompt), but that's a follow-up — the tool's own description (updated here) is what the LLM sees.

## Implementation Detail

### `resolveImageContentFromPath` signature

```zig
pub fn resolveImageContentFromPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) ![]u8
```

Returns the `data:image/<mime>;base64,<payload>` string. Errors:
- `error.FileNotFound` — path doesn't exist (or is a directory)
- `error.UnsupportedImageFormat` — magic bytes don't match
- `error.ImageTooLarge` — resulting data URL exceeds `MAX_CONTENT_BYTES`

Caller owns the returned slice.

### Cross-validation order in `executeShowPreviewToString`

1. Existing: `content_type` valid (one of the 5 supported values)
2. **NEW**: If `path` is set, `content_type` must be `"image"` — else error envelope with hint
3. **NEW**: If both `content` AND `path` are set — error envelope with hint
4. **NEW**: If `path` is set, call `resolveImageContentFromPath` — wrap any error in an envelope with a self-correcting hint (e.g. "convert the file to PNG or use `content` with a hand-written data URL")
5. **MODIFIED**: `validateContentSize` runs on the RESOLVED content (which may be a `data:` URL produced from the path) — not the raw `input.content`
6. Existing: code requires `language` for `content_type="code"`
7. Existing: UTF-8 sanitize (no-op for base64 payload but harmless)
8. Existing: emit `successEnvelope`

The `resolved_content` local variable is freed via a `defer` if `path` was used (the alternative branch reuses `input.content` directly without ownership transfer).

### Magic byte detection table

| Bytes (hex)                       | MIME       |
|-----------------------------------|------------|
| `89 50 4E 47 0D 0A 1A 0A`           | image/png  |
| `FF D8 FF`                          | image/jpeg |
| `47 49 46 38 37 61` / `47 49 46 38 39 61` | image/gif (87a/89a) |
| `52 49 46 46 ?? ?? ?? ?? 57 45 42 50` | image/webp |

These are the 4 browser-native formats. AVIF, HEIC, TIFF, BMP, etc. are deliberately NOT supported — the user can pre-convert them. A future "more formats" plan can extend `detectImageMime`.

## Tests (12 new tests)

### `resolveImageContentFromPath` (7 tests)

1. `returns data:image/png;base64,... for a valid PNG` — fixture: 67-byte minimal PNG
2. `detects JPEG via FF D8 FF magic bytes` — fixture: 254-byte minimal JPEG
3. `detects GIF via GIF87a/GIF89a magic bytes` — fixture: 42-byte minimal GIF87a
4. `detects WebP via RIFF....WEBP magic bytes` — fixture: 32-byte minimal WebP (VP8L)
5. `rejects file with unknown magic bytes` — fixture: plain text file
6. `rejects missing file with FileNotFound` — non-existent path
7. `rejects file exceeding MAX_CONTENT_BYTES` — large PNG-tagged file (>1 MiB)

### `executeShowPreviewToString` (4 tests)

8. `with path-only image returns success envelope` — happy path
9. `rejects when both content AND path are provided` — mutual exclusivity
10. `rejects path when content_type is not "image"` — cross-validation
11. `with content-only image still works (back-compat regression)` — existing 4-type behaviour preserved

### Schema check (1 test)

12. `ShowPreviewInput schema has the new path property` — source-grep test that the schema includes `.name = "path"`

## Out of scope (deferred)

- HTTP-served preview files (new endpoint + token issuance + cleanup) — out of scope per the plan
- More image formats (AVIF, HEIC, TIFF, BMP) — pre-conversion is fine for v1
- Image resize / format conversion — server returns file as-is; browser handles display sizing
- URL-based path (`http://`, `s3://`) — **stale as of 2026-10-02**: `web_search` is now a
  real web *search* tool (plan 2026-10-02-web-search-tool.md), not a URL fetcher. The
  old shim that shelled out to `agent-browser snapshot` is gone. For fetching a URL, use
  the `command` tool.
- Adding `path` to the system prompts (`src/modules/agent/prompts.zig`) — the tool's own description (updated here) is what the LLM sees; a follow-up plan can add a prompt-level mention
- Sandboxing (allow-list of dirs) — same threat model as `read_file`; defer until user asks
