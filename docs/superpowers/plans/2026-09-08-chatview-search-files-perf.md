# ChatView Search Files Perf Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make ChatView `@` file search instant on large repos by eliminating the N-sequential-HTTP full-tree walk and unbounded DOM render.

**Architecture:** Add a single backend recursive search endpoint (`GET /api/system/folder?action=search`) that walks once server-side with ignore-skips + limit, then thin the two frontend `@` pickers (FileInput + Kanban duplicate) to debounced server queries with cached tree fallback, capped render, and abortable requests.

**Tech Stack:** Zig backend (`src/modules/system_folder/system_folder.zig`, `src/ai_workflow/tui/http_handlers/system_folder.zig`), Vue 3 frontend (`FileInput.vue`, `KanbanDescriptionEditor.vue`, `src/apps/desktop/src/api/index.ts`), vitest + `tests/functional/harness.py` for verification.

## Global Constraints

- DONT KILL the port 8081 server; functional tests use harness-picked ports (8080..8199 excl. 8081).
- Never spin a live `nalar` binary + `curl` for verification; use `tests/functional/*.py` harness + `zig build test`.
- No new npm deps; no DB migration; no config schema change.
- Backend allocator in handlers is per-request arena — do NOT `defer free` arena memory (keep `rows.deinit()` / file-handle closes).
- `KanbanDescriptionEditor.vue` is an exact duplicate of the FileInput `@` picker — every frontend fix lands in BOTH files.
- Follow existing wire conventions: `GET /api/system/folder?action=list&path=...` shape; snake_case `is_directory` on wire.

## Background — What Is Slow Today (verified 2026-09-08)

- Trigger: `src/apps/desktop/src/components/file/FileInput.vue:404-426` — 150ms debounce only on `@`-regex detect, not on filter/network.
- Walk: `FileInput.vue:318-378` `loadAllFiles(root)` — on first `@`, sequential depth-first `await scanDir` with one raw `fetch(GET /system/folder?action=list)` per directory (line 329-331, bypasses `apiFetch`). No depth limit (`depth` unused), no skip for `node_modules/zig-out/zig-cache/target/dist` (only dotfiles skipped, line 340), no cache/abort across opens. Cost ≈ #dirs × RTT + backend `listDirectory` + per-entry `git check-ignore` subprocess (`src/modules/system_folder/system_folder.zig:187-214`).
- Backend: `src/ai_workflow/tui/http_handlers/system_folder.zig:31-76` + `src/modules/system_folder/system_folder.zig:159` — single-level only, no `q/recursive/limit` params. No `/api/files` or `search_files` endpoint exists (repo-wide grep negative).
- Filter: `FileInput.vue:380-402` — per-keystroke O(F×Q) subsequence match, `toLowerCase` per file per keystroke, empty query returns entire tree.
- Render: `FileInput.vue:539-570` — unbounded `v-for="(file, idx) in filteredFiles"` (line 554), all rows in DOM (`max-h-72 overflow-y-auto` scrolls but doesn't virtualize). Footer `{{ filteredFiles.length }} of {{ fileList.length }}` confirms all-match render. Arrow nav does global `querySelectorAll('.file-picker-list button')` + `scrollIntoView({smooth})` per key (504-512).
- Duplicate: `src/apps/desktop/src/components/kanban/KanbanDescriptionEditor.vue:138-197,542-583` — same walk + filter + unbounded render. Note latent mismatch: kanban copy reads `entry.isDirectory` (camel) at :158 vs backend `is_directory` (snake).
- Ruled out: `FilePickerDialog.vue` (single-dir only), `FolderExplorer.vue` (no search), paperclip native picker + paste handlers (image-only, unrelated).

## Files To Touch

1. `src/modules/system_folder/system_folder.zig` — new `searchFiles(allocator, io, root, query, limit, max_depth)` pure helper (recursive walk, skip-list, subsequence/substring match, dirs-first sort, hard cap).
2. `src/ai_workflow/tui/http_handlers/system_folder.zig` — new `action=search` branch (`q`, `limit`, `max_depth` params) + static-contract tests in same file or `system_folder_test.zig`.
3. `src/apps/desktop/src/api/index.ts` — new `searchFiles(cwd, q, limit?)` helper using `apiFetch` (not raw fetch).
4. `src/apps/desktop/src/components/file/FileInput.vue` — rewire `@` picker to server search + cap + cache + abort (see Task 2).
5. `src/apps/desktop/src/components/kanban/KanbanDescriptionEditor.vue` — mirror of (4) + fix `isDirectory` → `is_directory` read.
6. `tests/functional/system_folder_search_test.py` — NEW harness test (wire replay).
7. `docs/superpowers/plans/2026-09-08-chatview-search-files-perf.md` — THIS file.

## Task 1 — Backend: `searchFiles` helper + `action=search` endpoint (TDD)

- [ ] Read `src/modules/system_folder/system_folder.zig:159-236` (`listDirectory`) and `src/ai_workflow/tui/http_handlers/system_folder.zig:31-104` (route + serialization). Note per-entry `git check-ignore` cost and dirs-first sort.
- [ ] Write failing Zig test: `searchFiles` on a tmpdir fixture with `node_modules/`, `.zig-cache/`, `target/`, `dist/`, `zig-out/` dirs asserts they are skipped; asserts `limit` caps results; asserts empty query returns top-N (not whole tree); asserts subsequence `comp` matches `components/`.
- [ ] Run it, confirm it fails (no function yet).
- [ ] Implement `searchFiles(allocator, io, root_path, query, limit, max_depth)`:
  - Iterative stack (not recursion) with `max_depth` default 8, `limit` default 50 (hard cap 200).
  - Skip-list (exact name match, case-sensitive): `node_modules`, `zig-out`, `.zig-cache`, `zig-cache`, `target`, `dist`, plus existing dotfile skip. Single const array so both `listDirectory` and search share it later.
  - Match: case-insensitive substring first; fall back to existing subsequence (`matchesOutOfOrder` semantics ported from FileInput) so `tst`→`test` keeps working. Rank substring hits before subsequence hits, then dirs-first, then `localeCompare`-equivalent (`lessThanIgnoreCase`).
  - Reuse `entry.kind` (no extra stat); keep `git check-ignore` behavior identical to `listDirectory` (do NOT remove in this task — perf win comes from fewer dirs visited + limit).
- [ ] Run test, confirm pass. Run `zig build test --summary all`, confirm no regressions.
- [ ] Write failing static-contract test for HTTP layer: `GET /api/system/folder?action=search&path=<root>&q=comp&limit=50` returns `{ entries: [...] }` with `is_directory` snake_case, length ≤ limit; missing `q` returns top-N (not error); `limit>200` clamps to 200; unknown action unchanged.
- [ ] Implement `action=search` branch in `systemFolderHandler` (parse `q` default `""`, `limit` default 50 clamp 1..200, `max_depth` default 8 clamp 1..16). Serialize same `{name, path, is_directory, is_symlink}` shape as list. Empty `path` → 400 (empty-slice-as-NULL rule).
- [ ] Register nothing new in `src/main.zig` (same `/api/system/folder` route) — verify route order untouched.
- [ ] Run Zig tests + `zig build test --summary all`.
- [ ] Commit backend only.

## Task 2 — Frontend: FileInput `@` picker → server search + caps + abort (TDD)

- [ ] Read `FileInput.vue:46-50` (FileEntry), `:318-426` (walk+filter+trigger), `:449-512` (keyboard nav), `:539-570` (render).
- [ ] Write failing vitest (`FileInput.search.spec.ts`): mock `api.searchFiles` — asserts typing `@comp` calls server (not N `fetch` walks); asserts render caps at 50 rows (`wrapper.findAll('button')` ≤ 50 even when server returns 200); asserts second `@` open with same `cwd` reuses cache (no second network call); asserts stale response discarded via generation counter/abort.
- [ ] Run it, confirm fail.
- [ ] Implement in `FileInput.vue` (minimal, no virtual list in v1):
  - Add `api.searchFiles(cwd, q, limit=50)` in `src/apps/desktop/src/api/index.ts` via `apiFetch` (fixes raw-fetch bypass, gets timeout/auth handling).
  - Replace `loadAllFiles` full-walk-on-open with: open → `searchFiles(cwd, fileQuery, 50)`; debounce server calls 150ms on `fileQuery` change (reuse existing `fileDebounceTimer` pattern, second timer `fileSearchTimer`).
  - Generation counter (`searchGen++` per request; ignore responses with stale gen) + `AbortController` cancel on close/retype.
  - Per-`cwd` cache `Map<string, FileEntry[]>` for empty-query top-N only (bounded: max 3 cwds, else evict oldest) — non-empty queries always hit server (fresh ranking).
  - `filteredFiles`: if server results present use them directly (no client re-filter); keep client subsequence filter ONLY as fallback when server errors (operates on cached top-N).
  - Render cap: `v-for="(file, idx) in filteredFiles.slice(0, 50)"` + footer text `showing X of Y` (Y = server total or `filteredFiles.length`). Reset `selectedFileIndex=0` whenever `fileQuery` changes (fixes stale-index Enter-no-op).
  - Keyboard nav: scope selector to `filePickerRef.querySelectorAll('button')` (not `document`), drop `behavior:'smooth'` → `'auto'`, keep 50ms timer.
  - Loading counter: show `Searching…` spinner state from request lifecycle (fixes stuck-at-0 `fileList.length` counter — remove bulk-assign dependency).
- [ ] Run vitest, confirm pass. Run `pnpm test:unit` for the file + `vue-tsc --noEmit`.
- [ ] Commit frontend FileInput only.

## Task 3 — Mirror fix into KanbanDescriptionEditor + field bug (TDD)

- [ ] Read `KanbanDescriptionEditor.vue:138-228,542-583`. Confirm duplicate walk + `entry.isDirectory` camel read at ~:158.
- [ ] Write failing vitest asserting `is_directory` snake rows are detected as dirs (currently `undefined` → all treated as files).
- [ ] Port Task 2 implementation 1:1 (server search, debounce, cap 50, abort, cache, index reset, scoped nav). Fix `entry.isDirectory` → `entry.is_directory` (or accept both with `??` for safety: `entry.is_directory ?? entry.isDirectory`).
- [ ] Run vitest + `vue-tsc --noEmit`.
- [ ] Commit.

## Task 4 — Functional wire test + perf assertion (verification)

- [ ] Create `tests/functional/system_folder_search_test.py` using `harness.py` (fresh tmpdir HOME, free port, `$NALAR_BIN`):
  - Fixture cwd with `node_modules/big/`, `zig-out/`, `src/components/` + 300 generated files.
  - Test 1: `GET /api/system/folder?action=search&path=<cwd>&q=comp&limit=50` returns ≤50, contains `components`, excludes `node_modules` paths.
  - Test 2: empty `q` returns ≤50 (not whole tree).
  - Test 3: `limit=5000` clamps (response ≤200).
  - Test 4: old `action=list` single-level contract unchanged (regression guard).
  - Test 5 (perf): time-to-first-byte for search < 1s on the 300-file fixture; old behavior reference (N list calls) would be >> 1s — assert search completes and document timing in test output (not a flaky hard bound: assert <5s, log actual).
- [ ] Run `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/system_folder_search_test.py -v`. Must be green.
- [ ] Run `zig build test --summary all` + relevant `pnpm test:unit`. Record counts in plan PR description.
- [ ] Commit test.

## Task 5 — Docs + manual QA checklist

- [ ] Manual QA (dev binary, real repo as cwd): type `@` → results appear <300ms; type `@comp` → narrows; Esc closes; reopen `@` → instant (cache); `node_modules` file never appears; arrow+Enter inserts; kanban description `@` behaves identically.
- [ ] Update `docs/SPEC.md` § file-search if such section exists (else skip — do NOT create new spec file).
- [ ] Final `zig build test --summary all` + `pnpm test:unit` green. Open PR from worktree for `in_review_task` column.

## Out Of Scope (explicitly NOT in this plan)

- Virtualized list (vue-virtual-scroller) — cap-at-50 solves the DOM blowup for v1; virtualize only if 50-row render still janks.
- Removing per-entry `git check-ignore` subprocess — keep semantics identical; optimize only if profiling after this plan still shows it hot.
- FTS5/SQLite filename index — filesystem walk with skip-list + limit is sufficient; index is a bigger migration.
- `FolderExplorer.vue` lazy tree + `FilePickerDialog.vue` single-dir search — untouched (not on slow path).
- Backend `listFiles` O(n² log n) comparator in `api/index.ts:2960-2981` — dead wrt `@` path; fix separately if adopted.

## Verification (before claiming done)

- [ ] Plan saved here (this file) and reviewed before execution.
- [ ] `zig build test --summary all` green, `pnpm test:unit` green, `tests/functional/system_folder_search_test.py` 5/5 green.
- [ ] Manual QA checklist in Task 5 passes on a large cwd.
- [ ] PR open from worktree; kanban card in `in_review_task`.
