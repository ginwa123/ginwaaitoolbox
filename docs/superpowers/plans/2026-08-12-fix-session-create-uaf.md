# Fix session_create use-after-free SEGV — Plan

**Goal:** Stop the server from SEGV-ing when `POST /api/llm/session` is hit. The crash is a use-after-free in the async-task boundary created by `parseFromSliceLeaky` → `emit_run_agent.concurrent`. Fix the lifetime contract at the sync→async boundary and stop trusting an `unreachable` after `std.c.raise` in the crash handler.

**Architecture:** Two surgical edits. (1) Move the per-string dupes in `ContextIPCTui.emit_run_agent` from *inside* the concurrent task to *before* the `concurrent` call, into the long-lived `self.allocator`, and have the concurrent task consume + free those owned slices. (2) Replace the `unreachable` after `std.c.raise` in `crash_handler.zig::handleCrashSignal` with a `while (true) {}` spin so a successful raise that doesn't immediately terminate doesn't trigger Zig's panic machinery.

**Tech Stack:** Zig 0.16, std.Io.Group, std.heap.ArenaAllocator.

## Crash evidence

From the user's crash log:

```
UG_HANDLER: req.body.len=302, body_start_20=302
=== CRASH: received signal SEGV (signal number 11) ===
/home/ginwa/ginwaaitoolbox/src/root.zig:101:58: 0x21cd21c in run (root.zig)
                    const copy_queue_message = local.dupe(u8, qmsg) catch unreachable;
/usr/lib/zig/std/mem/Allocator.zig:455:5: 0x11e1244 in dupe__anon_8143
    @memcpy(new_buf, m);
/usr/lib/zig/std/compiler_rt/memcpy.zig:170:17: 0x2309895 in copyFixedLength
        d[i] = s[i];

thread 3587939 panic: reached unreachable code
/home/ginwa/ginwaaitoolbox/src/service/crash_handler.zig:220:5: 0x2200687 in handleCrashSignal (root.zig)
    unreachable;
```

Two stacked defects:
- **Primary** — `local.dupe(u8, qmsg)` SEGVs while reading `qmsg`'s bytes; the underlying memory is freed.
- **Secondary** — the crash handler's `unreachable;` after `std.c.raise` is reached; Zig's panic machinery runs inside the signal handler; panic calls `std.c.abort` → SIGABRT → the handler re-enters with SIGABRT, the same loop plays out.

Both fixes are below.

## Root Cause

```
HTTP server (custom_http_server)
└── per-request ArenaAllocator (ctx.allocator)        ← owns req.body
    └── handler: sessionCreateHandler(ctx, req, res)
        ├── req.body ──────────────► 302 bytes of JSON
        ├── std.json.parseFromSliceLeaky(RequestSession, allocator=ctx.allocator, req.body, ...)
        │     → RequestSession where string fields are EITHER:
        │       (a) slice headers into req.body       (.alloc_if_needed, no copy — the common case)
        │       (b) heap-allocated copies             (only when strings span JSON tokens / escapes)
        │     The parser does NOT guarantee (b). Documented behaviour: may point into input.
        ├── useCase(...) called synchronously
        │     copies slice headers into local vars (parsed.session_name, parsed.queue_message, ...)
        ├── emit_run_agent(.{ .queue_message = queue_message, ... })
        │     passes slice headers to
        │     self.group_emit_session_create.concurrent(self.io, run, .{ ..., qmsg, ... })
        │     runtime captures args via @memcpy into a heap-allocated Group.Task (Threaded.zig:516)
        │     — copies the 16-byte slice HEADERS, NOT the bytes they point at.
        └── handler RETURNS
              ↓
            per-request ArenaAllocator is freed   ← req.body's memory is gone
              ↓
            runtime worker thread picks up the queued task, calls run(...) on a different thread
              ↓
            run(...) calls `local.dupe(u8, qmsg)` (root.zig:101)
              ↓
            dupe tries to read qmsg.len bytes from qmsg.ptr — the ptr is now dangling
              ↓
            @memcpy inside copyFixedLength (compiler_rt/memcpy.zig:170) reads unmapped / freed memory
              ↓
            SEGV (signal 11)
```

The `local.dupe` inside `run` was an attempt at the right idea — heap-allocate data the async task owns — but the dupes happen **after** the source memory has been freed. The async task can never recover from a UAF source.

The sibling routine path (`fire.zig::fireRoutine`) gets this right: it dupes into `di.allocator` **synchronously**, *before* `concurrent(...)`, and `runFire` frees the dupes via `defer di.allocator.free(...)` after using them. `emit_run_agent` should follow the same pattern.

## Why "switch to alloc_always" or "use parseFromSlice + Parsed(T)" doesn't work alone

- `alloc_always` fixes the parser so strings are owned — but `parseFromSliceLeaky` already requires `allocate = .alloc_always` to be set by the caller; the caller in `session_create.zig` doesn't set it. We could change the call, but it still leaks if the caller doesn't free the result, and we still have to manage the lifetime across the sync→async boundary explicitly.
- `parseFromSlice` returns a `Parsed(T)` whose arena is freed by `deinit` — the slices are valid until then. But that arena has the same problem: it's local to the handler, freed when the handler returns.

The fix has to be: **the strings must be duped into memory that outlives the HTTP request, before `concurrent` is called.** That's what the `fireRoutine` pattern does.

## Design Decisions

| ID  | Decision                                                                                                                                | Why                                                                                                | Alternative rejected                                                                              |
|-----|-----------------------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------|
| D1  | Move the dupes OUT of the concurrent task and INTO `emit_run_agent` (synchronous, before `concurrent`). Use `self.allocator` (long-lived).| Source memory (`req.body` arena) is freed when the handler returns. Duping after-the-fact doesn't help — duping before-hand does. | (a) Have the caller pre-dupe. (b) Capture the arena in the concurrent task and free it from there. (a) leaks the contract — the bug happened because nobody owned the dupes; D1 makes `emit_run_agent` own them. (b) couples lifetime to the HTTP arena which is short-lived. |
| D2  | The concurrent task (`run`) uses the owned slices directly (no second dupe) and frees them at the end.                                  | Avoids the wasted work of duping twice. `insert_worker` already manages its own arena for SQL params; `event_buss.emit` is synchronous. | Keep the dupes in `run` — would require carrying the original slice headers past the arena free, which is what got us here. |
| D3  | Drop the inner `ArenaAllocator` in `run`; pass `di_inner.allocator` to `insert_worker` instead.                                          | Nothing in `run` uses the arena for cross-call lifetime anymore — the only thing that needed an arena was the dupes (now removed). | Keep the arena for a hypothetical future — YAGNI.                                                |
| D4  | In `crash_handler.zig::handleCrashSignal`, drop `noreturn`, drop `unreachable`, and just `return` after `raise(sig)`. On raise failure fall through to `_Exit`. | The triggering signal is implicitly blocked in the thread's mask while the handler runs, so `raise(sig)` queues the signal and returns. When we return from the handler, the kernel's `sigreturn` restores the original mask, sees the pending signal, and dispatches it via SIG_DFL (which we installed in STEP 1) — terminate + core dump. `unreachable` after raise made Zig treat it as a panic → panic calls `abort()` → SIGABRT → handler re-enters for SIGABRT → loop (the secondary crash). A plain return is what the kernel expects. | Use `noreturn` + `while (true) {}` — spun forever in the smoke test because the pending signal is only dispatched when the handler returns, and `while (true)` never returns. Use `_Exit` unconditionally — would skip the core dump on the happy path. |
| D5  | Document the new contract on `EmitRunAgentInput`: slices are PASSED-THROUGH, not duped by `emit_run_agent`. `emit_run_agent` now dups them. | Future maintainers must not regress to passing borrowed slices.                                        | No comment — would repeat the same bug.                                                            |

## File Structure

```
EDIT src/root.zig                                     (~25 lines: emit_run_agent body + EmitRunAgentInput docs)
EDIT src/service/crash_handler.zig                    (~5 lines: noreturn, while(true), drop unreachable)
NEW  src/root.zig test or session_create_test.zig      (optional: a test that posts a session_create with a 302-byte body and verifies no crash — skipped if too much infra; the fix is small and the crash is deterministic.)
```

Total: **2 surgical edits** (D1-D5). No new files unless we want a regression test.

## Verification

1. **Build:** `timeout 180 zig build 2>&1 | tail -n 30` from `/home/ginwa/ginwaaitoolbox/.worktrees/fix-session-create-uaf` — must succeed with no errors.
2. **Existing tests:** `timeout 300 zig build test --summary all 2>&1 | tail -n 50` — must not regress.
3. **Manual repro:** start the server, `curl -X POST -H 'Content-Type: application/json' -d @body.json http://localhost:8081/api/llm/session` with a 302-byte JSON body (mirrors the user's request). Must return 201, no SEGV, no `unreachable` panic in stderr.
4. **Crash handler smoke:** intentionally induce a SEGV in a dev build (e.g. deref null), confirm:
   - Crash log shows the SEGV.
   - Process terminates via `SIGSEGV` (default), NOT via a Zig `reached unreachable code` panic.
   - No SIGABRT re-entry in the log.

## Pitfalls

- **Don't pre-dupe in `useCase`.** That's the easy-looking fix (handler is already synchronous, has `di`), but it changes the contract of `EmitRunAgentInput` (callers must own). `fireRoutine` already passes owned slices to a private emit-style path — `emit_run_agent` should be the *owner* of the dupes, not the caller. Putting the dupes at the sync→async boundary in `emit_run_agent` itself matches the `fireRoutine` pattern.
- **Don't keep the inner arena "just in case".** If something in the future needs cross-call lifetime in `run`, it'll be obvious what's needed at that point. Removing it now prevents the same shape of bug (long-lived arena surviving the handler scope).
- **`noreturn` on `handleCrashSignal` requires explicit `while (true) {}` — NOT `unreachable`.** Zig's safety checks turn `unreachable` into a panic. Inside a signal handler that just `raise()`d, a panic re-enters the handler — infinite loop. `while (true) {}` is async-signal-safe and bounds cleanly: the kernel terminates the process when the signal is delivered.
- **`std.c.raise` semantics: don't trust them.** POSIX `raise()` is documented synchronous for unblocked signals, but the signal is delivered via the kernel's pending-bit + return-from-syscheck path. There are edge cases (signal blocked by parent thread, process-wide vs thread-directed). Spinning after a successful `raise` is the safe choice; the kernel will deliver soon.

## Verification (updated after smoke test)

Ran `scripts/crash_handler_smoke.sh` against the patched binary — **5 passed, 0 failed** (SEGV, ABRT, ILL, FPE, BUS). Each signal: log file contains `=== CRASH: <signal> ===` + stack trace + signal name; process exits with non-zero (killed by SIG_DFL). The pre-fix code with `unreachable` triggered the same panic loop the user reported (SIGSEGV → SIGABRT → SIGABRT → …). The post-fix code logs the crash, the kernel dispatches the pending signal via SIG_DFL, the process terminates cleanly.

## Related follow-ups (NOT in this fix — separate cards)

- The `ConcurrentError!void` from `emit_run_agent` is now `try`d but its error path is opaque — if `concurrent` ever returns `error.ConcurrencyUnavailable` we want the caller to see it. Today we just propagate; that's fine.
- `insert_worker` is called with `local.allocator` (arena) but takes `allocator` as a parameter, so passing `di_inner.allocator` is straightforward — no signature change needed.
- The `event_buss.emit(RunParamsNew, ...)` payload still borrows from `run`'s owned strings. The LLM workflow's `runAgenticMultiStepnew` (workflow.zig:577-584) already dupes those into a fresh arena before doing real work — no change needed downstream.