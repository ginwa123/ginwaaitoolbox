# [fix: `retryDelayMs` @intCast panic on `now_ns > deadline_ns` race] Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the crash `panic: integer does not fit in destination type` in `src/ai_workflow/tui/agentic_loop/retry_delay_ms.zig:59` that aborts the entire `nalar` worker when the LLM stream returns `error.StreamInterrupted` (zero-chunk SSE) and the workflow enters its retry loop. The race is between the loop-top `now_ns >= deadline_ns` check (line 56) and the inner `now_ns` re-read (line 58) — between the two reads, wall-clock time advances and `now_ns` can become `>= deadline_ns`, making `deadline_ns - now_ns < 0`, which makes `@divFloor(<negative>, <positive>)` return a negative value, which makes `@intCast(... → u32)` panic.

**Architecture:**

1. **EDIT** `src/ai_workflow/tui/agentic_loop/retry_delay_ms.zig` — apply the existing `@max(deadline_ns - now_ns, 0)` clamp pattern (already used at line 48 in the cancellation branch) to the regular sleep path at line 59. This is the ONE-LINE surgical fix.

2. **NEW** `src/ai_workflow/tui/agentic_loop/retry_delay_ms_race_test.zig` — single behavioural test that calls `retryDelayMs` 200 times in a tight loop with `delay_ms = 1`. Pre-fix: the race window fires within ~200 iterations, panic aborts the test binary. Post-fix: all 200 iterations return `true` cleanly.

3. **EDIT** `src/ai_workflow/tui/test_runner.zig` — register the new test file.

**Tech Stack:** Zig 0.16 (project pin), SQLite (via `nalarcore.sqlite.SqliteBackend` in-memory DB pattern from `workflow_compaction_envelope_test.zig:13-75`), `std.Io.Clock.now` for the race condition reproduction.

**Decisions taken (with rationale):**

1. **Fix is ONE line** — `deadline_ns - now_ns` → `@max(deadline_ns - now_ns, 0)`. Matches the existing cancellation-branch pattern at line 48. Don't refactor more (no "while I'm here" additions); the rest of the function is correct.

2. **Behavioural test only, no static-contract grep** — per the project lesson that grep tests are decoration around what should be a real behavioural call. The 200-iteration loop with `delay_ms = 1` reliably hits the race window in debug builds (where `@intCast` panics loudly on negative values); pre-fix the test binary aborts with non-zero exit, which `zig build test` reports as a failure. Post-fix the test passes deterministically.

3. **Out of scope (acknowledged but NOT in this plan):** the upstream "stream returns 0 chunks" issue in `Agent.zig:1363` (returning `error.StreamInterrupted` for empty SSE responses). That's a separate bug — the retry mechanism correctly catches it and re-attempts; the workflow's `retry_count > 10` bail is the eventual guard. Fixing the upstream issue (e.g., distinguishing "server closed before any bytes" from "client cancelled mid-stream") would be a follow-up plan.

## Global Constraints

- **Cross-platform (Linux + macOS + Windows)** — the fix is pure Zig, no platform-specific code. The behavioural test uses `std.Io.Clock.now(.real, std.testing.io)` which is cross-platform. On non-Linux the test may be skipped via `return error.SkipZigTest` if the race window is too narrow to reliably hit (debug-mode `@intCast` is platform-independent in behaviour, but timing characteristics differ).
- **Zig 0.16 stdlib** — `@max(i96, i96)` returns `i96`, `@intCast` accepts any source integer type. No stdlib API removals affect this fix.
- **TDD** — behavioural test first (RED), then fix (GREEN).
- **Surgical patch** — one-line change in `retry_delay_ms.zig`. No refactoring of the surrounding loop body (it's already correct apart from the missing clamp).
- **Verification before completion** — `zig build test --summary all` + `zig build install:linux:system` + `rm -rf zig-out/bin && zig build` must all pass before any task is marked complete.
- **No frontend changes** — backend-only fix.
- **No DB migrations** — fix is purely a memory-time arithmetic clamp.

## File Touch Map

| File | Action | Lines changed (est.) |
|---|---|---|
| `src/ai_workflow/tui/agentic_loop/retry_delay_ms.zig` | EDIT | +1 / -1 |
| `src/ai_workflow/tui/agentic_loop/retry_delay_ms_race_test.zig` | NEW | ~100 |
| `src/ai_workflow/tui/test_runner.zig` | EDIT | +1 |

Total: ~3 files, +3 / -1 net. No DB migrations, no frontend changes, no new dependencies.

---

## Tasks

### Task 1 — Behavioural stress test (RED)

**Goal:** Write a test that calls `retryDelayMs` 200 times with `delay_ms = 1`. Pre-fix, this panics on a random iteration; post-fix, it passes deterministically.

**File:** `src/ai_workflow/tui/agentic_loop/retry_delay_ms_race_test.zig`

- [ ] **Step 1.1** — Create the new test file with preamble and `setupDb` / `teardownDb` helpers mirroring `workflow_compaction_envelope_test.zig:13-80`:
  ```zig
  const std = @import("std");
  const testing = std.testing;
  const sqlite = @import("nalarcore").sqlite;
  const logger_mod = @import("nalarcore").loggermod;
  const retry_delay_ms = @import("retry_delay_ms.zig");
  const builtin = @import("builtin");

  fn setupDb() !struct {
      db: sqlite.SqliteBackend,
      threaded: std.Io.Threaded,
  } {
      const alloc = testing.allocator;
      var threaded = std.Io.Threaded.init(alloc, .{});
      errdefer threaded.deinit();
      const io = threaded.io();
      var db: sqlite.SqliteBackend = .{};
      errdefer db.deinit();
      try db.init(io, ":memory:");
      // isWorkerCancelled does `db.query("SELECT ... FROM workers ...")`.
      // The table doesn't need to exist for the SELECT to return zero rows
      // gracefully — but CREATE TABLE here for parity with the production
      // schema so future refactors don't break the test silently.
      try db.exec(alloc, "CREATE TABLE workers (id TEXT PRIMARY KEY)", &.{});
      return .{ .db = db, .threaded = threaded };
  }

  fn teardownDb(s: *@TypeOf(setupDb() catch unreachable)) void {
      s.db.deinit();
      s.threaded.deinit();
  }
  ```

- [ ] **Step 1.2** — Register the new test file in `src/ai_workflow/tui/test_runner.zig` (insert immediately after the existing `workflow_retry_delay_test.zig` entry at line 14):
  ```zig
  _ = @import("agentic_loop/retry_delay_ms_race_test.zig");
  ```

- [ ] **Step 1.3** — Add the test:
  ```zig
  test "retryDelayMs does not panic over 200 calls with delay_ms = 1 (race-window stress)" {
      // Pre-fix: std.Io.Clock.now advances between the loop-top check at
      // retry_delay_ms.zig:56 and the inner re-read at line 58. With
      // delay_ms = 1 (a 1ms deadline), the race window is small but reliably
      // hits within ~200 iterations in debug builds. @intCast(<negative>, u32)
      // panics with "integer does not fit in destination type" — aborts the
      // test binary with non-zero exit.
      //
      // Post-fix: deadline_ns - now_ns is clamped to >= 0 via @max before
      // the cast, so the function returns true cleanly on every iteration.
      //
      // Why 200 iterations: empirically the race fires within ~50-100 calls
      // on debug builds; 200 leaves a safety margin. If this turns flaky on
      // slow CI, bump to 500.
      //
      // Skip in ReleaseFast / ReleaseSmall: @intCast wraps negative → u32
      // silently there, so the bug wouldn't surface as a panic — the test
      // would falsely pass. We only run in Debug to catch the real bug.
      if (builtin.mode != .Debug) return error.SkipZigTest;

      var s = try setupDb();
      defer teardownDb(&s);
      const alloc = testing.allocator;

      var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});
      defer lg.deinit();

      var i: usize = 0;
      while (i < 200) : (i += 1) {
          const result = retry_delay_ms.retryDelayMs(.{
              .allocator = alloc,
              .delay_ms = 1,
              .db = &s.db,
              .session_id = "race_test_session",
              .io = s.threaded.io(),
              .logger = &lg,
          });
          try testing.expect(result == true);
      }
  }
  ```

- [ ] **Step 1.4** — Run `timeout 180 zig build test --summary all 2>&1 | tail -n 5`. The behavioural test should FAIL (pre-fix panic → non-zero exit → `zig build test` reports the failure). Expected: the test binary aborts with `thread N panic: integer does not fit in destination type` at `retry_delay_ms.zig:59`, `zig build test` exits with a failure summary.

  If the test passes deterministically pre-fix (race window too narrow on this machine), bump iteration count to 500 and retry. If still doesn't fail, the race is timing-impossible on this host and we need an alternative test approach (e.g., mock `std.Io.Clock.now` via a function-pointer injection — defer to plan author).

- [ ] **Step 1.5** — Commit: `git add src/ai_workflow/tui/agentic_loop/retry_delay_ms_race_test.zig src/ai_workflow/tui/test_runner.zig && git commit -m "test(retry_delay_ms): red — 200-iteration stress test exercises now_ns > deadline_ns race window"`.

### Task 2 — Apply the one-line fix (GREEN)

**Goal:** Add the `@max(deadline_ns - now_ns, 0)` clamp at line 59 of `retry_delay_ms.zig`, making the behavioural test from Task 1 pass.

**File:** `src/ai_workflow/tui/agentic_loop/retry_delay_ms.zig`

- [ ] **Step 2.1** — Open `src/ai_workflow/tui/agentic_loop/retry_delay_ms.zig` and locate the multi-line `@intCast(@divFloor(\n            deadline_ns - now_ns,` at lines 59-62.

- [ ] **Step 2.2** — Replace lines 59-62:
  ```zig
          const remaining_ms: u32 = @intCast(@divFloor(
              deadline_ns - now_ns,
              std.time.ns_per_ms,
          ));
  ```
  with:
  ```zig
          const remaining_ns: i96 = @max(deadline_ns - now_ns, 0);
          const remaining_ms: u32 = @intCast(@divFloor(
              remaining_ns,
              std.time.ns_per_ms,
          ));
  ```
  The variable rename to `remaining_ns` mirrors the cancellation branch's variable name at line 48 for consistency. No comment needed — the `remaining_ns` naming + the `@max` clamp speak for themselves (per the project lesson "no comments on logger calls / clear code").

- [ ] **Step 2.3** — Run `timeout 180 zig build test --summary all 2>&1 | grep -E "retryDelayMs does not panic"` and confirm the behavioural test from Task 1 now PASSES (GREEN).

- [ ] **Step 2.4** — Run the full test suite: `timeout 180 zig build test --summary all` and confirm no regressions (test count delta: +1 net).

- [ ] **Step 2.5** — Run `timeout 180 zig build install:linux:system` to catch any lazy-analysis errors the test target misses.

- [ ] **Step 2.6** — Run `rm -rf zig-out/bin && timeout 360 zig build` for a fresh full rebuild.

- [ ] **Step 2.7** — Commit: `git add src/ai_workflow/tui/agentic_loop/retry_delay_ms.zig && git commit -m "fix(retry_delay_ms): clamp deadline_ns - now_ns to >= 0 before @intCast (prevents panic when stream returns 0 chunks and workflow enters retry loop)"`.

### Task 3 — Cross-platform compile verification

**Goal:** Verify the fix compiles cleanly on Linux, Windows, and macOS targets. The fix is platform-independent pure Zig (uses only stdlib builtins `@max`/`@intCast`/`@divFloor`, which are inherently cross-platform), but lazy analysis on the install target doesn't always reach this file from `main.zig`'s root import path; the standalone `zig build-obj` technique (per project memory `zig-cross-platform.md`) is the cheapest verification.

- [x] **Step 3.1** — Cross-compile via standalone stub **not feasible** for this file. The `retry_delay_ms.zig` chain reaches `agentic_loop/mod.zig:1` which does `pub const nalarcore = @import("nalarcore");` — when mod.zig is included as part of the nalarcore module (via root.zig), this becomes a recursive import. Attempted variants tried during implementation:
  - `--dep nalarcore -Mroot=src/test_mod_cross.zig -Mnalarcore=src/root.zig` (stub in src/) → `file exists in modules 'root' and 'nalarcore'`
  - `--dep nalarcore -Mroot=/tmp/test_mod_cross.zig -Mnalarcore=src/root.zig` (stub in /tmp per memory pattern) → `no module named 'nalarcore' available within module 'nalarcore'` (recursive)
  - `-Mroot=src/ai_workflow/tui/agentic_loop/test_mod_cross.zig` (stub inside module) → `import of file outside module path` from sibling workflow.zig (uses `@import("../handle_tool.zig")` etc.)

  This is the pre-existing cross-compile limitation documented in `zig-cross-platform.md` ("Cross-compile build is blocked by pre-existing issues — `zig build install:windows` cannot produce binaries on a Linux host"). For a fix that uses only stdlib builtins, the Linux test pass (`zig build test --summary all`) already verifies the type-check graph through the test file's `@import("retry_delay_ms.zig")`. Skipped intentionally; no regression vs pre-existing state.

- [x] **Step 3.2** — Linux verification (the available platform): `timeout 180 zig build test --summary all` reports 1945/1951 tests passed (6 skipped, no failures); `timeout 180 zig build install:linux:system` builds `zig-out/bin/nalarcore-linux-x86_64` (82 MB) successfully (cp-to-`/usr/local/bin/nalar` fails harmlessly with permission — pre-existing); `rm -rf zig-out/bin && timeout 360 zig build` succeeds fresh.

---

## End-to-end smoke test (verification, run by hand)

**NOT a task** — this is the final manual check to verify the production crash is gone. Skip if the test suite is green (Task 1's stress test already exercises the race window).

**Implementation outcome (2026-07-29):** Task 1's stress test passed on the first run after the fix (RED baseline confirmed on a prior run with the un-fixed code — captured in stderr output). The end-to-end smoke against a running binary was NOT run because the test target's 200-iteration stress loop reliably reproduces the race condition in debug builds (the panic fired on the unfixed code, captured in the zig build test stderr). Smoke against running nalar would only confirm what the test already does.

```bash
# 1. Build the binary on port 8080 (NEVER 8081)
cd /home/ginwa/ginwaaitoolbox
timeout 180 zig build install:linux:system

# 2. Start isolated server
rm -rf /tmp/nalar-smoke-fix && mkdir -p /tmp/nalar-smoke-fix
env -i HOME=/tmp/nalar-smoke-fix PATH=$PATH \
  nohup ./zig-out/bin/nalarcore-linux-x86_64 --port 8080 \
  >/tmp/nalar-smoke-fix.log 2>&1 &
disown
sleep 4

# 3. Trigger a session that exercises the retry path. Easiest way: send a
#    message via the existing /api/llm/session endpoint with an invalid
#    api_key so the LLM call fails. The workflow will retry 10 times, each
#    retry calling retryDelayMs(config.retry_delay_ms). Pre-fix this would
#    panic on iteration 1-2. Post-fix: 10 retries complete cleanly with no
#    crash, ending with TooManyRetries bail.

WS=$(curl -sS -X POST http://127.0.0.1:8080/api/workspaces \
  -H 'content-type: application/json' -d '{"name":"smoke"}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')

curl -sS -X POST "http://127.0.0.1:8080/api/llm/session" \
  -H 'content-type: application/json' \
  -d "{\"workspace_id\":\"$WS\",\"message\":\"hello\",\"api_key\":\"INVALID\",\"base_url\":\"http://localhost:9999\",\"cwd\":\"/tmp\"}" \
  >/dev/null

# Wait for the workflow to exhaust retries (~30-60 seconds with default retry_delay_ms=0)
sleep 60

# 4. Check the log for the panic
grep -i "panic\|integer does not fit" /tmp/nalar-smoke-fix.log
# Expect: no output (no panic)

# 5. Verify the workflow completed via the TooManyRetries bail
grep -i "TooManyRetries\|retry" /tmp/nalar-smoke-fix.log | head -n 5
# Expect: at least one line indicating retry attempts and the final bail

# 6. Cleanup
PID=$(pgrep -f "nalarcore-linux-x86_64 --port 8080")
[ -n "$PID" ] && kill "$PID"
```

**Success criteria:** no `panic: integer does not fit in destination type` in the log; the workflow completes with the TooManyRetries bail; the binary does not crash.

---

## Reference

- **Symptom log:** `[err] [STREAM] stream ended without finish_reason (chunks=0)` followed by `panic: integer does not fit in destination type` at `retry_delay_ms.zig:59`.
- **Trigger condition:** upstream LLM stream returns `error.StreamInterrupted` (Agent.zig:1363) → workflow catches error at `workflow.zig:1085` → enters the `retryDelayMs` retry-sleep path at `workflow.zig:668-678`.
- **Existing pattern:** the cancellation branch in `retry_delay_ms.zig:48` already uses `@max(deadline_ns - now_ns, 0)` — the regular sleep branch was missed.
- **Related code:** `src/modules/agent/Agent.zig:1363` (the upstream `error.StreamInterrupted` source — separate bug, out of scope for this plan).
- **Project memory:** `zig-language-quirks.md` ("`@intCast` panics on negative → unsigned conversion in debug mode").
- **Project memory:** `static-contract-test-when-to-prefer-behavioural` (rationale for using a real behavioural call instead of grep tests).