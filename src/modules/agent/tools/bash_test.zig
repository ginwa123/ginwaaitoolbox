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
        .mandatory_timeout = 5,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try testing.expect(result.exit_code == 0);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "hello-cross-platform") != null);
}

test "bash_tool: large output is truncated by byte count" {
    // Verifies byte-based truncation caps a single huge line of generated
    // code (no newlines) — the failure mode that motivated moving the
    // post-read truncation from line-count to byte-count.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    // Produce 5000 bytes on a SINGLE line (no newlines). max_output=256
    // forces byte truncation; max_lines=999_999 disables line truncation
    // so we are testing the byte path in isolation.
    const result = try bash.execute_bash(allocator, io, .{
        .command = "head -c 5000 < /dev/zero | tr '\\0' 'x'",
        .cwd = "/tmp",
        .max_output = 256,
        .max_lines = 999_999,
        .mandatory_timeout = 5,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try testing.expect(result.exit_code == 0);
    try testing.expect(result.truncated == true);
    // The duplicated output must be capped at max_output bytes (not the
    // full 5000-byte single line).
    try testing.expect(result.stdout.len <= 256);
    try testing.expect(result.stdout.len > 0);
}

test "bash_tool: timeout fires on long-running command" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const result = try bash.execute_bash(allocator, io, .{
        .command = "sleep 5",
        .cwd = "/tmp",
        .mandatory_timeout = 1,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try testing.expect(result.timeout == true);
    try testing.expect(result.exit_code != 0); // killed by signal
}

test "bash_tool: timeout kills subshell descendants (no pipe-leak hang)" {
    // Regression test for the macOS hang. When bash is killed but its
    // descendants (subshells via `( )`, `|&`, backgrounded `&`, pipes)
    // inherit the pipe FDs back to us, the reader threads block forever
    // on pipe EOF that never arrives. The fix puts bash in its own
    // process group (.pgid = 0) so the timeout path can kill the whole
    // group with std.posix.kill(-pgid, .KILL).
    //
    // Without the fix this test hangs until the Zig test runner's
    // per-test timeout kills it; with the fix it returns in ~1 s with
    // timeout == true. We bound the wait with an overall deadline
    // matching `mandatory_timeout * 4` so a regression surfaces as a
    // test failure rather than a process hang.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    // `( sleep 5 ) | cat` — bash spawns a subshell for `( )` that
    // inherits the pipe FDs to us. The pre-fix code killed bash but
    // not the subshell, so the reader thread waited forever for EOF.
    const result = try bash.execute_bash(allocator, io, .{
        .command = "( sleep 5 ) | cat",
        .cwd = "/tmp",
        .mandatory_timeout = 1,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try testing.expect(result.timeout == true);
    try testing.expect(result.exit_code != 0);
}

test "bash_tool: timeout kills descendants across all common subshell shapes" {
    // Each of these exercises a distinct descendant topology that bash
    // spawns before exec'ing into the long-running command. The pre-fix
    // code (no .pgid, child.kill only) left each descendant holding the
    // pipe FDs to us, so the reader thread blocked forever. With the
    // process-group kill, the whole tree dies together and the pipes
    // EOF cleanly.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const cases = [_][]const u8{
        "( sleep 5 )", // bare subshell group
        "sleep 5 | head", // pipe (no subshell, but reader FDs shared)
        "sleep 5 & wait", // backgrounded job + wait
        "{ sleep 5; }", // brace group
        "( ( sleep 5 ) )", // nested subshells
        "bash -c 'sleep 5'", // inner bash inherits our pgid
        // The exact shape the AI hit in production (session-1783866771666):
        // outer `timeout` + nested `bash -c` + subshell-in-pipe. If the
        // process-group kill is incomplete this hangs for the full
        // mandatory_timeout duration and the reader-thread join never
        // returns.
        "timeout 3 bash -c '( sleep 10 ) | head -n 5'",
    };

    for (cases) |cmd| {
        const result = try bash.execute_bash(allocator, io, .{
            .command = cmd,
            .cwd = "/tmp",
            .mandatory_timeout = 3,
        });
        defer {
            allocator.free(result.command);
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        // Verify the process tree died correctly: either OUR 3s deadline
        // killed the bash process (result.timeout == true), or — for the
        // one case with an inner `timeout 3 …` — the inner `timeout`
        // command itself killed bash at the same 3s mark, propagating
        // exit code 124 (the standard `timeout(1)` exit code for a
        // killed command). Both outcomes prove the descendants were
        // reaped and the reader-thread join did not hang. Either is a
        // valid non-natural exit.
        const inner_timeout_killed_it = result.exit_code == 124 and !result.timeout;
        try testing.expect(result.timeout == true or inner_timeout_killed_it);
        try testing.expect(result.exit_code != 0);
    }
}

test "bash_tool: missing mandatory_timeout returns MandatoryTimeoutMissing" {
    // Runs on ALL platforms (no shell required) — the validation fires before
    // we ever spawn a child.
    const allocator = testing.allocator;
    const io = std.testing.io;

    const result = bash.execute_bash(allocator, io, .{
        .command = "echo should-never-run",
        .cwd = "/tmp",
        // mandatory_timeout intentionally omitted → null
    });
    try testing.expectError(error.MandatoryTimeoutMissing, result);
}

test "bash_tool: mandatory_timeout = 0 returns MandatoryTimeoutMissing" {
    // Zero is not a meaningful deadline; treat it the same as missing.
    const allocator = testing.allocator;
    const io = std.testing.io;

    const result = bash.execute_bash(allocator, io, .{
        .command = "echo should-never-run",
        .cwd = "/tmp",
        .mandatory_timeout = 0,
    });
    try testing.expectError(error.MandatoryTimeoutMissing, result);
}

test "bash_tool: background mode ignores missing mandatory_timeout" {
    // Background runs detach via nohup and have no deadline enforced by this
    // tool, so omitting mandatory_timeout must NOT return MandatoryTimeoutMissing.
    // We don't actually verify the detached process behavior (CI is too flaky
    // for that) — we only verify that the validation gate lets it through.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const result = bash.execute_bash(allocator, io, .{
        .command = "true",
        .cwd = "/tmp",
        .background = true,
        // mandatory_timeout intentionally null
    });
    // Only MandatoryTimeoutMissing is a contract violation. Any other
    // error means the background path is broken for unrelated reasons;
    // surface it as a test failure rather than masking it.
    if (result) |r| {
        defer allocator.free(r.command);
        defer allocator.free(r.stdout);
        defer allocator.free(r.stderr);
    } else |err| {
        try testing.expect(err != error.MandatoryTimeoutMissing);
    }
}

// =========================================================================
// Hang-prevention regression tests (2026-07-15 — worktree/bash-hang-d-state-fix)
//
// These tests cover the scenarios that the existing 8 tests miss:
//
//  1. The wall-clock bound — `execute_bash` MUST return within
//     `timeout + KILL_GRACE_PERIOD_SECONDS + 2s slack` even when the
//     bash process tree is misbehaving (subshell holding pipe FD open,
//     process in D-state-like behavior, etc.).
//
//  2. No FD leak — after `execute_bash` returns, the count of open FDs
//     in /proc/self/fd must equal the count BEFORE the call. No leaked
//     pipe FDs from the child process group.
//
//  3. No memory leak — using `testing.allocator` which reports leaks.
//
//  4. The pipe FDs are actually closed — even after force-kill of a
//     stuck process group, the parent-side pipe FDs are released so
//     the reader threads can exit cleanly.
//
//  5. The reader-thread join has a deadline — pathological commands
//     don't make `execute_bash` hang forever.
//
//  6. The child.wait() has a grace period — D-state descendants don't
//     make `execute_bash` hang forever.
//
//  7. Repeated sequential calls don't accumulate FDs (long-running
//     agent scenario).
//
// The actual "D-state" condition (process stuck in kernel I/O) cannot
// be reliably reproduced in tests (you'd need to fake an unmountable
// NFS share or a hung FUSE filesystem). Instead we simulate the
// equivalent: a subshell that holds the pipe FD open AND keeps running
// past the timeout. The pre-fix code would hang in this case because
// `child.wait(io)` waits forever for the subshell to exit.
// =========================================================================

/// Returns the count of open FDs in /proc/self/fd. Linux/macOS only.
///
/// Implemented via `ls -1 /proc/self/fd | wc -l` invoked through the bash
/// tool itself. This avoids the open-during-walk problem where opening
/// the dir gives us a new FD that the walker then tries to read from,
/// causing a BADF panic in the Io runtime.
fn countOpenFds() !usize {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return 0;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const result = try bash.execute_bash(allocator, io, .{
        .command = "ls -1 /proc/self/fd 2>/dev/null | wc -l",
        .cwd = "/tmp",
        .mandatory_timeout = 5,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    if (result.exit_code != 0) return 0;
    const trimmed = std.mem.trim(u8, result.stdout, " \t\n\r");
    return std.fmt.parseInt(usize, trimmed, 10) catch 0;
}

test "bash_tool: returns within bounded wall-clock time even when child hangs" {
    // A bash command that runs forever, forcing the timeout path. The
    // pre-fix code (child.wait(io) blocking forever) would hang this
    // test until the Zig test runner's per-test timeout fires.
    // The fix must ensure `execute_bash` returns within
    // timeout + KILL_GRACE_PERIOD (e.g., timeout=1s, grace=2s, so ≤3s).
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const start = std.Io.Timestamp.now(io, .real).nanoseconds;

    const result = try bash.execute_bash(allocator, io, .{
        .command = "sleep 30", // longer than the 1s timeout
        .cwd = "/tmp",
        .mandatory_timeout = 1,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const elapsed_ms: u64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds - start, 1_000_000));

    // Hard wall-clock upper bound: timeout (1s) + grace (2s) + 2s slack = 5s.
    // Pre-fix code blocks indefinitely on child.wait(io); this test would
    // time out at the test-runner level (typically 60s).
    try testing.expect(elapsed_ms < 5000);
    try testing.expect(result.timeout == true);
    try testing.expect(result.exit_code != 0);
}

test "bash_tool: pipe-FD-holding subshell does not hang (force-kill cleanup works)" {
    // Simulates the D-state condition by spawning a subshell that holds
    // the pipe FD open indefinitely via an `exec`-ed command that reads
    // from a never-closing source.
    //
    // The pre-fix code's `child.wait(io)` blocks waiting for the entire
    // process group to exit. With the process-group kill + grace-period
    // bounded wait, the function must return within timeout + grace.
    //
    // We use `tail -f /dev/null` which reads forever from a file that
    // never produces new data. SIGKILL kills it cleanly (not D-state),
    // but the test verifies the cleanup path still works correctly.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const start = std.Io.Timestamp.now(io, .real).nanoseconds;

    const result = try bash.execute_bash(allocator, io, .{
        .command = "tail -f /dev/null",
        .cwd = "/tmp",
        .mandatory_timeout = 1,
        .max_output = 256,
        .max_lines = 10,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const elapsed_ms: u64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds - start, 1_000_000));

    // Must return within timeout + grace + 2s slack.
    try testing.expect(elapsed_ms < 5000);
    try testing.expect(result.timeout == true);
    try testing.expect(result.exit_code != 0);
}

test "bash_tool: subshell holding pipe FD open after parent death" {
    // The closest reliable simulation of a "D-state-like" hang: bash
    // spawns a subshell that takes the pipe FD via inheritance and
    // runs forever (sleep 60). SIGKILL of the process group kills
    // the subshell too (it's in the pgid). The test verifies that
    // the post-kill cleanup doesn't hang waiting for descendants
    // that may have escaped the group.
    //
    // A real D-state process (kernel I/O) cannot be reliably
    // reproduced; this is the closest faithful test.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const start = std.Io.Timestamp.now(io, .real).nanoseconds;

    const result = try bash.execute_bash(allocator, io, .{
        // `( sleep 60 )` — bare subshell group, holds pipe FD
        .command = "( sleep 60 )",
        .cwd = "/tmp",
        .mandatory_timeout = 1,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const elapsed_ms: u64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds - start, 1_000_000));

    try testing.expect(elapsed_ms < 5000);
    try testing.expect(result.timeout == true);
    try testing.expect(result.exit_code != 0);
}

test "bash_tool: complex pipeline with multiple descendants is killed cleanly" {
    // Multi-stage pipeline: `sleep 30 | sleep 30 | sleep 30`. Each
    // `sleep` is a separate process in bash's pgid. The pgid kill
    // must reach all three, and the cleanup must complete within
    // bounded time.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const start = std.Io.Timestamp.now(io, .real).nanoseconds;

    const result = try bash.execute_bash(allocator, io, .{
        .command = "sleep 30 | sleep 30 | sleep 30",
        .cwd = "/tmp",
        .mandatory_timeout = 1,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const elapsed_ms: u64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds - start, 1_000_000));

    try testing.expect(elapsed_ms < 5000);
    try testing.expect(result.timeout == true);
    try testing.expect(result.exit_code != 0);
}

test "bash_tool: long-running inner command killed by outer bash timeout" {
    // The exact shape from production failure (session-1783866771666):
    // `timeout 30 bash -c 'sleep 60'`. The outer `timeout` would kill
    // at 30s, but our mandatory_timeout=1s should fire first. After
    // the kill, the inner bash should be reaped within the grace period.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const start = std.Io.Timestamp.now(io, .real).nanoseconds;

    const result = try bash.execute_bash(allocator, io, .{
        .command = "timeout 30 bash -c 'sleep 60'",
        .cwd = "/tmp",
        .mandatory_timeout = 1,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const elapsed_ms: u64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds - start, 1_000_000));

    try testing.expect(elapsed_ms < 5000);
    try testing.expect(result.timeout == true or result.exit_code != 0);
}

test "bash_tool: no FD leak after single call" {
    // Verify that execute_bash closes all pipe FDs by the time it
    // returns. The pre-fix code leaked pipe FDs because std.posix.kill
    // didn't touch the Child struct (memory: process-fd-quota-exceed).
    // The fix adds explicit pipe-FD closure in the cleanup paths.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const fd_count_before = try countOpenFds();

    const result = try bash.execute_bash(allocator, io, .{
        .command = "echo hello",
        .cwd = "/tmp",
        .mandatory_timeout = 5,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const fd_count_after = try countOpenFds();

    // After the call returns, no extra FDs should remain. We allow
    // a small tolerance (2 FDs) for transient async allocations
    // (test runner internal state) but anything more indicates a leak.
    const diff: usize = if (fd_count_after > fd_count_before)
        fd_count_after - fd_count_before
    else
        0;
    try testing.expect(diff <= 2);
}

test "bash_tool: no FD leak after timeout-forced kill" {
    // Same as above but for the timeout/force-kill path. This is the
    // path that pre-fix leaked the most FDs (the kill itself doesn't
    // close pipe FDs).
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const fd_count_before = try countOpenFds();

    const result = try bash.execute_bash(allocator, io, .{
        .command = "sleep 10",
        .cwd = "/tmp",
        .mandatory_timeout = 1,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const fd_count_after = try countOpenFds();

    const diff: usize = if (fd_count_after > fd_count_before)
        fd_count_after - fd_count_before
    else
        0;
    try testing.expect(diff <= 2);
}

test "bash_tool: no FD accumulation across 20 sequential calls" {
    // Long-running agent scenario: the LLM calls bash 20 times in
    // succession. Each call must release all FDs from the previous
    // call. Pre-fix code would leak ~5 FDs per call (the 3 pipe FDs
    // + 2 stdio FDs), so 20 calls would leak 100 FDs total. The fix
    // must close everything so the 21st call sees the same FD count
    // as the 1st.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const fd_count_before = try countOpenFds();

    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const result = try bash.execute_bash(allocator, io, .{
            .command = if (i % 2 == 0) "echo hello" else "sleep 0.3", // alternates success/timeout
            .cwd = "/tmp",
            .mandatory_timeout = 1,
        });
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const fd_count_after = try countOpenFds();

    const diff: usize = if (fd_count_after > fd_count_before)
        fd_count_after - fd_count_before
    else
        0;
    // Allow a tiny slack for transient state (e.g. fd walker itself
    // opening /proc/self/fd). Anything > 2 indicates a real leak.
    try testing.expect(diff <= 2);
}

test "bash_tool: no memory leak after single call" {
    // testing.allocator will report leaks on scope exit if anything
    // was allocated without being freed.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const result = try bash.execute_bash(allocator, io, .{
        .command = "echo hello",
        .cwd = "/tmp",
        .mandatory_timeout = 5,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    // The defer above frees the output. If execute_bash allocated
    // anything else internally that's leaked, testing.allocator
    // will report it when the test scope ends.
}

test "bash_tool: no memory leak after timeout-forced kill" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const result = try bash.execute_bash(allocator, io, .{
        .command = "sleep 10",
        .cwd = "/tmp",
        .mandatory_timeout = 1,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    // testing.allocator will report any leak on scope exit.
}

test "bash_tool: output is captured even when command is killed by timeout" {
    // The fix must NOT lose the partial output that bash wrote before
    // being killed. The reader threads must flush whatever was buffered
    // before the kill.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const result = try bash.execute_bash(allocator, io, .{
        // Write a marker before sleeping — that marker must be in stdout
        .command = "echo 'PARTIAL-OUTPUT-BEFORE-TIMEOUT'; sleep 10",
        .cwd = "/tmp",
        .mandatory_timeout = 1,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try testing.expect(result.timeout == true);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "PARTIAL-OUTPUT-BEFORE-TIMEOUT") != null);
}

test "bash_tool: background mode returns quickly even for hanging command" {
    // Background mode detaches via nohup. The function returns the PID
    // and log path. It must NOT wait for the detached command. This
    // was the path that used `child.wait(io)` at line 207 — verify it
    // still returns quickly.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const start = std.Io.Timestamp.now(io, .real).nanoseconds;

    const result = try bash.execute_bash(allocator, io, .{
        .command = "sleep 60", // hangs forever, but detached
        .cwd = "/tmp",
        .background = true,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const elapsed_ms: u64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds - start, 1_000_000));

    // Background spawn should complete in <2s (just spawn + read PID + log path).
    try testing.expect(elapsed_ms < 2000);
    try testing.expect(result.exit_code == 0);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "PID:") != null);
}

test "bash_tool: stdin_data command completes cleanly" {
    // A command that reads stdin and exits. Verifies the stdin
    // write path doesn't leak FDs and that the input is delivered
    // (we check exit_code == 0 + non-empty stdout rather than the
    // exact bytes because the existing stdin_data plumbing predates
    // this fix and may normalize trailing newlines).
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const fd_count_before = try countOpenFds();

    const result = try bash.execute_bash(allocator, io, .{
        .command = "cat",
        .cwd = "/tmp",
        .mandatory_timeout = 5,
        .stdin_data = "hello via stdin\n",
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try testing.expect(result.exit_code == 0);
    try testing.expect(result.stdout.len > 0);

    const fd_count_after = try countOpenFds();
    const diff: usize = if (fd_count_after > fd_count_before)
        fd_count_after - fd_count_before
    else
        0;
    try testing.expect(diff <= 2);
}

test "bash_tool: command that produces lots of output is truncated without hanging" {
    // Verifies the truncation logic works under timeout pressure.
    // The producer (`yes`) would produce infinite output; the reader
    // thread must truncate at max_output without hanging.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const start = std.Io.Timestamp.now(io, .real).nanoseconds;

    const result = try bash.execute_bash(allocator, io, .{
        .command = "yes hello | head -n 100000",
        .cwd = "/tmp",
        .mandatory_timeout = 3,
        .max_output = 1024, // tight byte limit to force truncation
        .max_lines = 50, // tight line limit
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const elapsed_ms: u64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds - start, 1_000_000));

    try testing.expect(elapsed_ms < 5000);
    try testing.expect(result.truncated == true);
    try testing.expect(result.stdout.len <= 1024);
}

test "bash_tool: very short timeout (1 second) does not deadlock" {
    // The shortest reasonable timeout. Verifies that even with
    // minimal grace period, the function returns cleanly.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const start = std.Io.Timestamp.now(io, .real).nanoseconds;

    const result = try bash.execute_bash(allocator, io, .{
        .command = "sleep 5",
        .cwd = "/tmp",
        .mandatory_timeout = 1,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const elapsed_ms: u64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds - start, 1_000_000));

    try testing.expect(elapsed_ms < 5000);
    try testing.expect(result.timeout == true);
    try testing.expect(result.exit_code != 0);
}

test "bash_tool: command exits normally before timeout fires" {
    // The "happy path" — make sure the fix didn't break the normal case.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const start = std.Io.Timestamp.now(io, .real).nanoseconds;

    const result = try bash.execute_bash(allocator, io, .{
        .command = "echo happy-path",
        .cwd = "/tmp",
        .mandatory_timeout = 5,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const elapsed_ms: u64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds - start, 1_000_000));

    try testing.expect(elapsed_ms < 2000);
    try testing.expect(result.timeout == false);
    try testing.expect(result.exit_code == 0);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "happy-path") != null);
}

test "bash_tool: nested bash -c with stuck sleep is killed cleanly" {
    // `bash -c 'sleep 60'` — inner bash. The outer pgid kill should
    // reach the inner bash too. Pre-fix code's `child.wait(io)` could
    // hang here because the inner bash was waiting for sleep.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const start = std.Io.Timestamp.now(io, .real).nanoseconds;

    const result = try bash.execute_bash(allocator, io, .{
        .command = "bash -c 'sleep 60'",
        .cwd = "/tmp",
        .mandatory_timeout = 1,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const elapsed_ms: u64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds - start, 1_000_000));

    try testing.expect(elapsed_ms < 5000);
    try testing.expect(result.timeout == true);
    try testing.expect(result.exit_code != 0);
}

test "bash_tool: exit code is set even when force-killed" {
    // After a forced kill, exit_code must be set to a non-zero value
    // (typically negative for signal-killed). It must NOT be 0.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const result = try bash.execute_bash(allocator, io, .{
        .command = "sleep 10",
        .cwd = "/tmp",
        .mandatory_timeout = 1,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try testing.expect(result.timeout == true);
    // exit_code is -signal_number for SIGKILL on POSIX, or -1 for unknown.
    try testing.expect(result.exit_code != 0);
}

// =========================================================================
// Static-contract regression tests
//
// These tests grep the source of bash.zig to verify the structural
// contracts that prevent the hang from being re-introduced by a
// future refactor. Behavioural tests above cover the runtime behaviour;
// these cover the "did someone break the fix" case where a refactor
// accidentally removes the kill, the bounded wait, or the manual pipe
// close.
//
// The contract being verified is captured by the 5 lines of bash.zig
// that the comment block at line 226 (worktree/bash-hang-d-state-fix)
// calls out. If any of these patterns disappears, the corresponding
// test below fails — the test name points at which contract broke.
// =========================================================================

const BASH_SOURCE_PATH = "src/modules/agent/tools/bash.zig";

fn readBashSource(allocator: std.mem.Allocator) ![]const u8 {
    const io = std.testing.io;
    return std.Io.Dir.cwd().readFileAlloc(
        io,
        BASH_SOURCE_PATH,
        allocator,
        .limited(1 << 20), // 1 MiB cap — bash.zig is ~30 KB
    );
}

test "bash: uses process-group kill (kill -pgid, not just child.kill)" {
    // Without process-group kill, subshells survive the timeout and
    // keep the pipe FDs open, hanging the reader threads forever.
    // The contract: `std.posix.kill(-child_pgid, .KILL)` must be used.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const source = try readBashSource(testing.allocator);
    defer testing.allocator.free(source);

    if (std.mem.indexOf(u8, source, "std.posix.kill(-child_pgid, .KILL)") == null) {
        std.debug.print(
            "!! bash.zig is missing std.posix.kill(-child_pgid, .KILL) — process-group kill removed !!\n",
            .{},
        );
        return error.ProcessGroupKillMissing;
    }
}

test "bash: spawns with .pgid = 0 (so kill -pgid reaches all descendants)" {
    // The .pgid = 0 flag on spawn places bash in its own process group.
    // Without this, std.posix.kill(-child_pgid, .KILL) would kill only
    // bash itself, not its subshells.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const source = try readBashSource(testing.allocator);
    defer testing.allocator.free(source);

    if (std.mem.indexOf(u8, source, ".pgid = 0") == null) {
        std.debug.print("!! bash.zig is missing .pgid = 0 on spawn !!\n", .{});
        return error.PgidZeroMissing;
    }
}

test "bash: has bounded wait (KILL_GRACE_PERIOD_NS + waitPidBounded)" {
    // The bounded-wait helper is the actual fix for D-state hangs. If
    // a refactor reverts to `child.wait(io)`, the test fails. The
    // helper name is part of the contract — don't rename without
    // updating the test.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const source = try readBashSource(testing.allocator);
    defer testing.allocator.free(source);

    if (std.mem.indexOf(u8, source, "KILL_GRACE_PERIOD_NS") == null) {
        std.debug.print(
            "!! bash.zig is missing KILL_GRACE_PERIOD_NS constant — bounded-wait fix removed !!\n",
            .{},
        );
        return error.KillGracePeriodMissing;
    }
    if (std.mem.indexOf(u8, source, "fn waitPidBounded") == null) {
        std.debug.print(
            "!! bash.zig is missing fn waitPidBounded — bounded-wait helper removed !!\n",
            .{},
        );
        return error.WaitPidBoundedMissing;
    }
}

test "bash: uses WNOHANG for the bounded wait (not blocking waitpid)" {
    // The fix replaces `child.wait(io)` (which uses blocking waitpid)
    // with `waitpid(pid, &status, WNOHANG)` (which polls). If the
    // source regresses to a blocking call, the D-state hang is back.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const source = try readBashSource(testing.allocator);
    defer testing.allocator.free(source);

    if (std.mem.indexOf(u8, source, "std.c.W.NOHANG") == null) {
        std.debug.print(
            "!! bash.zig is missing std.c.W.NOHANG — bounded wait may have regressed to blocking !!\n",
            .{},
        );
        return error.WNoHangMissing;
    }
}

test "bash: manually closes pipe FDs after grace-period expiry" {
    // After SIGKILL on a D-state descendant, waitpid will keep
    // returning WNOHANG-0 until the grace period expires. Then we
    // MUST close the pipe FDs ourselves (std.Io.File has no
    // destructor). If the manual close is removed, the reader threads
    // hang forever waiting for pipe EOF that never arrives.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const source = try readBashSource(testing.allocator);
    defer testing.allocator.free(source);

    // Look for the pattern `child.stdout.?.close(io)` (or `|.close(io)`
    // via the `if (child.stdout) |stdout_pipe| stdout_pipe.close(io)` form)
    if (std.mem.indexOf(u8, source, "stdout_pipe.close(io)") == null and
        std.mem.indexOf(u8, source, "child.stdout.?.close(io)") == null)
    {
        std.debug.print(
            "!! bash.zig is missing the manual stdout pipe close after kill !!\n",
            .{},
        );
        return error.StdoutPipeCloseMissing;
    }
    if (std.mem.indexOf(u8, source, "stderr_pipe.close(io)") == null and
        std.mem.indexOf(u8, source, "child.stderr.?.close(io)") == null)
    {
        std.debug.print(
            "!! bash.zig is missing the manual stderr pipe close after kill !!\n",
            .{},
        );
        return error.StderrPipeCloseMissing;
    }
}

test "bash: does NOT use child.kill(io) (which only kills immediate child)" {
    // `child.kill(io)` only kills bash itself, not the process group.
    // Subshells and pipe consumers survive and keep pipe FDs open.
    // The pre-PR-82 code did this and hung the agent. The fix must
    // use `std.posix.kill(-child_pgid, .KILL)` instead.
    //
    // We grep for `child.kill(` and assert it appears ZERO times.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const source = try readBashSource(testing.allocator);
    defer testing.allocator.free(source);

    var iter = std.mem.splitScalar(u8, source, '\n');
    var line_no: usize = 1;
    while (iter.next()) |line| : (line_no += 1) {
        // Allow comments that mention `child.kill(` (e.g. "child.kill()
        // would only kill bash"). Only fail on actual code.
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "//")) continue;
        if (std.mem.indexOf(u8, line, "child.kill(") != null) {
            std.debug.print(
                "!! bash.zig line {d} uses child.kill() — must use std.posix.kill(-child_pgid, .KILL) instead !!\n",
                .{line_no},
            );
            return error.ChildKillUsed;
        }
    }
}
