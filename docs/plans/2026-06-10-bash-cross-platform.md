# bash.zig Cross-Platform Support (Linux / macOS / Windows) — `bash`-everywhere

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `src/modules/agent/tools/bash.zig` compile and run on **Linux**, **macOS**, and **Windows** with `bash` as the shell on every platform. No regressions on Linux.

**Architecture:** Replace the `std.posix.poll`-based foreground I/O loop with a `std.Thread`-based reader (one thread per stream). Keep `bash` as the shell everywhere — no `cmd.exe` fallback. Windows users get bash via Git for Windows, WSL, or any other bash distribution on PATH. This eliminates all shell-quoting, temp-path, and self-kill-pattern branches; the only cross-platform code is the I/O plumbing.

**Tech Stack:** Zig 0.16, `std.process.spawn`, `std.Io.File.readStreaming`, `std.Thread`, `std.atomic.Value(bool)`. `std.posix` → removed.

---

## Background — what's broken today

- **Compile-blocker on Windows** (`src/modules/agent/tools/bash.zig`):
  - Line 2: `const posix = std.posix;` — `std.posix` is unavailable on Windows targets.
  - Line 241: `posix.pollfd` — POSIX-only.
  - Lines 250, 295, 343, 391: `posix.POLL.IN/HUP/ERR` — POSIX-only.
  - Line 283: `posix.poll(...)` — POSIX-only; no Windows equivalent for anonymous pipes.
  - Line 207: `.pgid = 0` — POSIX-only concept. Remove.
- **No other portability issues.** `std.process.spawn`, `child.kill`, `child.wait`, `child.stdin.close(io)`, `std.Io.File.readStreaming`, `std.Io.Timestamp.now` are all cross-platform (verified in `/usr/lib/zig/std/process.zig:260,442,496` and `process/Child.zig:118,134`).
- **`bash_selfkill.zig` is fine as-is.** All its patterns (`kill`, `killall`, `pkill`, `$$`, `$!`, `$PPID`, `nohup`) are bash syntax, which is the only shell we support. No Windows-branch needed.
- **`/tmp` works on every platform** because the child is always bash: Git Bash maps `/tmp` to the Windows temp dir, WSL has a real `/tmp`, Linux/macOS have a real `/tmp`.

---

## Design Decisions (locked in)

1. **Shell** → `bash` everywhere. Single literal `&.{ "bash", "-c", command }`. `std.process.spawn` does the PATH lookup.
2. **Foreground I/O** → two `std.Thread`s, one per stream. Each thread loops `readStreaming` and appends to a mutex-protected `ArrayList(u8)`. Main thread monitors a deadline; on timeout calls `child.kill(io)`. Completion = both streams EOF + `child.wait` returns.
3. **`.pgid = 0` removed** from the spawn — default `null` is fine. Killing the immediate child is the right semantics for a tool.
4. **Background log path** → keep `/tmp/bg_{d}.log` as a literal. Bash on each platform resolves it correctly.
5. **Selfkill module** → unchanged. No Windows patterns, no POSIX/Windows split.

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `src/modules/agent/tools/bash.zig` | **Modify** | Cross-platform foreground I/O loop; one-line tool description update |
| `src/modules/agent/tools/bash_test.zig` | **Create** | Cross-platform tests |
| `src/modules/agent/test_runner.zig` | **Modify** | Register `bash_test.zig` |

No new module files. No changes to `bash_selfkill.zig`. No changes to `build.zig`.

---

## Chunk 1: Make `bash.zig` cross-platform

### Task 1.1: Add cross-platform tests and verify the baseline

**Files:**
- Create: `src/modules/agent/tools/bash_test.zig`
- Modify: `src/modules/agent/test_runner.zig` (register the new test)

- [ ] **Step 1.1.1: Create `bash_test.zig` with a baseline Linux test**

```zig
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const bash = @import("bash.zig");

test "bash_tool: foreground echo command runs on host OS" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const result = try bash.execute_bash(allocator, io, .{
        .command = "echo hello-cross-platform",
        .cwd = if (builtin.os.tag == .linux) "/" else "/tmp",
        .max_output = 1024,
        .max_lines = 10,
        .timeout = 5,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try testing.expect(result.exit_code == 0);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "hello-cross-platform") != null);
}

test "bash_tool: large output is truncated by line count" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const result = try bash.execute_bash(allocator, io, .{
        .command = "seq 1 1000",
        .cwd = "/tmp",
        .max_output = 1024 * 1024,
        .max_lines = 5,
        .timeout = 5,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try testing.expect(result.exit_code == 0);
    try testing.expect(result.truncated == true);
    try testing.expect(result.stdout_lines >= 5);
}

test "bash_tool: timeout fires on long-running command" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const result = try bash.execute_bash(allocator, io, .{
        .command = "sleep 5",
        .cwd = "/tmp",
        .timeout = 1,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try testing.expect(result.timeout == true);
    try testing.expect(result.exit_code != 0); // killed by signal
}
```

- [ ] **Step 1.1.2: Register the test in `test_runner.zig`**

In `src/modules/agent/test_runner.zig`, add this line after line 25 (the `cloak_browser_test.zig` import) and before the closing `}`:

```zig
    // Bash tool cross-platform tests
    _ = @import("tools/bash_test.zig");
```

- [ ] **Step 1.1.3: Run the new tests to verify they pass on the current Linux-only implementation**

Run: `timeout 120 zig build test:agent 2>&1 | tail -n 30`
Expected: all three new tests pass. The current `bash.zig` (with `posix.poll`) compiles and works on Linux; we are only adding test coverage here.

- [ ] **Step 1.1.4: Commit**

```bash
git add src/modules/agent/tools/bash_test.zig src/modules/agent/test_runner.zig
git commit -m "test(bash): add cross-platform test coverage (baseline)"
```

---

### Task 1.2: Replace `posix.poll` with thread-based reader

**Files:**
- Modify: `src/modules/agent/tools/bash.zig` (lines 2, 200-403)

- [ ] **Step 1.2.1: Remove `const posix = std.posix;` (line 2) and `.pgid = 0` (line 207)**

Two surgical edits:
- Delete line 2 entirely.
- In the foreground `std.process.spawn` call (line 207), remove the `, .pgid = 0` field. The `.argv` line becomes `&.{ "bash", "-c", command }` (unchanged literal — we keep bash everywhere).

- [ ] **Step 1.2.2: Refactor the foreground read loop to use `std.Thread`**

Replace the entire section from `// --- Foreground mode ---` (line 202) through the end of the `while (true) { ... }` loop (line 399) with the thread-based implementation below. The data structures (`stdout_data`, `stderr_data`, line counters, truncation flags) are preserved; only the multiplexing mechanism changes.

Write this exactly — do not improvise:

```zig
    // --- Foreground mode ---
    const max_output = input.max_output orelse 20 * 1024;
    const max_lines = input.max_lines orelse 1000;
    const timeout_sec = input.timeout orelse 30;

    // .pgid removed: default null. child.kill kills the immediate child, which
    // is the correct behavior for a tool. Subprocesses are reparented on exit.
    var child = try std.process.spawn(io, .{
        .argv = &.{ "bash", "-c", command },
        .cwd = if (input.cwd) |cwd| .{ .path = cwd } else .inherit,
        .stdin = if (input.stdin_data != null) .pipe else .close,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    if (input.stdin_data) |data| {
        if (child.stdin) |stdin| {
            var write_buf: [1024]u8 = undefined;
            var stdin_writer = std.Io.File.writer(stdin, io, &write_buf);
            try stdin_writer.interface.writeAll(data);
            stdin.close(io);
            child.stdin = null;
        }
    }

    const timeout_ns = @as(u64, timeout_sec) * std.time.ns_per_s;
    const start_time = std.Io.Timestamp.now(io, .real).nanoseconds;

    var stdout_data: std.ArrayList(u8) = .empty;
    var stderr_data: std.ArrayList(u8) = .empty;
    defer {
        stdout_data.deinit(allocator);
        stderr_data.deinit(allocator);
    }

    var stdout_line_count: usize = 0;
    var stderr_line_count: usize = 0;
    var stdout_truncated = false;
    var stderr_truncated = false;
    var stdout_eof = std.atomic.Value(bool).init(false);
    var stderr_eof = std.atomic.Value(bool).init(false);
    var stdout_mutex: std.Thread.Mutex = .{};
    var stderr_mutex: std.Thread.Mutex = .{};

    const ReadContext = struct {
        stream: std.Io.File,
        io: std.Io,
        buf: *[4096]u8,
        data: *std.ArrayList(u8),
        line_count: *usize,
        truncated: *bool,
        max_output: usize,
        max_lines: usize,
        eof_flag: *std.atomic.Value(bool),
        mutex: *std.Thread.Mutex,
        allocator: std.mem.Allocator,
    };

    const readLoopFn = struct {
        fn run(ctx: ReadContext) void {
            defer ctx.eof_flag.store(true, .release);
            while (true) {
                const n = std.Io.File.readStreaming(ctx.stream, ctx.io, &.{ctx.buf}) catch return;
                if (n == 0) return;
                for (ctx.buf[0..n]) |byte| {
                    if (byte == '\n') ctx.line_count.* += 1;
                }
                if (!ctx.truncated.*) {
                    ctx.mutex.lock();
                    defer ctx.mutex.unlock();
                    ctx.data.appendSlice(ctx.allocator, ctx.buf[0..n]) catch return;
                    if (ctx.data.items.len >= ctx.max_output or ctx.line_count.* >= ctx.max_lines) {
                        ctx.truncated.* = true;
                        var trim_pos: usize = ctx.data.items.len;
                        if (ctx.line_count.* >= ctx.max_lines) {
                            var count: usize = 0;
                            for (ctx.data.items, 0..) |b, i| {
                                if (b == '\n') {
                                    count += 1;
                                    if (count == ctx.max_lines) {
                                        trim_pos = i + 1;
                                        break;
                                    }
                                }
                            }
                        } else if (ctx.data.items.len > ctx.max_output) {
                            trim_pos = ctx.max_output;
                        }
                        if (ctx.data.items.len > trim_pos) {
                            ctx.data.shrinkAndFree(ctx.allocator, trim_pos);
                        }
                    }
                }
            }
        }
    }.run;

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;

    const stdout_ctx = ReadContext{
        .stream = child.stdout.?,
        .io = io,
        .buf = &stdout_buf,
        .data = &stdout_data,
        .line_count = &stdout_line_count,
        .truncated = &stdout_truncated,
        .max_output = max_output,
        .max_lines = max_lines,
        .eof_flag = &stdout_eof,
        .mutex = &stdout_mutex,
        .allocator = allocator,
    };
    const stderr_ctx = ReadContext{
        .stream = child.stderr.?,
        .io = io,
        .buf = &stderr_buf,
        .data = &stderr_data,
        .line_count = &stderr_line_count,
        .truncated = &stderr_truncated,
        .max_output = max_output,
        .max_lines = max_lines,
        .eof_flag = &stderr_eof,
        .mutex = &stderr_mutex,
        .allocator = allocator,
    };

    const stdout_thread = try std.Thread.spawn(.{}, readLoopFn, .{stdout_ctx});
    const stderr_thread = try std.Thread.spawn(.{}, readLoopFn, .{stderr_ctx});

    var timeout_hit = false;
    var child_term: ?std.process.Child.Term = null;

    while (true) {
        const elapsed = std.Io.Timestamp.now(io, .real).nanoseconds - start_time;
        if (elapsed > timeout_ns) {
            timeout_hit = true;
            _ = child.kill(io);
            // Do not call child.wait() here; kill() invalidates child.id.
            // The wait happens after the threads join below.
            child_term = .{ .signal = .KILL };
            break;
        }
        if (stdout_eof.load(.acquire) and stderr_eof.load(.acquire)) {
            child_term = child.wait(io) catch .{ .unknown = 1 };
            break;
        }
        std.time.sleep(10 * std.time.ns_per_ms);
    }

    stdout_thread.join();
    stderr_thread.join();
    if (child_term == null) {
        child_term = child.wait(io) catch .{ .unknown = 1 };
    }
```

- [ ] **Step 1.2.3: Run the bash tests on Linux**

Run: `timeout 120 zig build test:agent 2>&1 | tail -n 30`
Expected: all three bash tests pass. No regressions in the agent test suite.

- [ ] **Step 1.2.4: Verify cross-compile to Windows succeeds**

Run: `timeout 120 zig build install:windows 2>&1 | tail -n 20`
Expected: build succeeds. The `zig-out/bin/nalarcore-windows-x86_64.exe` artifact is produced. No `std.posix` references remain.

- [ ] **Step 1.2.5: Verify cross-compile to macOS succeeds (x86_64 and aarch64)**

Run:
```bash
timeout 120 zig build install:macos 2>&1 | tail -n 20
timeout 120 zig build install:macos-arm 2>&1 | tail -n 20
```
Expected: both builds succeed.

- [ ] **Step 1.2.6: Verify no `std.posix` references remain in `bash.zig`**

Run: `timeout 5 rg -n "std\.posix|posix\." src/modules/agent/tools/bash.zig`
Expected: zero matches. (Manual visual check of the file is also fine.)

- [ ] **Step 1.2.7: Commit**

```bash
git add src/modules/agent/tools/bash.zig
git commit -m "feat(bash): thread-based I/O loop (cross-platform, removes std.posix)"
```

---

### Task 1.3: Update the tool description with bash-on-Windows note

**Files:**
- Modify: `src/modules/agent/tools/bash.zig:504-527` (the `bash_tool` const literal's `description` field)

- [ ] **Step 1.3.1: Add a `## Platform Notes` block to the tool description**

Find the `description` field in the `bash_tool` literal (starts around line 508). After the existing `\\## Safety` block (ends with `\\Never assume the working directory — always set cwd explicitly.`), add the following line:

```zig
        \\
        \\## Platform Notes
        \\The shell is `bash` on every platform. On Windows you must have
        \\`bash.exe` on PATH. The most common sources are:
        \\- [Git for Windows](https://git-scm.com/download/win) — ships Git Bash.
        \\- [WSL](https://learn.microsoft.com/windows/wsl/install) — full Linux bash.
        \\- MSYS2, Cygwin, or a manual `bash` install.
        \\If bash is not on PATH, the tool will fail with `FileNotFound` at
        \\spawn time. macOS users: stock macOS ships bash 3.2; install
        \\bash 4+ via Homebrew (`brew install bash`) for modern syntax.
```

The full description becomes the existing text plus this new `## Platform Notes` block at the end.

- [ ] **Step 1.3.2: Run the agent test suite to confirm the prompt still renders**

Run: `timeout 120 zig build test:agent 2>&1 | tail -n 20`
Expected: all tests pass. The `bash_tool.description` is rendered into the agent's tool listing; the prompt tests in `src/modules/agent/prompts_test.zig` will catch any rendering regression.

- [ ] **Step 1.3.3: Commit**

```bash
git add src/modules/agent/tools/bash.zig
git commit -m "docs(bash): document bash-on-Windows requirement in tool description"
```

---

## Done Criteria

- [ ] `zig build test:agent` passes 100% on Linux. The three new bash tests (`foreground echo`, `large output truncated`, `timeout fires`) are in the green.
- [ ] `zig build install:windows` produces `zig-out/bin/nalarcore-windows-x86_64.exe` cleanly.
- [ ] `zig build install:macos` and `zig build install:macos-arm` produce macOS binaries cleanly.
- [ ] `rg "std\.posix" src/modules/agent/tools/bash.zig` returns zero matches.
- [ ] `bash.zig` contains a `## Platform Notes` block in its `description` field.
- [ ] `bash_selfkill.zig` is unchanged from its current state (no new files in that module).
- [ ] The new `bash_test.zig` is registered in `src/modules/agent/test_runner.zig`.

---

## Manual verification (per-platform smoke test)

Once the cross-compile artifacts exist, run on each target:

**Linux** (host):
```bash
echo '{"command":"echo linux-ok","cwd":"/","timeout":5}' \
  | ./zig-out/bin/nalarcore-linux-x86_64
```

**Windows** (on a Windows machine with bash on PATH):
```cmd
echo {"command":"echo windows-ok","cwd":"C:\\","timeout":5} ^
  | nalarcore-windows-x86_64.exe
```

**macOS** (on a Mac):
```bash
echo '{"command":"echo macos-ok","cwd":"/","timeout":5}' \
  | ./nalarcore-macos-aarch64
```

In all three cases the response should contain the expected echo output in the `stdout` field and `exit_code: 0`.

---

## Risks

1. **Windows machines without bash** will fail at runtime with `error.FileNotFound` from `std.process.spawn`. The error message is clear enough; the user installs Git Bash or enables WSL. This is the only failure mode the plan does not handle gracefully with a fallback.
2. **macOS bash 3.2** is missing bash 4+ features (associative arrays, `mapfile`, `**` globstar). Users on stock macOS get bash 3.2; modern bash syntax errors out. Documented in the tool description.
3. **Thread leak on timeout**: the reader threads exit when the child dies and the pipes close. Worst case 10ms of cleanup after a kill. Acceptable.

---

## What's NOT in this plan (kept out for scope)

- ❌ A `cmd.exe` fallback for Windows machines without bash (would re-add all the platform branching we just deleted).
- ❌ `sh` instead of `bash` on POSIX (would change behavior, no portability win on Windows).
- ❌ `JobObject` API for Windows process-tree killing (overkill; immediate-child kill is the right tool semantics).
- ❌ Refactoring `bash.zig` into smaller modules (file stays ~620 lines, consistent with the rest of `tools/`).
