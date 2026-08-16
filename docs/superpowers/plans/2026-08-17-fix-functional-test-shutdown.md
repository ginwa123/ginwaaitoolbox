# Fix functional test teardown slowness

## Goal

Cut the functional-test suite wall-clock from ~8m26s to ~1m by eliminating the
~10s of wasted teardown time per test. Measured locally: 64 tests × 10s each
= 641s of teardown = 93% of total wall-clock. Target: 506s → ~80s.

## Root cause

Three bugs compounding, in order of fix:

1. **`/test/shutdown` is a no-op graceful shutdown.** The Zig handler
   (`src/ai_workflow/tui/http_handlers/shutdown.zig`) calls
   `di.server.shutdown()` which marks the listener as not running, but the
   process keeps serving in-flight requests and never exits. The harness's
   graceful-shutdown wait always times out.

2. **The cronjob manager thread outlives main's defers.** Started in
   `GinwaServer.listen()` (via `cronjob_manager.start()`), never stopped
   before `main` returns. After main's defers free the SQLite WAL pages and
   the LlmConfig, the cronjob thread tries to dereference them and segfaults
   ~10s later with `rc=-11` (SIGSEGV). Pre-fix measurement: process exits
   with SIGSEGV at t=10.5s after /test/shutdown.

3. **The harness polls `os.kill(pid, 0)` to detect death.** That syscall
   returns 0 for **zombie** processes (the process is dead but the parent
   hasn't reaped it). After a graceful `std.process.exit(0)`, the binary
   becomes a zombie almost immediately, but Python's `os.kill(pid, 0)` keeps
   reporting "alive" until the parent reaps the zombie. The harness never
   reaps (it only stored `proc.pid`, not the `Popen` object), so the wait
   poll ALWAYS times out the full budget (5s + 5s in the original).

   Post-cronjob-fix, the process exits cleanly within ~50ms, but the zombie
   lives until the harness process dies (i.e. never, until pytest exits).
   So the harness's 1s polling budget per phase is exhausted three times
   (3s total) on every test.

## Fix

### `src/ai_workflow/tui/http_handlers/shutdown.zig`

The `/test/shutdown` endpoint is **test-only** (production uses the `nalar
service` daemon + SIGTERM). Make it actually exit the process by spawning a
detached thread that calls `std.process.exit(0)` after a 50ms sleep (so the
HTTP response has time to flush over the wire).

```zig
const spawn_fn = struct {
    fn run() void {
        var ts = std.c.timespec{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
        std.process.exit(0);
    }
}.run;
if (std.Thread.spawn(.{}, spawn_fn, .{})) |_| {} else |_| {
    std.process.exit(0);
}
return .{ .message = "Server shutdown initiated" };
```

If thread spawn fails (resource exhaustion), exit synchronously — the
client doesn't need a 200 response if we're going to terminate anyway.

### `src/main.zig`

Stop the cronjob manager thread before main returns. Order matters: the
cronjob thread ticks every 1s and references the running LlmConfig and the
SQLite WAL. Stop it BEFORE the defers at the top of main (which free both).

```zig
try gs.listen(); // blocks until the server is stopped

// cronjob thread MUST be joined before main's defers run, otherwise it
// outlives the freed SQLite WAL + LlmConfig and segfaults ~10s later.
gs.cronjob_manager.stop();
gs.sse_manager.stop();
```

### `tests/functional/harness.py`

Two changes:

**(a) `_wait_dead` uses `os.waitpid(pid, WNOHANG)` instead of `os.kill(pid, 0)`.**

`waitpid(WNOHANG)` returns:
- `(0, 0)` — process is still running, no zombie
- `(pid, status)` — child has exited and we JUST reaped it
- raises `ChildProcessError` (ECHILD) — child doesn't exist

That's the correct signal in a parent-of-subprocess context. `os.kill(pid, 0)`
reports success for zombies, which is why the old code stalled forever.

Windows fallback: `os.waitpid` is unavailable on Windows; fall back to
`os.kill(pid, 0)`. Windows doesn't have zombie processes, so the heuristic
is sufficient there.

**(b) Teardown polling budget tightened from 5+5+5s to 1+1+1s.**

The 1s budget is safe because `/test/shutdown` exits the process within
~50ms in the common case. The SIGTERM/SIGKILL steps are the safety net for
future regressions.

### `tests/functional/smoke_boot_test.py`

Add `test_teardown_completes_within_3s` regression test that boots a fresh
nalar, drives `health()`, and asserts `teardown()` finishes in < 3s. The
budget is 15× the measured post-fix teardown (~0.2s) — generous for slow CI
runners, but 3× tighter than the old failing 10s behavior. If it regresses,
the suite will go from ~3 min back to ~10 min.

## Verification

Local measurements (single-core, Linux x86_64, nalar-core Debug build):

| | Before | After |
|---|---|---|
| Suite wall-clock | 506.33s (8m26s) | 51.05s (51s) |
| Per-test teardown | 10.01s (every test) | ~0.2s |
| Total teardown time | ~641s (93% of suite) | ~13s |
| Test count | 64 | 65 (new regression test) |
| Pass / Skip / Fail | 64 / 0 / 0 | 65 / 0 / 0 |

Zig test suite (`zig build test --summary all`): 2338 pass, 6 skip, 0 fail —
unchanged from the pre-fix baseline.

## Risk

Low. The Zig changes are localized to the test-only shutdown endpoint and
the existing shutdown-order at the end of `main`. The cronjob fix matches
the documented intent of `cronjob_manager.stop()` (idempotent, joins the
thread). The harness changes are pure Python and the new `waitpid` logic
falls back to `os.kill(pid, 0)` on Windows.

prod paths unaffected:
- `nalar service start/stop` uses SIGTERM, not the `/test/shutdown` endpoint
- The desktop app uses Tauri IPC, not HTTP shutdown
- The Vue frontend doesn't call `/test/shutdown`
