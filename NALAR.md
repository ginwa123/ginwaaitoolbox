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

Plan: docs/superpowers/plans/2026-07-25-design-element-drag-and-drop.md (Chunk 2)

### What landed
- Selection is now `Set<string>` instead of `string | null`. Shift+click toggles membership; plain click is exclusive.
- Dragging one element in a multi-selection moves the entire selection (same dx/dy applied to all).
- Delete/Backspace removes every selected element (one keystroke).
- Escape clears the entire selection.
- PropertiesPanel renders a "N elements selected" banner when multiple are selected; the single-element form only shows for exactly one.

## 2026-07-25: Design mode snap-to-edges + alignment guides

Plan: docs/superpowers/plans/2026-07-25-design-element-drag-and-drop.md (Chunk 3)

### What landed
- Pure-function `computeSnapDelta` snaps within 6 design-px of any other element's edge/center.
- Canvas-center + canvas-edge fallback targets (snaps to page center when no other element is nearby).
- 1px violet SVG alignment guides render during drag and clear on pointerup.
- Group drag applies snap to the selection's union bbox (the whole group snaps together).

## 2026-07-25: Design mode keyboard nudge

Plan: docs/superpowers/plans/2026-07-25-design-element-drag-and-drop.md (Chunk 4)

### What landed
- Arrow keys move the selection by 1 design-px: ←/→ for x, ↑/↓ for y.
- Shift+arrow moves by 10 design-px (Figma's "big step").
- Input-focus guard preserved (PropertiesPanel X/Y inputs still get their arrow keys for cursor navigation).
- No-op when nothing is selected (no escape route from the canvas for stray arrows).

## 2026-07-25: Design mode element drag-and-drop (Figma-style) — COMPLETE

Plan: docs/superpowers/plans/2026-07-25-design-element-drag-and-drop.md

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
- `src/crash_handler.zig` (312 lines): POSIX `sigaction` for SEGV/BUS/ABRT/ILL/FPE; Windows `SetUnhandledExceptionFilter` via Win32 extern.
- `src/crash_handler_test.zig`: 10 static-contract tests (TDD red→green).
- `src/crash_handler_smoke.zig` + `scripts/crash_handler_smoke.sh`: end-to-end smoke (5/5 PASS on Linux).
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

Plan: docs/superpowers/plans/2026-07-26-crash-signal-handler.md (TBD)
Branch: worktree/crash-handler
Commit: 0418bc07
