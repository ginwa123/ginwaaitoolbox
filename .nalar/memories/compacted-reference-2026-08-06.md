# nalar — Compacted Memory Reference

> Snapshot 2026-08-06. Compiled from ~30 local memory files (`.nalar/memories/`), ~15 global memory files (`~/.config/nalar/memories/`), AGENTS.md, and the 11-skill inventory. Preserve: names, dates, numbers, decisions, preferences, open work. Drop filler.

---

## 1. Project & Stack

- **Repo:** `/home/ginwa/ginwaaitoolbox` — Zig 0.16 backend + Vue 3 / TS desktop app, multi-platform (Linux ✅ macOS ✅ Windows ✅)
- **Webapp + desktop wrapper:** `src/apps/desktop/` + `nalar-desktop` (WebKitGTK / WKWebView / WebView2)
- **Binaries:** `zig-out/bin/nalar` (~87 MB), `zig-out/bin/nalar-desktop` (~29 MB)
- **Spec source-of-truth:** `docs/SPEC.md` (consolidates all 178 historical plan files)
- **Memory dirs:** local `.nalar/memories/`, global `~/.config/nalar/memories/`

## 2. Mandatory Rules (do not violate)

- **NEVER kill/use port 8081** — always-running dev `nalar` shared with user → use port **8080** for local smoke
- **Every test MUST work on Linux + mac + Windows** — verify via `zig build-obj -fno-emit-bin -target X`
- `cwd_override` on `ToolExecContext` is **UNUSED dead-letter field** — never depend on it being populated
- **NEVER touch** `.nalar/agents/<name>/NALAR.md` — only root `NALAR.md` is project conventions

## 3. Zig 0.16 — Critical API Removals

| ❌ Removed | ✅ Replace with |
|---|---|
| `std.posix.socket/bind/listen/accept/connect/recv/send/close` | `std.os.linux.*` / `.windows.*` / `.darwin.*` (raw `usize`; check `> std.math.maxInt(i32)`) |
| `std.posix.kill/getcwd/getenv` | `std.c.*` or helpers in `src/helpers/` |
| `std.posix.setsockopt` (Windows) | gate `if (builtin.os.tag != .windows)` |
| `std.fs.cwd() / accessAbsolute` | `std.Io.Dir.cwd()` / `std.c.faccessat` |
| `std.crypto.random.bytes` | `std.c.getrandom(buf.ptr, buf.len, 0)` |
| `std.time.timestamp()` | `std.Io.Clock.now(.real, io).toSeconds()` or libc `gettimeofday` |
| `std.Thread.Mutex` | `std.atomic.Mutex` (spinlock) for `std.Thread.spawn` workers; `std.Io.Mutex` for Io runtime |
| `std.process.spawn(allocator,...)` | `std.process.spawn(io, options)` — io FIRST |
| `child.wait(io)` after `kill(io)` | just `kill(io)` — kill already reaps + closes pipes |
| `parseFromSlice + deinit` | `parseFromSliceLeaky` (per-request arena reaps) |
| `std.json.fmt` w/ invalid-UTF-8 | sanitize via `helpers.sanitize.sanitizeUtf8` first |

**Special traps:**
- `std.Io.Threaded` blocks user-space deadlines on `recv()` — must set `SO_RCVTIMEO` or aggressive TCP keepalive for read deadlines
- `spawn .cwd` is `process.Child.Cwd` union (`.inherit` / `.{ .path = ... }` / `.{ .dir = ... }`) — never `null`
- `std.json.Stringify.valueAlloc` accepts anonymous structs, but `field: T = runtime_local` does NOT compile (comptime scope)
- `defer` inside `if/else` branch fires at branch end — hoist to function scope
- `_ = var` discarded if `var` used later → `pointless discard` error

## 4. Cross-Platform Helpers (reuse, don't reinvent)

| Need | Use |
|---|---|
| PID / kill / is-running | `helpers.process_status.{killProcess, isProcessRunning, getCurrentProcessIdInt}` (returns `i32`) |
| `getcwd / getenv` without Io | `nalarcore.helpers.{getcwd, getenv}` (libc) |
| TCP keepalive | `Agent.zig apply_tcp_keepalive` (POSIX), gate `!= .windows` |
| HTTP client (libcurl) | `src/modules/http/HttpClient.zig` |
| Daemonize (Win32) | `src/modules/daemon/` |
| SIGTERM handler | `src/modules/signal_handlers/` |
| Cross-platform shell smoke | `scripts/ci-smoke-test.sh`, `scripts/service-lifecycle-smoke.sh` |
| Clong alias pattern | `i64` for `long` on Linux/macOS 64-bit, `i32` on Windows |
| Decode Win32 FILETIME | `ticks/10000000 - 11644473600` |

## 5. Build & Verification (mandatory trio)

```bash
# Backend
timeout 180 zig build test --summary all
timeout 180 zig build install:linux:system
timeout 360 bash -c 'rm -rf zig-out/bin && zig build'  # catches lazy-analysis + stale cache

# Frontend (BOTH required — vitest does NOT type-check)
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
timeout 120 bunx vitest run 2>&1 | tail -n 20
```

| Check | Module graph | Catches addExecutable-only errors? |
|---|---|---|
| `zig build test` | rooted at test runner | No (lazy analysis) |
| `install:linux:system` | rooted at `main.zig` | Partial (cp-to-`/usr/local/bin/nalar` masks success) |
| `rm -rf zig-out/bin && zig build` | fresh rebuild | **Yes** |

`zig build` "failed command:" line is **misleading debug noise** (not failure); check summary `passed/failed` instead. Use `ZIG_BUILD_ERROR_STYLE=minimal` to suppress.

## 6. Backend Patterns

- **Per-request arena allocator** (`GinwaServer`) → don't add `defer free()` for `ctx.allocator` allocations
- **HTTP handler thin-wrapper pattern:** `parseFromSliceLeaky` + `std.json.Stringify.valueAlloc` + typed response struct (not hand-rolled `allocPrint`); status 200/201/400/404/409
- **`req.params.get("name")`** (not `req.path_params`)
- **Always alias tables in SELECTs:** `h llm_history`, `s sessions`, `t workspace_item_tasks`, `r routines`, `wi workspace_items`, `w workspaces`
- **Image fields have two shapes:** `image_urls` (plural array) for `SaveMessageInput`/`TUIHistory`, `image_url` (singular string) for SSE/REST
- **TUIHistory has BOTH `tools` + `tool_call_id`** — set both for tool-result messages
- **Fire-and-forget spawn needs per-child reaper thread** (NOT `signal(SIGCHLD, SIG_IGN)` which breaks other wait sites)
- **raw `waitpid` doesn't auto-close pipes** — `child.wait/io` is the only path that triggers `childCleanupPosix`
- **FD leak diagnostic:** `ls /proc/$PID/fd | wc -l`, then `awk '{print $NF}' | sort | uniq -c` to bucket
- **OS-level crash handlers** in `src/service/crash_handler.zig` (POSIX `sigaction` + Win32 `SetUnhandledExceptionFilter`)

## 7. SQLite Patterns

- **`exec`/`query` only bind TEXT** — format `i64` via `std.fmt.allocPrint("{d}")` before binding
- **Empty `[]const u8` → NULL** — split INSERT/UPDATE into "with-X" / "without-X" for `NOT NULL DEFAULT ''` columns
- **`step()` can return ROW after DONE** — track explicit `done` flag in `Rows`
- **Transactions:** commit/rollback returns `error.TransactionClosed`; `deinit()` MUST null `self.db`
- **Dynamic SQL for `sqlite3_exec`:** need NUL sentinel (`bufPrint` + manual `buf[slice.len] = 0`)
- **`std.Io.Mutex` is NOT reentrant** — inner tx methods can't call db-level locking
- **GENERATED ALWAYS AS STORED** silently drops non-deterministic columns (use triggers + `CAST(... AS REAL)` for microsecond timestamps)
- **`localtime_r` broken on glibc 2.x** — use `std.time.epoch` (offset `+719468`, NOT `+2440588`)
- **Migration helper:** `addColumnIfMissing(db, alloc, table, column, definition)` where `definition` = `"col_name TYPE"`
- **Migration registration trap:** defining `MigrationNNN` struct is NOT enough — must register in `allMigrations` slice

## 8. Frontend (Vue 3) Patterns

- **vite-tsc only runs in `bun run build`** — vitest does NOT type-check (TS2532, etc.)
- **`apiFetch` mocks need both `text()` AND active Pinia** (uses `response.text()` + `useNotificationStore()` on non-OK)
- **`defineExpose` auto-unwraps refs** — parent reads raw value, NOT `{ value: T }`; update interface + call sites together
- **`??` does NOT coalesce empty string to null** — use `||` or explicit `=== '' ? null` for SQL `COALESCE(col, '')` shape
- **jsdom normalizes hex colors to `rgb()`** in `wrapper.attributes('style')`
- **Browser EventSource named events** need `addEventListener('name', cb)` — not just `onmessage`
- **`v-if / v-else-if` chain attaches to MOST RECENT preceding `v-if`** — independent blocks need N× `<v-if>`
- **Vue 3 async `onMounted` race:** set "ready" flag LAST; tests poll with bounded loop
- **`IntersectionObserver` missing in jsdom** — install no-op default in `beforeEach`, override with capturing mock per test
- **`<template v-for>` only scopes `idx` inside its body** — access `node.element.id` from sibling template fails
- **SPA HTML5-history reload 404:** needs prefix-scoped SPA fallback (`StaticDirConfig.spa_fallback_prefix`)
- **fixed top-right badges need `pointer-events-none`** — z-index controls paint only, not hit testing
- **`cloak_browser` snapshot doesn't capture JS-rendered content** — use API endpoints instead (FX rates)
- **vue-tsc --build emits .js files** next to .ts source — delete them before committing
- **vue-test-utils + missing IntersectionObserver** cascades to next test — install default no-op

## 9. Vue Testing Conventions

- **NEVER write static-contract tests** — user rule (2026-07-29). Always behavioural: call function, assert return; mount component, assert DOM
- **`agentic_loop/` requires INLINE tests** (per README), not separate `_test.zig` files — only exception is `parsing_test.zig`. Other dirs use `*_test.zig`
- **`setActivePinia(createPinia())`** in `beforeEach` for any `useNotificationStore` mock
- **vue-test-utils dragstart must fire BEFORE drop** — composable's `draggedIds` resets on each drop
- **`virtualScrollerRef.value.containerRef`** is raw `HTMLElement` (auto-unwrapped), NOT `{value: HTMLElement}`

## 10. Kanban / Project Workflow

- Every task MUST move through columns: `start` → milestone (stay) → `complete` → `merged`
- **PR index** in `docs/SPEC.md` §10.2.1 — every merged feature adds entry
- Spec frontmatter row format: `[<X>@<version>] <fact>` with **single line per fact**
- AGENTS.md is append-only changelog — add "### YYYY-MM-DD: <title>" block per landed feature
- Skills saved to: cross-project → `~/.config/nalar/memories/`, project-only → `.nalar/memories/`

## 11. Recent Changes — Most Impactful (chronological)

- **2026-08-06 — Single-element drag freezes** (latent v6 bug): `updateDesignElementGeometry` not mirroring response. Fix: 13-line mirror matching batch endpoint; 8 new behavioural tests in `workspacesStoreSingleGeometry.spec.ts`
- **2026-08-06 — Chat scroll position persistence** (close → reopen): new `useChatScrollRestore` + `VirtualScroller.scrollToPosition` + `VirtualScrollerExposed` interface fix (all 12 call sites had `.value.value`)
- **2026-07-31 — Design layer drag-to-join-or-leave-group** (Figma-style): `reparentElements` + `POST .../elements/reparent-batch` + cycle preflight via recursive CTE
- **2026-07-30 — Design group drag SSE compounds delta:** capture ORIGINAL positions on first pointermove; reset snapshot on `handleDragEnd` (PR #144 broke this)
- **2026-07-30 — Nested @pointerdown + setPointerCapture:** bubble-steals-capture → use `.stop` modifier or `event.stopPropagation()`
- **2026-07-29 — NEVER static-contract tests** (user rule). Design complete (drag/multi-select/snap/nudge/constrain)
- **2026-07-29 — Kanban task tags** (Migration 067, JSON-encoded string column, `[a-zA-Z0-9_-]`, djb2 color)
- **2026-07-28 — Design Page ↔ WorkspaceItemTask 1:1 FK** (Migration 066): eager task creation, NO `REFERENCES` (SQLite limitation), UNIQUE index
- **2026-07-28 — AppLayout close handlers strip URL pageId** — 4 close handlers + 1 forward-sync pattern missing pageId
- **2026-07-27 — Service files moved** to `src/service/`; `root.zig` keeps backward-compat aliases
- **2026-07-26 — OS crash handler** (POSIX sigaction + Win32 SetUnhandledExceptionFilter), 10 tests
- **2026-07-26 — Design chat 💬** exact-name lookup orphans prior chats → message-probe fallback (`taskHasMessages` w/ limit=1)
- **2026-07-26 — Kanban notification icon** (Migration 065 `last_human_touched_at`): green checkmark = reviewed, orange dot = awaiting
- **2026-07-25 — Design drag-and-drop wire repaired** (TODO no-op → real handler)
- **2026-07-25 — Design-mode multi-select + group drag + snap + keyboard nudge**
- **2026-07-15 — Bash FD leak** (foreground path, 555/556 orphan pipes from raw `waitpid`)
- **2026-07-15 — `retryDelayMs` extracted** to `retry_delay_ms.zig`; tests updated
- **2026-07-04 — CI:** dropped macOS `brew update`, Linux `pacman -Syu`; added webkit2gtk to Linux CI

## 12. Inventory — Files / Skills / Workers

### Memory files
- **Local** (project): desktop-app-webkitgtk-zig-016-cimport-broken, nalar-data-and-routines, nalar-frontend-patterns, nalar-infra-and-build, project-working-patterns, prompts-zig-requires-tool-gate-static-sections, vue-3-horizontal-scroll-restore-on-remount, vue-3-v-if-chain-attaches-to-previous-sibling, vue-3-virtual-scroller-reactive-scrollability, zig-0.16-stdlib-changes, zig-build-and-test, zig-cross-platform, zig-defer-scoped-inside-if-else-block, zig-json-deep-copy-before-deinit, zig-language-quirks, zig-path-join-non-null-terminated-slice, zig-sqlite-patterns, zig-test-cleanup-deeply-nested-dirs, webapp-rebuild-bun-cjs-loader-skips-fs-readfilesync, kanban-create-shape-mismatch-untitled-project, design-tab-button-needs-full-wire, kanban-lazy-load-tasks, nalar-backend-architecture, design-element-rectangle-covers-iframe, design-chat-canonical-name-lookup-orphans-prior-chats, design-chat-per-page-sessions, applayout-close-handlers-strip-url-params, design-page-task-fk, kanban-tags-free-form-string-list, agent-tool-creation-pattern, conditional-prompt-block-gated-on-tool-equipped, design-mode-iframe-scrollbar-leak, vue-3-empty-string-vs-null-mismatch, design-group-drag-sse-stale-positions, custom-http-static-html-pattern, kanban-task-notification-icon
- **Global** (cross-project): add-skill-tool-prepends-frontmatter, migration-registration-trap, no-comments-on-logger-calls, static-contract-test-when-to-prefer-behavioural, race-condition-tests-use-stress-loop-with-small-delay, design-element-parent-id-tooling-gap, zig-mock-state-global-use-after-free-across-tests, nalar-agentic-loop-inline-tests-required, design-drag-throttle-vs-debounce-requires-local-optimistic-state, vue-intersection-observer-jsdom-cascade, zig-struct-default-value-cannot-capture-runtime-locals, design-layer-drag-end-to-end-verified, design-resize-handle-pointerdown-bubbles-to-wrapper, vue-3-defineexpose-auto-unwraps-refs, single-element-drag-frozen-no-local-mirror

### Skills
- **Global:** brainstorming, writing-plans, TDD, systematic-debugging, verification-before-completion, dispatching-parallel-agents, subagent-driven-development, requesting-code-review, receiving-code-review
- **Local:** desktop-frontend-build, vitest-resolve-alias-stub-for-bare-specifiers, vue-teleport-vitest-document-queryselector, vue-tsc-build-emits-js-files, zig-constcast-slice-helper-mismatch, zig-slice-headers-across-defer-lifetimes

### Active Workers (conflict watch)
- `task_1785508162594` @ `/home/ginwa/ginwaaitoolbox` (active, last touch <1m)

---

## 13. Open Items / TODO (from SPEC.md §5 Pending)

- **Smart-spacing / distribute-horizontal-vertical** (group/canvas layout)
- **Snap-to-grid toggle** (Figma parity)
- **Drag from layers-panel to canvas** (cross-list DnD)
- **Lock/hide elements** (schema migration needed)
- **Group containers — drag INTO a frame** (existing types but UI lacks)
- **Marquee drag-select** (Shift+click works for 1-5)
- **Chat cross-tab scroll sync** (currently localStorage only)
- **Page rename → rename paired chat task** (Migration 066 limitation)
- **Delete page → cascade-delete chat task** (manual cascade today)
- **sqlite3/openssl vcpkg wiring for Windows binary build** (cross-compile blocker)
- **`install:macos` / `install:macos-arm` build** (blocked on `build.zig` sysroot paths)

## 14. Quick-Reference Anti-Patterns (loudest alarms)

| Anti-pattern | Consequence |
|---|---|
| `child.wait(io)` after `child.kill(io)` | Panic: `child.id == null` assertion |
| `defer allocator.free("literal")` | `Invalid free` panic in debug |
| Anonymous structs in different positions | Distinct types — hoist to named struct |
| `?? null` on SQL `COALESCE(col, '')` empty-string | Buckets to wrong group (LayersPanel bug) |
| `field: T = runtime_local` in anonymous struct | `'X' not accessible outside function scope` |
| `pointer-events-none` on parent thinking it makes child click-through | Parent Z-still-paints; only events pass |
| `cp -r vendor/ /usr/local/share/` in build script | Windows has no `/usr/local/share` |
| `pathlib.Path("/tmp")` on macOS | macOS tmp is `/var/folders/...` — use `tempfile.gettempdir()` |
| `signal.SIGKILL` on Windows in Python | Use `taskkill /F` |
| Hardcoded `os.path.expanduser("~/.config/nalar")` on Windows | Use `os.environ["HOME"]` + `path.join` |
| Test with `expect(source).toContain('substring')` | User rejects — write behavioural |
| Treating `bun run build` success as type-check pass when bun-only env | vue-tsc silently no-ops — use `node node_modules/vue-tsc/bin/vue-tsc.js -b` |