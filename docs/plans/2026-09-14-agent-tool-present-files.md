# Plan: agent tool `present_files` (click-to-download)

## Goal
One-sentence: let the agent present one or more workspace files of ANY type (text, jpg/png, pdf, zip, code, etc.) as cards in chat; every file is downloadable on click, and images (jpg/png/gif/webp) show a visible preview/thumbnail before download.

Non-goals (v1): no inline edit, no multi-workspace paths, no resumable/chunked download, no permissions UI beyond existing session cwd. Text/other non-image files get a file row + download only (no full inline viewer in v1).

## Background (what exists today)
- No `present_files` tool exists. Closest is `show_preview` (`src/modules/agent/tools/show_preview.zig`) — ephemeral side-panel renderer, inline `content`/`data:` URL only, no file URL, no download.
- No download endpoint exists. `src/main.zig` serves SPA static files + JSON APIs only. No `/api/files/*`, no `Content-Disposition: attachment`, no `sendFile`. Only file-ish reads: `GET /api/git/file/read`, `GET /api/system/folder?action=read`, background-process log.
- Tool-output cards (`src/apps/desktop/src/components/tool_outputs/`, ~30 `.vue`) are purely presentational — zero `fetch`/`blob`/`download`. Only download-adjacent code is `PreviewContentRenderer.vue:openInNewTab()` (HTML blob → `window.open`, no filename) and `kanban/KanbanDescriptionEditor.vue` (`fetch(url).blob()` to rehydrate thumbnails).
- API client (`src/apps/desktop/src/api/index.ts:apiFetch`) is JSON-only (`response.json()`, 15s timeout, auto-toast). Binary download must bypass or extend it (precedent: `KanbanDescriptionEditor.serverUrlToFile()` uses raw `fetch` + `blob()`).
- Registration pattern (4 steps): (1) `src/modules/agent/tools/<name>.zig` defines `AgentTool` + `Input` + `execute<Name>ToString` returning `<name>…</name>` XML; (2) `src/agentic_loop/tools_exec_<name>.zig` wraps via `wrapToolOutput`; (3) register in BOTH `equips()` and `UNIFIED_TOOL_REGISTRY()` in `src/agentic_loop/tools_equipped.zig`; (4) re-export in `src/agentic_loop/tools.zig`, dispatched by `handle_tool.zig:402` (3-phase placeholder → INSERT → UPDATE, SSE via `onEventSendLLMHistory`).

## Proposal

### UX
- Agent calls `present_files{files:[{path, label?, caption?}]}` → chat shows a `PresentFiles.vue` card: one row per file (icon + label/filename + size + mime + ⬇ download button), click row/button downloads.
- Per-type rendering (v1):
  - `image/*` (jpg/png/gif/webp): thumbnail preview visible WITHOUT clicking download (e.g. 120–240px thumb in card, click thumb → fullscreen via existing `ImagePreview` modal), plus explicit ⬇ button / clickable filename for download.
  - everything else (text, code, pdf, zip, etc.): generic 📄 row (icon by extension) + filename + size + ⬇ download. No inline content viewer in v1 (keeps payload small; full text preview stays in `show_preview`/`read_file`).
- Click behavior: `GET /api/files/download?session_id=…&path=…&disposition=attachment` → browser download with original filename (`Content-Disposition: attachment; filename="…"`). Image `<img>` uses same endpoint with `disposition=inline` (`Content-Disposition: inline`, `Cache-Control: private, max-age=3600`) so the browser renders instead of downloading. Fallback on error: red inline error in card (same style as `ShowPreview` error block), broken-image icon for failed thumbs, no navigation away.
- Keep card collapsed-friendly: header `present_files → 3 files ✓`, expanded body = file rows. Reuse `ToolCardHeader` chrome (violet pill, ✓/✗, +/− expander, ⎘ copy-path).

### Backend (Zig)
1. **New tool** `src/modules/agent/tools/present_files.zig`:
   - `PresentFilesInput = struct { files: []FileRef }`, `FileRef = struct { path: []const u8, label: ?[]const u8, caption: ?[]const u8 }`.
   - Validation: require 1–10 files, each `path` absolute, exists, is file (not dir/symlink-escape), size ≤ 50 MiB (reject with clear error so LLM can split); accept ANY file type (text, jpg, pdf, zip, code — no extension allowlist); do NOT read bytes — only `stat` (name/size/mime via extension + magic-byte sniff reuse from `show_preview.detectImageMime`, extended to generic mime; unknown → `application/octet-stream`).
   - Returns `<present_files><status>presented</status><files><file path="…" bytes="…" mime="…" label="…"/>…</files></present_files>`. No base64, no content inline (keeps SSE payload small — unlike `show_preview` 1 MiB cap; images render via URL, not data URI).
   - Static-contract test in-file (`TOOL_PATH="src/modules/agent/tools/present_files.zig"`), mirror `show_preview.zig:660+`.
2. **Exec wrapper** `src/agentic_loop/tools_exec_present_files.zig`: parse args → `executePresentFilesToString` → `wrapToolOutput("present_files", …)`.
3. **Register**: `tools.zig` re-export + both `equips()` and `UNIFIED_TOOL_REGISTRY()` entries in `tools_equipped.zig` + `DEFAULT_AGENT_TOOLS` entry (decided 2026-09-14: default in all modes — agent + kanban items via the creation-time seed; plain chat sessions have an empty allowlist = unfiltered, so they get it automatically).
4. **Download + inline-preview endpoint** (new, the only binary route):
   - `GET /api/files/download?session_id=<id>&path=<abs>&disposition=<inline|attachment>` → handler `src/http_handlers/files_download.zig` (new) + route in `src/main.zig` next to `/api/system/folder` group.
   - AuthZ: resolve `session_id` → session cwd (same lookup as `readFileContent`/`/system/folder`); reject if `path` escapes cwd (`std.fs.path` resolve + prefix check, no symlink follow); 404 if missing, 403 if dir/traversal, 413 if > 50 MiB. Same checks for both dispositions.
   - Response: `200`, `Content-Type: <mime>`, `Content-Length`, `Cache-Control: no-store` (attachment) / `private, max-age=3600` (inline). `disposition=attachment` (default, for ⬇ clicks) → `Content-Disposition: attachment; filename="<basename>"`; `disposition=inline` (for `<img>` thumbs) → `Content-Disposition: inline; filename="<basename>"`. Stream file (don't buffer whole file in memory).
   - Query-string encoding: frontend `encodeURIComponent(path)`; backend percent-decodes (check existing router decoding behavior first).
5. **Prompt**: add 2-line usage note in `prompts_build_messages_for_agent_prompt.zig` (when to call `present_files` vs `show_preview` vs `generate_image`).

### Frontend (Vue)
6. **Parser**: extend `tool_outputs/_shared/toolOutputParser.ts` with `parsePresentFiles(content): {path,bytes,mime,label,caption}[]` + unit test.
7. **Card** `tool_outputs/PresentFiles.vue` (new) — DECIDED: cookie-based auth (confirmed 2026-09-14), so plain `<a href>` + `<img src>` carry auth automatically; no `fetch`+`blob`+`objectURL` needed:
   - Props `:content` (inner `<data>` XML), `:parameters`, `:cwd`, `:expanded`, `:sessionId` (thread through from `ChatView` — check how `sessionCwd` is passed today).
   - Image files (`mime` starts with `image/`): `<img :src="previewUrl(file)" loading="lazy">` where `previewUrl = /api/files/download?session_id=…&path=…&disposition=inline`, thumb styling (~160px, rounded, object-cover), click → existing `ImagePreview` fullscreen modal; filename + ⬇ button use `<a :href="downloadUrl(file)" :download="basename">`.
   - Non-image files: generic row (📄/extension icon + filename + size + mime + ⬇) as `<a :href="downloadUrl(file)" :download="basename">` — browser handles the save dialog; no JS blob dance, no `revokeObjectURL`.
   - `downloadUrl(file) = /api/files/download?session_id=${sessionId}&path=${encodeURIComponent(file.path)}&disposition=attachment`, `previewUrl(file)` same with `disposition=inline`.
8. **Dispatch**: `ChatView.vue` — import `PresentFiles`, add `v-else-if="msg.tool_name==='present_files'"` branch next to `show_preview` (`:~3458`), pass `sessionId`.
9. **api client**: add `downloadFile(sessionId, path): string` URL builder in `api/index.ts` (not `apiFetch` — binary). If `fetch+blob` path chosen, add `downloadFileBlob()` helper with `signal` + `silent:true` error mapping.

### Verification (no live-server curl — use harnesses)
- **Zig**: in-file static-contract test (tool def shape) + `present_files` validation tests (absolute-path reject, missing-file error, dir reject, >cap reject); handler unit test for traversal reject + `Content-Disposition` header.
- **Frontend**: `PresentFiles.spec.ts` (parse + rows + `downloadUrl`/`previewUrl` encoding + image-thumb renders `<img>` with `disposition=inline` while ⬇ uses `attachment`) + `toolOutputParser` test.
- **Functional (wire round-trip — MANDATORY per repo rules)**: `tests/functional/agent_present_files_test.py` via `harness.py` (fresh binary, tmpdir HOME, free port ≠ 8081): create workspace+session, run agent tool call with real wire body `{files:[{path:<abs>}]}` (absolute path, non-empty — avoids the `""`-as-NULL / `isAbsolute("")` traps from PR #291), assert card payload lists file, then `GET /api/files/download?...&disposition=attachment` asserts `200` + `attachment; filename=` + byte-identical body for BOTH a `.txt` and a `.jpg`; `disposition=inline` asserts `200` + `inline` + same bytes (img-renderable); plus traversal test (`path=/etc/passwd` → 403) and missing-file test (404). This catches route-order shadowing (`/files/download` vs `/files/:id`) and empty-slice binding — unit tests alone miss these.

## Risks / open questions
1. **Auth on download**: RESOLVED 2026-09-14 — cookie-based (user-confirmed). Plain `<a :href download>` + `<img :src>` send cookies automatically; no `fetch`+`blob`+`objectURL` path needed. (If a future header-token mode appears, revisit with `fetch→blob` fallback.)
2. **Path scope**: restrict to session cwd (recommended) or any absolute path the server can read (like `show_preview`/`read_file` threat model)? Cwd-scoped is safer for a download primitive (browser saves to disk).
3. **Size cap**: 50 MiB proposal — confirm SSE/HTTP server limits; streaming avoids memory blowup but timeout (`apiFetch` 15s) doesn't apply to raw fetch — set explicit `AbortSignal.timeout(120_000)` for large files.
4. **Route order**: register `/api/files/download` BEFORE any `/api/files/:param` literal to avoid `matchRoute` shadowing (see `kabelweb src/server/router.zig:182` precedent).
5. **MIME**: reuse `static_files.zig:103-118` map; fallback `application/octet-stream` (forces download).

## Steps (execution order)
- [ ] 1. Backend tool: `present_files.zig` + in-file tests
- [ ] 2. Exec wrapper + `tools.zig` re-export + `tools_equipped.zig` dual registration (+ prompt note)
- [ ] 3. Download handler + route in `main.zig` (traversal/size/mime/headers) + handler tests
- [ ] 4. Frontend parser + `PresentFiles.vue` + `ChatView` dispatch + `api/index.ts` URL builder
- [ ] 5. Zig tests + frontend spec tests green
- [ ] 6. Functional harness test (wire body + download bytes + 403/404 cases), port ≠ 8081
- [ ] 7. PR from this worktree (`worktree/agent-tool-present-files-1789413066346`) for human review

## Files to touch (expected)
- NEW: `src/modules/agent/tools/present_files.zig`, `src/agentic_loop/tools_exec_present_files.zig`, `src/http_handlers/files_download.zig`, `src/apps/desktop/src/components/tool_outputs/PresentFiles.vue`, `tests/functional/agent_present_files_test.py`
- EDIT: `src/agentic_loop/tools.zig`, `src/agentic_loop/tools_equipped.zig`, `src/agentic_loop/prompts_build_messages_for_agent_prompt.zig`, `src/main.zig`, `src/apps/desktop/src/components/tool_outputs/_shared/toolOutputParser.ts`, `src/apps/desktop/src/components/views/ChatView.vue`, `src/apps/desktop/src/api/index.ts`
