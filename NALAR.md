Nalar AI agent backend (Zig 0.16) with Vue 3 desktop app. See `.nalar/memories/` for detailed patterns and `~/.config/nalar/memories/` for cross-project lessons.

## Memories

Detailed patterns live in:
- Local: `.nalar/memories/` (project-specific: backend, frontend, data, infra)
- Global: `~/.config/nalar/memories/` (cross-project: Zig stdlib, Vue 3 patterns, SQLite gotchas)

## Language & Environment Facts

<!-- Known API changes, syntax rules, and environment behaviors for this codebase. -->
<!-- Format: - [lang@version] <fact in one sentence> -->

- [zig@0.16] **CRITICAL: `std.Io.Threaded` does NOT honor user-space deadlines on blocking socket reads** — when a worker thread is parked in `recv()` waiting for data, the main thread's deadline check is dead code. The worker only unblocks when the kernel returns (RST/FIN/error/timeout). To enforce a read deadline on a TCP stream, you MUST set `SO_RCVTIMEO` on the underlying socket fd, OR drive the Io's `select`/`async` with a timeout. Symptom: an "idle timeout" loop never fires when the server stalls without sending RST/FIN. See `src/modules/agent/Agent.zig` callStreaming read loop and the SKIP comment in `call_streaming_test.zig` for the live example.
- [zig@0.16] `std.Thread.Mutex` does NOT exist — `std.Thread` only exposes spawn/join/detach APIs. For a mutex in a `std.Thread.spawn`'d worker, use `std.atomic.Mutex` (a lock-free `enum(u8) { unlocked, locked }` with `tryLock() bool` and `unlock() void`) as a spinlock with `while (!m.tryLock()) std.atomic.spinLoopHint()`. For mutexes held by Io-runtime code, use `std.Io.Mutex` (lock takes `io: Io`). The critical section must be small (a few hundred ns) for the spinlock to be acceptable.
- [zig@0.16] **`std.process.spawn` takes `io: Io` as first arg** (not allocator). Signature: `spawn(io: Io, options: SpawnOptions) SpawnError!Child`. The `Child` struct has no `.allocator` field — its handle is owned by the Io runtime. Forgetting `io` and passing an allocator is a common mistake (the allocator will be treated as an Io and the type check fails).
- [zig@0.16] **`std.process.Child.kill(child, io)` is the all-in-one "terminate + wait + cleanup"** — it sends SIGTERM (or Windows equivalent), blocks until the child exits, sets `child.id = null`, and reaps. You MUST NOT call `child.wait(io)` after `kill(io)` because `wait` asserts `child.id != null` and will panic. There is no "kill but don't wait" API in 0.16.
- [zig@0.16] **Zig 0.16 has no public `std.posix.socket/bind/listen/accept/connect/recv/send/close`** — they live in `std.os.linux.*` (or `.windows.*`, `.darwin.*`) and return a raw `usize` (success value on success, `-errno` cast to `usize` on failure). Check return against `std.math.maxInt(i32)` to detect errors, then `@intCast` to `i32` for the fd. The `errno()` helper inside `posix.zig` is private.
- [desktop-app] `nalar-desktop` is the new native webview wrapper at `src/apps/desktop_app/`. It spawns `nalar` as a child process and opens a native webview window (WebKitGTK 4.1 on Linux via manual `extern "c"` + C shim at `platform/webview_linux.c`, WKWebView on macOS via Objective-C++ shim at `platform/macos/nalar_webview.mm`, WebView2 on Windows via C++ shim at `platform/windows/nalar_webview.cpp`). Build: `zig build nalar-desktop`. The Vue webapp is embedded as comptime bytes via the codegen step `zig build codegen:webapp-assets` (which depends on `zig build build:webapp` to run `bun run build` first). Runtime startup: extract assets to `$XDG_RUNTIME_DIR/nalar-desktop-webapp-<pid>/`, spawn `nalar --port <port> --static-dir <webapp-dir>`, wait for `/api/health`, open the webview at `http://127.0.0.1:<port>/`. 21/21 unit tests pass via `zig build test:desktop-app`. The output binary is ~29 MB (includes 4.7 MB of embedded webapp assets + the 17 MB nalarcore link).

# Mandatory
- Dont ever kill the process port 8081 or process nalar !!!
- If you want to test use process port 8080 and process nalar !!!
- When create a test make sure its work on platform linux, mac and windows

## 2026-07-27: Reorganize `src/` — 11 service files moved into `src/service/`

The 11 top-level files in `src/` that all serve the `nalar service
{start,stop,status,restart}` lifecycle + crash reporting are now grouped
under a new `src/service/` subdirectory. Follows the same pattern as the
existing `helpers/`, `modules/`, `migrations/`, `apps/`, `ai_workflow/`
subdirectories.

**What landed.**
- 11 files moved via `git mv` (history preserved):
  - `src/service/crash_handler.zig` + `_test.zig` + `_smoke.zig`
  - `src/service/daemon.zig` + `_test.zig`
  - `src/service/signal_handlers.zig` + `_test.zig`
  - `src/service/state_file.zig` + `_test.zig`
  - `src/service/main_service.zig` + `_test.zig`
- New `src/service/mod.zig` re-exports all 5 modules
- `src/root.zig` re-exports via `nalarcore.service.*` AND keeps the
  backward-compat top-level aliases (`nalarcore.state_file`,
  `nalarcore.daemon`, etc.) — existing call sites untouched.
- `src/service/main_service.zig` updated `helpers/mod.zig` →
  `../helpers/mod.zig` (going up one dir).
- `scripts/crash_handler_smoke.sh` updated `SMOKE_SRC` path.
- Doc-comment paths updated across moved files + `src/main.zig` +
  `src/service/daemon.zig` call-site list.

**What was NOT done (out of scope).**
- `startup.zig` is still dead code (its `pub fn startup()` is never
  called; the actual startup is `ai_mod.startup.start()`). Left for a
  follow-up.
- `main.zig` is still 763 lines. The `dispatchServiceSubcommand` (~115
  lines) and the static-file handler duplication (~140 lines) are still
  inline. Left for a follow-up.

## 2026-07-25: Design element drag-and-drop wire repaired

### Symptom (pre-fix)
Click on a design element → violet outline + 8 resize handles appear (selection works).
Click-and-drag → element does NOT move.

### Root cause
`AppLayout.handleDesignUpdateElement` (src/apps/desktop/src/components/AppLayout.vue:1129)
was a TODO no-op (`void elementId; void patch`). DesignElement's pointermove emitted
`update` patches, DesignView re-emitted them upward as `updateElement`, but the parent
silently discarded them.

### Fix
- Added `activeDesignPageId` + `setActiveDesignPage` to workspaces store (Task 1.1).
- DesignView mirrors its local `activePageId` to the store on mount + tab switch (Task 1.2).
- Extracted design handlers into `useDesignHandlers` composable for testability (Task 1.3).
- Replaced the no-op with a real handler that routes geometry-only patches to
  `PATCH /geometry` and full patches to `PUT /elements/:id` (Task 1.3).
- Throttled the drag stream to 50ms with a trailing emit on pointerup (Task 1.4).

## 2026-07-25: Design mode multi-select + group drag

Plan: docs/SPEC.md §3.8 (Chunk 2)

### What landed
- Selection is now `Set<string>` instead of `string | null`. Shift+click toggles membership; plain click is exclusive.
- Dragging one element in a multi-selection moves the entire selection (same dx/dy applied to all).
- Delete/Backspace removes every selected element (one keystroke).
- Escape clears the entire selection.
- PropertiesPanel renders a "N elements selected" banner when multiple are selected; the single-element form only shows for exactly one.

## 2026-07-25: Design mode snap-to-edges + alignment guides

Plan: docs/SPEC.md §3.8 (Chunk 3)

### What landed
- Pure-function `computeSnapDelta` snaps within 6 design-px of any other element's edge/center.
- Canvas-center + canvas-edge fallback targets (snaps to page center when no other element is nearby).
- 1px violet SVG alignment guides render during drag and clear on pointerup.
- Group drag applies snap to the selection's union bbox (the whole group snaps together).

## 2026-07-25: Design mode keyboard nudge

Plan: docs/SPEC.md §3.8 (Chunk 4)

### What landed
- Arrow keys move the selection by 1 design-px: ←/→ for x, ↑/↓ for y.
- Shift+arrow moves by 10 design-px (Figma's "big step").
- Input-focus guard preserved (PropertiesPanel X/Y inputs still get their arrow keys for cursor navigation).
- No-op when nothing is selected (no escape route from the canvas for stray arrows).

## 2026-07-25: Design mode element drag-and-drop (Figma-style) — COMPLETE

Plan: docs/SPEC.md §3.8

### What landed (all 5 chunks)
- **Drag-to-move works** (was a TODO no-op in AppLayout.handleDesignUpdateElement).
- **Multi-select** via Shift+click; group drag; multi-delete with one Delete key.
- **Snap-to-edges** with 1px violet alignment guides (6px threshold; canvas-center fallback).
- **Keyboard nudge** — arrow keys = 1px, Shift+arrow = 10px.
- **Constrain-to-canvas** — drag and nudge that would push an element entirely off-canvas clamp at 10px sliver.

### Bug fix at the heart
`AppLayout.handleDesignUpdateElement` was a TODO no-op (`void elementId; void patch`). The drag handler in DesignElement emitted `update` patches on every pointermove, but the parent silently discarded them. Now the wire is alive: the composable `useDesignHandlers` routes geometry-only patches to `PATCH /geometry` (60+/sec safe) and full patches to `PUT /elements/:id`.

### What was deferred (out of scope for this plan)
- Marquee drag-select (draw a rectangle to select everything inside). Lower priority — Shift+click is enough for the common 1-5-element case.
- Smart-spacing/distribute-horizontal/vertical (would need a server endpoint for batch geometry updates).
- Snap-to-grid (Figma toggle; can be added once snap-to-edges is comfortable).
- Drag-from-layers-panel to canvas (next plan if requested).
- Lock/hide (needs schema migration).
- Group containers — dragging elements INTO a frame (out of scope; `frame`/`group` element types exist but UI doesn't support drag-into yet).

## 2026-07-26: OS-level crash signal/exception handler

**Symptom (pre-fix).** `panicHandler` in `root.zig` catches Zig-level panics
(`@panic`, `unreachable`, index OOB) and writes a backtrace to
`/tmp/agentic_coding.log`. **But it does NOT catch OS-level crash signals**
that the kernel delivers to the process directly:

| Crash source | Caught by `panicHandler`? |
|---|---|
| `@panic("...")`, `unreachable`, slice OOB | ✅ |
| `try` error returned from `main` | ✅ (normal exit) |
| SIGSEGV / SIGBUS / SIGABRT / SIGILL / SIGFPE | ❌ — kernel terminates silently |
| Windows ACCESS_VIOLATION, STACK_OVERFLOW, etc. | ❌ |

The historical FD-leak and use-after-free bugs in this codebase (`bash.zig`
pipe leak, `Agent.httpClient` pool leak, `session_to_client_ids` race) all
manifested as SIGSEGV — and left no entry in `/tmp/agentic_coding.log`.

**What landed.**
- `src/service/crash_handler.zig` (312 lines): POSIX `sigaction` for SEGV/BUS/ABRT/ILL/FPE; Windows `SetUnhandledExceptionFilter` via Win32 extern.
- `src/service/crash_handler_test.zig`: 10 static-contract tests (TDD red→green).
- `src/service/crash_handler_smoke.zig` + `scripts/crash_handler_smoke.sh`: end-to-end smoke (5/5 PASS on Linux).
- `src/main.zig`: `installCrashHandlers()` called after `setPanicLogPath()`.
- `src/root.zig`: re-export `crash_handler` as `nalarcore.crash_handler`.

**Key design choices.**
- Restore `SIG_DFL` BEFORE logging (defends against crash-in-handler infinite loops).
- Capture the stack via `std.debug.captureCurrentStackTrace` (Zig 0.16 API; `getStackTrace` was removed) and format raw hex addresses — no per-frame heap allocation in signal context.
- Append to the same `panic_log_path` that `panicHandler` uses; mirror to stderr; re-raise (POSIX) or return `EXCEPTION_EXECUTE_HANDLER` (Windows).

**Verification.**
```
$ ./scripts/crash_handler_smoke.sh
==> Summary: 5 passed, 0 failed   (SEGV, ABRT, ILL, FPE, BUS)

$ zig build-obj -fno-emit-bin -target x86_64-windows-gnu: PASS
$ zig build-obj -fno-emit-bin -target aarch64-macos:     PASS
$ zig build test: 1850/1859 pass (3 pre-existing workflow_retry_delay_test failures unrelated)
```

**Pre-existing bug surfaced but NOT fixed here.** `root.zig::panicHandler` calls `std.c.fopen(path, "a")` with `path` being `[]const u8` (NOT null-terminated). On Linux+glibc this accidentally works, but Zig 0.16 should reject it at compile time. It escapes type-checking only because lazy analysis never instantiates `panicHandler`'s body for the test target's module graph. The new `crash_handler.zig` works around it by writing the NUL sentinel explicitly into a stack buffer.

Plan: docs/SPEC.md §3.1 (Backend — Core HTTP / Crash Handler)
Branch: worktree/crash-handler
Commit: 0418bc07
PR: (see SPEC.md §10.1)

## 2026-07-27: `workflow_retry_delay_test.zig` — 3 failures fixed

### Symptom (pre-fix)
`zig build test --summary all` reported 3 failures under `ai_workflow.tui.agentic_loop.workflow_retry_delay_test`:

1. `workflow.zig declares retryDelayMs helper` — `fn retryDelayMs(` not found in `workflow.zig`.
2. `workflow.zig retryDelayMs uses raw libc nanosleep, not std.Io.sleep` — same root cause.
3. `workflow.zig per-retry message is feed_to_llm (so AI sees full retry history)` — `saveRetryAttemptMessage` had `is_feed_to_llm = false`.

### Root cause (two distinct bugs)

**Bug A — `is_feed_to_llm = false` in `saveRetryAttemptMessage`:**
The per-retry diagnostic was written as a user-side chat entry
(`is_input = true` for rendering) but did NOT propagate to the LLM
context. The agent only ever learned about retries via the final
`TooManyRetries` summary. The docstring above the helper already
documented `is_feed_to_llm = true` as the intended behavior — the
implementation was the bug.

**Bug B — `retryDelayMs` extracted from `workflow.zig` to `retry_delay_ms.zig` without updating the test:**
`workflow_retry_delay_test.zig` was written when `retryDelayMs` was
inline in `workflow.zig` (commit `79de0068`). Commit `3f0d9e53` later
extracted it into `retry_delay_ms.zig` (a sub-module under
`agentic_loop/`) and re-exported via `mod.zig`. The two **definition
tests** (`fn retryDelayMs` exists, uses raw libc `nanosleep`) still
read `workflow.zig` — the wrong file. The four **usage tests**
(`retryDelayMs` is called from the right places in workflow.zig)
correctly still point at `workflow.zig`.

### Fix (2 files)

- `src/ai_workflow/tui/agentic_loop/workflow.zig:905` — `is_feed_to_llm = false` → `is_feed_to_llm = true`.
- `src/ai_workflow/tui/agentic_loop/workflow_retry_delay_test.zig` — added `RETRY_DELAY_SOURCE_PATH` constant for `retry_delay_ms.zig`; routed the two definition tests through it; renamed the two test names to use the new file name; updated the docstring to record the architecture refactor.

### Verification
- `zig build test --summary all`: **1853/1859 pass** (was 1850/1859, 3 failed). Consistent across 3 random seeds.
- `zig build install:linux:system`: binary builds (cp to `/usr/local/bin/nalar` fails harmlessly on permission).
- `rm -rf zig-out/bin && zig build`: fresh full rebuild succeeds.
- `zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc` + `aarch64-macos -lc`: both cross-compile clean.

Branch: `worktree/fix-retry-delay-test`
Commit: `7e4b8b45` (merged to main as `e88b8264`)

## 2026-07-28: AppLayout close handlers strip pageId from URL on design items

### Symptom (pre-fix)
Closing the chatview (✕ button) while on a design item with multiple
pages silently stripped `pageId` from the URL. A page reload then
restored the design item but landed on the FIRST design page instead
of the page the user had been editing.

### Root cause
Four close handlers in `AppLayout.vue` navigated back to
`view=workspace` with `workspaceId + itemId` but never included
`pageId`:

| Handler | Trigger |
|---|---|
| `handleCloseTaskView` | ChatView ✕ button |
| `closeGitViewer` | GitFileViewer ✕ button |
| `closeSkillViewer` | SkillDetail ✕ button |
| `closeCodeEditor` | CodeEditor ✕ button |

The reverse-sync watcher at lines 236-263 watches
`[activeWorkspaceItemId, activeDesignPageId]` and mirrors them back to
the URL — but it ONLY fires when EITHER value changes. Closing
chat/git/skill/code doesn't change either value, so the watcher doesn't
run to restore pageId either.

### Fix
In all 4 close handlers, read `activeDesignPageId` from the store and
include `pageId` in the `router.replace` query when set:

```js
const pageId = workspacesStore.activeDesignPageId
const query: Record<string, string> = { view: 'workspace', workspaceId: wsId, itemId }
if (pageId) query.pageId = pageId
router.replace({ path: '/app', query })
```

`pageId` is design-item-scoped and empty for kanban/folder items, so
the URL stays clean for non-design items.

### Verification
- 19/19 AppLayout.urlPersist.spec.ts pass (was 16)
- 41/41 AppLayout test files pass
- 1522/1522 full vitest suite passes
- `vue-tsc --build` clean
- `bun run build` clean

### Related
- Memory: `.nalar/memories/applayout-close-handlers-strip-url-params.md`
- Branch: `worktree/close-chatview-keep-pageid`
- Commit: `e5897530`


### 2026-07-29: Kanban task tags (free-form string list)

**What landed:**
- New column on `workspace_item_tasks`: `tags TEXT NOT NULL DEFAULT ''` (Migration 067). JSON-encoded array of strings (e.g. `'["bug","urgent","frontend"]'`); empty string = "no tags".
- Wire shape: `WorkspaceItemTaskResponse.tags` (string, JSON-encoded), `TaskCreateRequest.tags`, `TaskUpdateRequest.tags` (both `?[]const u8`).
- Frontend: `KanbanTagsInput` chip input component. `<KanbanTagsInput>` rendered between description and unattended-mode toggle in `KanbanTaskDetailDialog` (both create + edit modes).
- `WorkspaceItemTaskCard` renders up to 3 colored tag chips below the title (with `+N more` link if more than 3).
- Validation via `tags_validation.zig::validateAndNormalizeTags` — char whitelist `[a-zA-Z0-9_-]`, length cap 50 chars per tag, case-insensitive dedupe (first-occurrence wins), JSON shape validation.
- Deterministic 6-color palette via djb2 hash of lowercase tag (same algorithm in card + dialog for visual consistency).

**Decisions taken:**
- Free-form string list (Option A from the brainstorm) — chose simplicity over managed vocabulary. Forward-compatible with a future managed-tag migration (read the JSON array, create proper tag rows + join table).
- JSON string column, not a separate table — no SQL-level filtering needed in v1.
- Per-tag char whitelist `[a-zA-Z0-9_-]` (GitHub-style). Per-tag length cap 50 chars.
- Case-insensitive dedupe preserves first-occurrence casing.
- 6-color palette deterministically chosen via djb2 hash of lowercase tag name.

**Out of scope (v1):**
- Tag filtering on the kanban board (substring search later if needed).
- Tag management page (no rename, no merge).
- Tag autocomplete.
- Tag rename propagation across tasks.
- Per-tag colors user-chosen.

**Plan:** docs/superpowers/plans/2026-07-28-kanban-task-tags.md
**Spec:** docs/superpowers/specs/2026-07-28-kanban-task-tags-design.md
**Branch:** `worktree/kanban-task-tags`


### 2026-07-29: design Cmd+Shift+G Ungroup + rebased onto group-drag-fix

**What landed:**

Backend (commit `59061c7f` after rebase, originally `ee903dc9`):
- `design_model.ungroupElements(alloc, db, input) UngroupError![]DesignElement`
  - Reparents group children to the group's parent (or NULL); deletes the group row.
  - Errors: `BadGroupId`, `NotAGroup`, `EmptyGroup`, `DbError`, `OutOfMemory`.
- HTTP handler `design_elements_ungroup.zig`:
  - `POST /api/workspaces/:ws/items/:item/design/pages/:page/elements/ungroup`
  - Body `{ element_id }`, 200 `{ orphaned: DesignElement[] }`.
  - Errors: 400 (`BadGroupId` / `NotAGroup` / `EmptyGroup`), 500.

Frontend (commit `daf21418` after rebase, originally `d7a05497`):
- `api.ungroupDesignElements(ws, item, page, elementId)` — POST wrapper.
- `workspacesStore.ungroupDesignElements(...)` — replaces orphaned children in place + splices the group row.
- `useDesignHandlers.ungroupSelection(elementId)` — composable; clears selection on success; toasts.
- `DesignContextMenu` — new "Ungroup" item, disabled unless exactly 1 group/frame is selected.
- `DesignView.vue` — Cmd+Shift+G keyboard handler + `handleDesignUngroupFromContextMenu` wired to the LayersPanel + canvas menus.

**Rebase sequence (merging worktrees in the right order):**

1. The `worktree/group-drag-fix` branch (commit `461fa3a9`) was a separate, parallel worktree that landed AFTER `worktree/group-ungroup` branched off `main`. The two branches touched different functions in `DesignView.vue` (group-drag added `expandSelectionWithDescendants`; ungroup added `handleDesignUngroupFromContextMenu`).
2. Merged `worktree/group-drag-fix` → `main` with `--no-ff` (commit `ac66d088`).
3. Rebased `worktree/group-ungroup` onto the updated `main`:
   - Backend commit `ee903dc9` applied cleanly.
   - Frontend commit `d7a05497` had 1 conflict in `DesignView.vue` (lines 1150–1190) — resolved by keeping both new functions (the conflict was at the same insertion point but for different functions; manual merge preserved both).
   - Rebase produced new commit hashes `59061c7f` and `daf21418`.
4. Verified: vue-tsc clean; vitest 1600/1601 (1 pre-existing NalarBrowserInlinePreview flake, passes standalone); zig 2013/2019; both binaries build clean.

**Plan:** docs/superpowers/specs/2026-07-29-design-right-click-group-menu.md (Chunk 9, originally deferred from grouped-layers plan)
**Branches:**
- main: now contains group-drag-fix (merge `ac66d088`)
- worktree/group-ungroup: now contains both group-drag-fix AND ungroup feature

### 2026-07-30: better-compaction-context — enriched XML + use-after-free mock bug

### 2026-08-06: Kanban "Create task & run agent" — single-click task + agent start

**What landed.** Secondary `▶ Create task & run agent` button in the New Task dialog (`KanbanTaskDetailDialog`, `mode: 'create'`). The button creates the task, queues `title + '\n\n' + description` as the first user message via `POST /api/llm/session`, and routes the user to the new task's chat view via the existing `selectTask` emit.

**Files.** 5 (3 NEW tests, 2 EDIT impl). Frontend-only — no backend changes, no migration, no Zig changes. The two endpoints (`POST /api/workspaces/.../tasks` and `POST /api/llm/session`) already exist and compose cleanly.

**Wire.** The dialog adds a sibling `create-and-run` emit with the same payload as `create` but a `mode: 'create_and_run'` discriminator. `KanbanView.handleCreateTaskSave` branches on `mode`:
- `create` — today's flow (create + move + close dialog).
- `create_and_run` — also queues the title + description via `api.sendChatMessage`, then reuses the existing `selectTask` emit so the `AppLayout → Sidebar` chain navigates to the new chat view.

**Message composition.** `title + '\n\n' + description` when description is non-empty, else just `title`. Empty description is allowed (the message is just the title). The unattended toggle flows through as `is_auto_retry_until_stop`.

**Partial success.** When `sendChatMessage` fails after the task is created, surface a `notifyError` toast and skip navigation. The user can click the card to retry manually. Never strand the user.

**Tests.** 16 new behavioural tests across 3 new files (3 in `workspacesStoreRunAgent.spec.ts`, 7 in `KanbanTaskDetailDialog.runAgent.spec.ts`, 6 in `KanbanView.createAndRun.spec.ts`). All pass; no regressions in the 271-test Kanban suite. Pre-commit verification: `bun run build` clean, `zig build test` 2145 pass + 6 skip (same as baseline), `zig build install:linux:system` builds 77 MB nalar binary.

**Bug found during live smoke.** The plan/spec said to check `result?.status === 'queued'` but the backend actually returns `status: 'send'` (see `session_create.zig:115`). The host was checking `'queued'` which never matched — the navigation path was dead code. Fix: check `'send'` instead. Verified via live smoke flow on port 8080:
  1. `POST /api/workspaces` → workspace_id
  2. `POST /api/workspaces/:ws/items` (with `path: "/tmp"`) → item_id
  3. `POST /api/workspaces/:ws/items/:item/kanban/columns` → column_id
  4. `POST /api/workspaces/:ws/items/:item/tasks` → task_id
  5. `POST /api/llm/session` with `session_id=task_id`, `queue_message="Title\n\nDescription"` → `{"id":"task_id","name":"New Session","status":"send"}`

**Plan:** `docs/superpowers/plans/2026-08-06-kanban-create-task-run-agent.md`
**Spec:** `docs/superpowers/specs/2026-08-06-kanban-create-task-run-agent-design.md`
**Branch:** `worktree/kanban-create-task-run-agent`

### Symptom
The agent's compaction step (when session history grew past the model's
window) gave the next iteration of the agent ONLY the compactor's summary.
The next iteration had no access to (a) the full user chat history or
(b) every file the AI had previously read via `read_file`. So if the
agent's next iteration needed to know "what did the user actually ask"
or "what files did the AI previously scan", it had to re-fetch from
scratch — losing the compaction's value.

### Fix
Added `compaction_context.zig` helper module that wraps the compactor's
XML in a `<compaction_context>` envelope with two new sections:
- `<user_history>` — every user chat row for the session, capped at 100
  turns / 2000 chars each (truncated; oldest dropped).
- `<read_files>` — every `read_file` tool-result row, deduplicated
  (first occurrence wins), with absolute paths computed relative to `cwd`.

Wired into `maybeCompactMessagesNew` so every compaction now carries
this enriched context forward to the next iteration.

### Tests
12 new tests across 2 files (`compaction_context_test.zig` + `compaction_enrich_test.zig`):
- parseReadFilePath extracts the path from a valid envelope
- fetchUserChatHistory / fetchReadFilePaths query mock DBs and de-dup / sort
- enrichCompactionXml wraps the compactor's output and renders both sections
- Integration tests (3) verify the wire-up — the mock now sees the
  enriched XML, not the bare compactor output.

### Bug fix (commit d131eb1d) — module-global mock_state slices go stale
**Symptom (pre-fix).** 3 integration tests crashed with `signal ABRT`/
`Segmentation fault` — stack trace pointed at
`std.mem.indexOf(u8, mock_state.last_compacted_xml, ...)`.

**Root cause.** `mockCompactMessagesInMemory` stored a raw `[]const u8`
pointer to the `enriched_xml` that the caller (`maybeCompactMessagesNew`)
would `defer allocator.free` on its return path. By the time the test
read `mock_state.last_compacted_xml`, the buffer was already freed.
`mock_state` is a module-level GLOBAL, so test N+1 inherited the
dangling pointer and crashed reading it.

**Fix.**
- `MockState.last_compacted_xml_owned: []u8` — the mock now `dupe`s
  the input before storing.
- `releaseLastCompactedXml()` helper frees the owned buffer.
- Each test that reads `last_compacted_xml` defers `releaseLastCompactedXml()`
  so the buffer is freed BEFORE `testing.allocator_instance.detectLeaks()`
  fires (post-test-scope).

**Memory written.** `~/.config/nalar/memories/zig-mock-state-global-use-after-free-across-tests.md`
documents the pattern for future mock-state authors.

### Verification
- `zig build test --summary all`: 2021/2027 pass (was 2018/2027 — +3 new tests)
- `zig build install:linux:system`: 87 MB nalar binary at zig-out/bin/nalar
  (cp-to-/usr/local/bin/nalar fails harmlessly on permission).
- Cross-compile `zig build-obj -fno-emit-bin` for Windows + macOS: clean
  (only sibling files with `@import("../..")` fail — pre-existing limitation).

**Branch:** worktree/better-compaction-context
**Commits:** `d131eb1d fix(test): mock now dups compacted XML ...`,
             `a8e1da0c todo better compact` (scaffolding),
             plus prior test scaffolding (`use proper allocator`,
             `remove useless test`).
