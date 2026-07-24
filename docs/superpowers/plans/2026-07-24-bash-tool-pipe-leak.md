# Bash Tool Foreground Pipe FD Leak — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop `execute_bash` from leaking 2 pipe FDs (stdout + stderr parent read ends) on every successful foreground call — currently ~280 leaked pipes accumulate per hour of agent activity.

**Architecture:** Add an explicit pipe-close block AFTER the deadline-race loop in `execute_bash`'s foreground path. The block runs once for every code path that exits the loop (`.reaped`, `.no_child`, `.grace_period_expired`, `.unexpected_error`), removing the per-arm duplication. The close happens BEFORE `stdout_thread.join()` so reader threads exit immediately (they may have already seen EOF in the happy path, or they get EBADF in the D-state path).

**Tech Stack:** Zig 0.16, `std.Io`, `std.process.Child`, raw libc `waitpid` + `nanosleep` (already imported via `bash.zig`)

---

## Background — root cause (verified 2026-07-24)

### Empirical evidence (running nalar PID 2134141 on port 8081)

```
$ ls /proc/2134141/fd | wc -l
556

$ # unique pipe inodes held by this process
$ ls -la /proc/2134141/fd | awk '{print $NF}' | grep '^pipe:' | sort -u | wc -l
555
```

**555 unique pipe inodes are orphaned** (held only by this process; the other end was closed when the child exited). Each successful `execute_bash` call leaks 2 FDs (stdout + stderr parent read ends) → ~277 leaked bash calls in the session's 70-minute lifetime.

The orphan-pipe signature is confirmed: `holders=1` for all 555 pipe inodes.

### The bug

`src/modules/agent/tools/bash.zig` foreground path (lines 404–770):

```zig
var child = try std.process.spawn(io, .{
    .argv = &.{ "bash", "-c", command },
    ...
    .stdin = if (input.stdin_data != null) .pipe else .close,
    .stdout = .pipe,
    .stderr = .pipe,
    .pgid = 0,
});
// ... spawn reader threads ...
child_term = blk: {
    while (true) {
        if (stdout_eof.load(.acquire) and stderr_eof.load(.acquire)) {
            const wait_result = waitPidBounded(io, child_pgid, KILL_GRACE_PERIOD_NS);
            switch (wait_result.outcome) {
                .reaped => break :blk statusToTerm(wait_result.status),     // ❌ LEAK
                .no_child => break :blk .{ .exited = 0 },                    // ❌ LEAK
                .grace_period_expired, .unexpected_error => {
                    if (child.stdout) |stdout_pipe| stdout_pipe.close(io);   // ✅ OK
                    if (child.stderr) |stderr_pipe| stderr_pipe.close(io);   // ✅ OK
                    break :blk if (...) ... else ...;
                },
            }
        }
        if (... >= deadline_ns) {
            timeout_hit = true;
            _ = std.posix.kill(-child_pgid, .KILL) catch {};
            const wait_result = waitPidBounded(io, child_pgid, KILL_GRACE_PERIOD_NS);
            switch (wait_result.outcome) {
                .reaped => break :blk statusToTerm(wait_result.status),     // ❌ LEAK
                .no_child => break :blk .{ .exited = 0 },                    // ❌ LEAK
                .grace_period_expired, .unexpected_error => {
                    if (child.stdout) |stdout_pipe| stdout_pipe.close(io);   // ✅ OK
                    if (child.stderr) |stderr_pipe| stderr_pipe.close(io);   // ✅ OK
                    break :blk if (...) ... else ...;
                },
            }
        }
        const ts = NanoSleepTimespec{...};
        _ = nanosleep(&ts, null);
    }
};
// Join the reader threads.
stdout_thread.join();
stderr_thread.join();
```

**Why `waitPidBounded` does NOT close pipes**: the helper uses raw libc `std.c.waitpid` (line 124) which only reaps the zombie — it does NOT trigger Zig 0.16's `childCleanupPosix` defer. Only `child.wait(io)` would call `childCleanupPosix` and close the parent's pipe FDs.

**Why the bash tool uses `waitPidBounded` instead of `child.wait(io)`**: the author explicitly avoided `child.wait(io)` (which uses blocking `waitpid`) because D-state descendants would hang the agent forever. The comment at line 421–430 acknowledges `child.wait(io)` would close the pipes — but then the IO.Select→waitPidBounded refactor (2026-07-15, commit `sse-fd-leak`-era) silently broke the pipe-cleanup contract without adding a manual close.

**Why existing tests miss the bug** (`src/modules/agent/tools/bash_test.zig:461`):
1. `countOpenFds()` (line 270) uses `execute_bash` itself to count FDs — so the test infrastructure leaks FDs on every call.
2. `bash_tool: no FD leak after single call` permits `diff <= 2` — exactly the leak amount per call.

---

## File Structure

### Files to modify
- **`src/modules/agent/tools/bash.zig`** — add post-loop pipe-close block in `execute_bash`'s foreground path; remove the now-redundant per-arm pipe-close lines in the `.grace_period_expired`/`.unexpected_error` arms.
- **`src/modules/agent/tools/bash_test.zig`** — tighten the existing FD-leak tests; add a 100-iteration stress regression test.

### Files to create
- None — modifications only.

### No file additions needed
The fix is in-place and does not warrant a new module.

---

## Task Decomposition

### Task 1: Write a failing regression test that catches the per-call FD leak

**Files:**
- Modify: `src/modules/agent/tools/bash_test.zig:461-494` (existing `bash_tool: no FD leak after single call` test)
- Test: `src/modules/agent/tools/bash_test.zig`

- [ ] **Step 1: Read the existing test to confirm its current shape**

Open `src/modules/agent/tools/bash_test.zig:461-494`. The current test:
- calls `countOpenFds()` before,
- calls `execute_bash` once,
- calls `countOpenFds()` after,
- asserts `diff <= 2`.

- [ ] **Step 2: Tighten the tolerance and assert 0 FDs leaked**

Edit the test to:
1. Call `countOpenFds()` BEFORE the call (existing).
2. Call `execute_bash` ONCE (existing).
3. Call `countOpenFds()` AFTER the call (existing).
4. Change the assertion from `try testing.expect(diff <= 2);` to `try testing.expect(diff == 0);`.

Plus add a sibling test (place immediately after the existing one at line 495) for the kill/timeout path — it currently exists at line 496 but also has `diff <= 2` tolerance. Tighten it to `diff == 0` too.

This MUST FAIL on current `main` because every bash call leaks 2 FDs and the test's tolerance is exactly 2.

- [ ] **Step 3: Run the test to confirm it fails**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | grep -E "(bash_tool.*FD leak|fail|expected.*0|test.*FD leak)"
```

Expected output (red-green baseline): the two tightened tests fail with `expected 0, found 2` (or similar).

- [ ] **Step 4: Add a 100-iteration stress regression test**

Append a new test to `bash_test.zig` (right after the tightened single-call test). The test:
1. Records `fd_count_before = countOpenFds()`.
2. Loops 100 times, calling `execute_bash` with `command = "echo hello"`, `cwd = "/tmp"`, `mandatory_timeout = 5`.
3. Calls `countOpenFds()` again.
4. Asserts `fd_count_after - fd_count_before <= 0` (zero FD growth over 100 calls).

This MUST FAIL on current `main` (expected delta: 200).

Use the existing `countOpenFds` helper verbatim — DO NOT write a new helper. The test name: `bash_tool: 100 sequential calls do not grow the open-fd count`.

- [ ] **Step 5: Run the new stress test to confirm it fails**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | grep -E "(bash_tool.*100 sequential|fail|expected.*0|test.*FD leak)"
```

Expected output: the new stress test fails with `expected 0, found 200` (or similar — 100 calls × 2 leaked FDs).

- [ ] **Step 6: Commit the failing tests**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/modules/agent/tools/bash_test.zig
git commit -m "test(bash): tighten FD-leak tolerance to 0 and add 100-iter stress regression"
```

---

### Task 2: Fix the pipe leak in `execute_bash`'s foreground path

**Files:**
- Modify: `src/modules/agent/tools/bash.zig:628-697`

- [ ] **Step 1: Read the current `child_term = blk: { ... }` block end-to-end**

Read `src/modules/agent/tools/bash.zig:628-697` to internalize the exact shape.

The block has TWO switch statements (one per loop iteration's exit condition). Each switch has 4 outcomes. The `.reaped` and `.no_child` outcomes break without closing pipes. The `.grace_period_expired` and `.unexpected_error` outcomes close pipes inline.

- [ ] **Step 2: Remove the redundant inline pipe-close lines from the `.grace_period_expired`/`.unexpected_error` arms**

In BOTH switch statements (the EOF-driven one at lines 642–651 and the timeout-driven one at lines 668–676), remove these 2 lines from the `.grace_period_expired, .unexpected_error =>` arm:

```zig
if (child.stdout) |stdout_pipe| stdout_pipe.close(io);
if (child.stderr) |stderr_pipe| stderr_pipe.close(io);
```

The arm should now ONLY build the synthetic `Term` (`.signal = .KILL` on POSIX, `.unknown = 1` on Windows) and break.

- [ ] **Step 3: Add a single post-loop pipe-close block BEFORE `stdout_thread.join()`**

Insert a new block immediately after the closing `};` of `child_term = blk: { ... };` and BEFORE the `stdout_thread.join();` line:

```zig
// CRITICAL: close the parent-side pipe FDs after waitPidBounded returns.
// waitPidBounded uses raw libc waitpid which does NOT call
// childCleanupPosix (that only runs from child.wait(io)). Without
// this close, every successful bash tool call leaks 2 FDs (the
// parent's read ends of stdout + stderr pipes). The reader threads
// either saw EOF (happy path) or will see EBADF (D-state path) —
// either way they exit cleanly after we close. std.Io.File has no
// destructor, so we MUST close the FDs explicitly or they leak
// until process exit.
if (child.stdout) |stdout_pipe| stdout_pipe.close(io);
if (child.stderr) |stderr_pipe| stderr_pipe.close(io);
```

The line number to insert at: immediately AFTER the `};` closing the `child_term = blk: { ... }` block (currently around line 690) and BEFORE the comment line `// Join the reader threads...` (currently around line 692).

- [ ] **Step 4: Run the regression tests to confirm the fix works**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | grep -E "(bash_tool.*FD leak|bash_tool.*100 sequential|test success|fail|Build Summary)"
```

Expected output:
- `bash_tool: no FD leak after single call` — PASS (was failing before fix)
- `bash_tool: no FD leak after timeout-forced kill` — PASS (was failing before fix)
- `bash_tool: 100 sequential calls do not grow the open-fd count` — PASS (new test, was failing)

- [ ] **Step 5: Run the full test suite to confirm no regressions**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -3
```

Expected output: `Build Summary: 3/3 steps succeeded; 1836/1842 tests passed (6 skipped)` — 1833/1839 baseline + 3 new test variants (tightened tolerance on 2 existing + 1 new stress test).

- [ ] **Step 6: Run the install step (catches lazy-analysis errors `zig build test` misses)**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build install:linux:system 2>&1 | tail -3
```

Expected output: clean build (the `cp` to `/usr/local/bin/nalar` fails harmlessly with permission — that's OK).

- [ ] **Step 7: Commit the fix**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/modules/agent/tools/bash.zig
git commit -m "fix(bash): close parent-side stdout/stderr pipes after waitPidBounded

The bash tool's foreground path uses waitPidBounded (raw libc waitpid)
instead of child.wait(io) to avoid hanging on D-state descendants. But
waitpid does NOT trigger childCleanupPosix, so the parent's pipe FDs
were never closed.

Fix: add explicit pipe close AFTER the wait loop, BEFORE the reader
threads join. The reader threads either saw EOF (happy path) or will
see EBADF (D-state path) and exit cleanly.

Removes the redundant per-arm pipe-close lines from the
.grace_period_expired/.unexpected_error switch arms.

Empirical: 555 leaked pipe FDs in a 70-minute session (PID 2134141)
at ~2 FDs per bash call. After fix: zero growth over 100 calls."
```

---

### Task 3: Update existing memory to reflect the new root cause

**Files:**
- Modify: `~/.config/nalar/memories/nalar-backend-architecture.md` (global memory) — replace the bash.zig/HttpClient paragraph with the new finding.

**NOTE:** This is a global memory update (not local) because the FD-leak class is project-wide and the bash.zig root cause is specific enough that future agents on this codebase need to know it.

- [ ] **Step 1: Read the current `Source C` section in `nalar-backend-architecture.md`**

Find the section starting with `### Source C — bash.zig subprocess pipe leak in timeout/error paths`. Read lines around it.

- [ ] **Step 2: Update the section to reflect that the SUCCESS path is the actual leak site, not the timeout path**

Edit the section to:
1. Retitle to: `### Source C — bash.zig foreground path leaks 2 FDs per successful call (NOT just timeout)`.
2. Add the empirical evidence (555 leaked pipes in 70 minutes, ~2 FDs/call).
3. Update the "Fix:" section to describe the new post-loop pipe-close fix.
4. Update the "When this bites:" section to mention that EVEN SUCCESSFUL bash calls leak — this is the dominant case.
5. Add the new diagnostic recipe snippet that I used to find this leak (`ls -la /proc/$PID/fd | awk '{print $NF}' | grep '^pipe:'`).

- [ ] **Step 3: Commit the memory update**

```bash
cd ~/.config/nalar
git add memories/nalar-backend-architecture.md
git commit -m "memory: bash.zig foreground leaks 2 FDs per call (success path, not just timeout)"
```

**Note:** Only commit if `~/.config/nalar` is a git repo. Otherwise just write the file.

---

### Task 4: End-to-end verification with a stress test on port 8080

**Files:**
- No file changes. This is a manual verification step.

- [ ] **Step 1: Start a fresh nalar on port 8080**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
nohup ./zig-out/bin/nalar --port 8080 > /tmp/nalar-8080-verify.log 2>&1 &
sleep 3
PID=$(pgrep -f "nalar --port 8080" | head -1)
echo "Nalar PID: $PID"
echo "Initial FD count: $(ls /proc/$PID/fd | wc -l)"
```

Expected: FD count is small (~10-20) immediately after start.

- [ ] **Step 2: Fire 50 bash tool calls via the HTTP API**

Use the bash tool's HTTP endpoint. The exact API path is `POST /api/tools/bash` (verify by reading `src/ai_workflow/tui/http_handlers/bash.zig` or the relevant router config). The body shape:

```json
{
  "command": "echo hello",
  "mandatory_timeout": 5
}
```

Use a bash loop to call it 50 times in sequence:

```bash
for i in $(seq 1 50); do
  curl -sS -X POST http://127.0.0.1:8080/api/tools/bash \
    -H "Content-Type: application/json" \
    -d '{"command":"echo hello","mandatory_timeout":5}' > /dev/null
done
```

If the endpoint is not directly exposed (you need a session_id), use the SSE/chat endpoint instead. The simplest verification is via the Zig test binary which already has the right plumbing.

- [ ] **Step 3: Verify FD count is stable**

```bash
PID=$(pgrep -f "nalar --port 8080" | head -1)
echo "After 50 bash calls, FD count: $(ls /proc/$PID/fd | wc -l)"
echo "Pipe FDs: $(ls -la /proc/$PID/fd | awk '{print $NF}' | grep -c '^pipe:')"
```

Expected: FD count and pipe FDs stay at baseline (no growth). If pipe FDs grew by ~100, the fix is incomplete.

- [ ] **Step 4: Stop the test nalar**

```bash
kill $(pgrep -f "nalar --port 8080" | head -1)
```

**DO NOT kill the nalar on port 8081** (the user's running session).

- [ ] **Step 5: Clean up the test log**

```bash
rm /tmp/nalar-8080-verify.log
```

---

### Task 5: Move kanban card to "done" and write a short summary

**Files:**
- No file changes. Project workflow step.

- [ ] **Step 1: Run a final verification**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -3
timeout 180 zig build install:linux:system 2>&1 | tail -3
rm -rf zig-out/bin
timeout 360 zig build 2>&1 | tail -3
```

Expected: all three pass clean. Per `verification-before-completion` skill, NEVER claim success without fresh evidence.

- [ ] **Step 2: Open a PR (if not auto-opened)**

If the project auto-opens PRs on push, skip this step. Otherwise:

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git push -u origin worktree/<branch-name>
gh pr create --title "fix(bash): close parent pipe FDs after waitPidBounded" \
  --body "Fixes the 2-FD-per-call leak in execute_bash's foreground path. After ~70 minutes of agent activity, the nalar process accumulates ~280 orphaned pipe FDs. Root cause: waitPidBounded uses raw libc waitpid which does NOT trigger childCleanupPosix. Fix: add explicit pipe close after the wait loop, mirroring the errdefer pattern already used for the error path. Verified with 100-iteration stress test."
```

- [ ] **Step 3: Move the kanban card to "done"**

Use the kanban_move_task tool with `target_column_id = col_3c48fb9ad67f0000`.

---

## Pitfalls

1. **Do NOT use `child.wait(io)` as the fix**. The author of `bash.zig` explicitly avoided it because blocking `waitpid` hangs on D-state descendants. The fix uses raw libc `waitpid` + manual pipe close, NOT `child.wait(io)`. Touching this design would re-introduce the original hang.

2. **Do NOT close pipes BEFORE the reader threads have flushed their data**. The fix closes pipes AFTER `waitPidBounded` returns (after both EOF flags are set OR after the grace period expires) — which is the SAME point at which the reader threads are ready to be joined. Closing earlier risks losing buffered data.

3. **Do NOT use `defer` for the pipe close**. The fix is INSIDE the `blk:` loop's exit path. A `defer` at function scope would fire on EVERY exit (including the `errdefer` block at line 585, which already does its own close). Putting it AFTER the blk loop is the right scope.

4. **The `countOpenFds()` helper itself leaks FDs on every call** (because it calls `execute_bash`). This is now harmless because `execute_bash` doesn't leak anymore — but if a future refactor reintroduces a per-call leak, the helper's behavior would mask it. The 100-iter stress test guards against this.

5. **The 6-FD-per-burst signature** (visible in the FD creation timestamps) is misleading. It suggested stdin_data bash calls were the culprit. The actual leak is 2 FDs/call REGARDLESS of stdin_data — when stdin_data is provided, the parent explicitly closes its write end at line 454, so stdin doesn't leak.

6. **`Child.stdout`/`child.stderr` may be null** on some spawn failure paths (the `.close` value for stdin doesn't apply to stdout/stderr here, but defensive coding matters). The fix uses `if (child.stdout) |stdout_pipe| ...` — matches the existing errdefer pattern.

---

## Verification

End-to-end success criteria (ALL must be true):

1. `timeout 180 zig build test --summary all` reports the same total test count as baseline (1833/1839 → 1836/1842 with 3 new tests; the 3 new tests pass).
2. `timeout 180 zig build install:linux:system` builds clean.
3. `rm -rf zig-out/bin && timeout 360 zig build` builds clean.
4. Live nalar (PID 2134141, port 8081) FD count is stable — does NOT grow at >2 FDs per minute after the fix is deployed (note: this requires restarting the user's nalar process to pick up the new binary).
5. The 100-iteration stress test passes (`bash_tool: 100 sequential calls do not grow the open-fd count`).
6. The memory file `~/.config/nalar/memories/nalar-backend-architecture.md` documents the new root cause (success path, not just timeout path).

The user can verify #4 by running:

```bash
PID=$(pgrep -f "nalar --port 8081" | head -1)
for i in $(seq 1 6); do
  sleep 10
  echo "[+$(($i * 10))s] FDs: $(ls /proc/$PID/fd | wc -l)"
done
```

Expected: FD count is stable (no growth) after restarting nalar with the new binary.