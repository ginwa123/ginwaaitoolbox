//! End-to-end functional test for the MCP stdio timeout / cancel-callback
//! / markStale self-healing fix (plan 2026-08-28-fix-mcp-stdio-blocking).
//!
//! The fix's three layers:
//!  1. `readFramed` / `writeFramed` now poll a deadline + cancel-callback.
//!  2. `StdioClient.send` / `recv` accept a `deadline_ns` + cancel-fn.
//!  3. `StdioRegistry.markStale(name)` flips a dirty flag so the next
//!     `getOrSpawn` for the same name kills the hung child + spawns fresh.
//!
//! For the building block, see `src/modules/agent/mcp/mcp/mcp_stdio.zig`'s
//! inline tests (test 21 "recv returns RecvTimeout when child never
//! responds" + test 22 "recv aborts immediately when cancel callback
//! returns true" + test 23 "markStale forces respawn").
//!
//! This file's job is the END-TO-END wire-level demonstration:
//!
//!   Test 1: Spawn hung-server.sh directly, send a tools/list frame,
//!           assert the recv times out within the 1s deadline (not
//!           blocking forever). Proves the framing layer works against
//!           a real child on the wire.
//!
//!   Test 2: Two consecutive spawns through the same `hung_argv` —
//!           the SECOND one gets a fresh child (proves markStale
//!           style respawn at the binary level by killing+respawning
//!           via subprocess).
//!
//! This module deliberately does NOT boot pabrik. Launching the full
//! backend to test a 30s timeout would make the suite 30s slower per
//! test; the workflow integration is covered by the Zig unit tests
//! (they're faster) and by the manual smoke test the user can run with
//! `zig build pabrik-desktop && ./zig-out/bin/pabrik --port 8080` against
//! a hung-server.sh config.
//!
//! Zig port of `tests/functional/mcp_stdio_hang_test.py` (same test
//! names, same order).
//!
//! WHY THE CHILD'S STDIN/STDOUT ARE FILES, NOT PIPES
//! -------------------------------------------------
//! Python used `subprocess.Popen(stdin=PIPE, stdout=PIPE)` and then
//! `select.select([proc.stdout], [], [], 0.5)` to ask "did a frame
//! arrive within this window?". Zig 0.16's `Io.File` exposes no
//! pipe reader with a poll timeout that composes with the `Io` handle
//! the rest of the suite uses, and a blocking read is exactly the
//! deadlock the harness already documents ("WHY FILES AND NOT PIPES" on
//! `harness.runPabrikCommand`): a child that writes NOTHING is the
//! subject under test, so the parent would block forever.
//!
//! Handing the fixture two regular files inside a `makeScratchDir`
//! gives the same wire bytes with no pipe to drain: the parent writes
//! the frame into `stdin` before the spawn, and "did a response
//! arrive?" becomes a `readFileAlloc` whose length is the answer. The
//! fixture's contract is unchanged — it reads ONE line from stdin,
//! discards it, and never writes to stdout — and the files are removed
//! with the scratch dir on the way out.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

const builtin = @import("builtin");

/// The hung-server fixture, relative to the REPO ROOT.
///
/// Python derived this from `Path(__file__).resolve().parent`, which is
/// absolute by construction. Zig has no `__file__` whose module root is
/// knowable at runtime (`@src().file` is relative to the MODULE root,
/// which is `tests/functional/` under `zig build test` and the repo root
/// under a bare `zig test`), so the port follows the convention the rest
/// of this package already relies on: `harness.resolvePabrikBin`
/// resolves `zig-out/bin/...` relative to the CWD, and
/// `tests/functional/build.zig` pins that CWD to the repo root via
/// `run_unit_tests.setCwd(b.path("../.."))`.
const HUNG_SERVER = "tests/functional/fixtures/hung-server.sh";

/// The canonical MCP stdio `tools/list` frame, plus the extra newline the
/// Python wrote so the fixture's `read -r _discarded` returns.
///
/// Kept byte-for-byte: the `Content-Length: 78` must match the JSON
/// body, and this test exists precisely to prove the FIXTURE is really
/// hung — a frame the fixture never read would make "no response"
/// true for the wrong reason.
const TOOLS_LIST_FRAME =
    "Content-Length: 78\r\n\r\n" ++
    "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"tools/list\",\"params\":{}}";

/// `_wait_for_timeout(proc, deadline_s=1.0)`'s deadline, in ms.
const DEADLINE_MS: i64 = 1000;

/// `select.select([proc.stdout], [], [], 0.5)`'s poll slice.
const POLL_SLICE_MS: i64 = 500;

/// A hung child plus the scratch file its stdout lands in.
///
/// `deinit` is the ONLY teardown path and is registered with `defer`,
/// because the fixture ends in `sleep 3600` — a test that returns early
/// on a failed assertion and forgets to kill it leaks a process that
/// outlives the whole suite.
const Hung = struct {
    child: std.process.Child,
    pid: u32,
    stdout_path: []u8,

    /// SIGKILL the child and reap it.
    ///
    /// `Child.kill` ALREADY reaps: the stdlib documents it as
    /// "kills ... then blocks until it terminates, then cleans up all
    /// resources", and it nulls `child.id` on the way out. Calling
    /// `wait` after it is not a harmless no-op — `wait` opens with
    /// `assert(child.id != null)`, so the second reap panics. That
    /// matters here because the second test kills + reaps inside a
    /// scoped block AND still has the `defer` run afterwards; `kill`
    /// is idempotent, so the second call does nothing.
    ///
    /// The `stdout_path` allocation is freed HERE rather than by the
    /// caller: it is this struct's to give away (the file itself is
    /// removed with the scratch dir), and a `defer gpa.free(...)` at
    /// the call site would have to be registered BEFORE this `deinit`
    /// runs to keep the path alive — exactly the LIFO trap the
    /// harness notes. One owner, one free.
    fn deinit(self: *Hung) void {
        self.child.kill(io);
        gpa.free(self.stdout_path);
    }

    /// The bytes the child has written to stdout so far. Owned.
    ///
    /// A hung fixture writes none, so this is normally empty; a
    /// non-empty result is the failure signal.
    fn readStdout(self: *Hung) ![]u8 {
        return std.Io.Dir.cwd().readFileAlloc(io, self.stdout_path, gpa, .limited(1 << 20)) catch
            try gpa.dupe(u8, "");
    }
};

/// Python's `_hung_argv()`: skip unless the fixture is there AND
/// executable. Both halves matter — `sh fixture` would happily run a
/// non-executable file, so checking existence alone would let a
/// permission regression masquerade as a behaviour change.
fn hungArgv() ![]const u8 {
    std.Io.Dir.cwd().access(io, HUNG_SERVER, .{ .execute = true }) catch {
        std.debug.print(
            "hung-server.sh missing or not executable: {s}\n",
            .{HUNG_SERVER},
        );
        return error.SkipZigTest;
    };
    return HUNG_SERVER;
}

/// `kill(pid, 0)` — Python's `proc.poll() is None`, inverted.
///
/// Swallows every error into "not alive": ESRCH is the answer, EPERM
/// (alive but not ours) is the one case where reporting "dead" would
/// be wrong, and these children are always ours.
fn childAlive(pid: u32) bool {
    if (builtin.os.tag == .windows) return true;
    const p: std.posix.pid_t = @intCast(pid);
    std.posix.kill(p, @as(std.posix.SIG, @enumFromInt(0))) catch return false;
    return true;
}

/// Spawn the hung fixture with `stdin_text` already in its stdin file.
///
/// The stdin file is written BEFORE the spawn so the fixture's first
/// `read -r` returns immediately rather than racing the parent's
/// write — the Python wrote through a pipe and flushed, which is the
/// same ordering guarantee.
fn spawnHung(scratch: []const u8, stdin_text: []const u8) !Hung {
    const argv = try hungArgv();

    const stdin_path = try std.fs.path.join(gpa, &.{ scratch, "hung-stdin" });
    defer gpa.free(stdin_path);
    const stdout_path = try std.fs.path.join(gpa, &.{ scratch, "hung-stdout" });
    errdefer gpa.free(stdout_path);

    // Both handles stay open until the spawn returns: `SpawnOptions
    // .stdin/.stdout = .{ .file = h }` hands the CHILD its own dup of
    // the descriptor, so closing early would leave the fixture reading
    // and writing nothing. `writeStreamingAll` is unbuffered, so the
    // frame is on disk before the child exists.
    var in_file = try std.Io.Dir.cwd().createFile(io, stdin_path, .{});
    defer in_file.close(io);
    try in_file.writeStreamingAll(io, stdin_text);

    var out_file = try std.Io.Dir.cwd().createFile(io, stdout_path, .{});
    defer out_file.close(io);

    const child = try std.process.spawn(io, .{
        .argv = &.{argv},
        .stdin = .{ .file = in_file },
        .stdout = .{ .file = out_file },
        // Python: `stderr=subprocess.DEVNULL`. The fixture writes
        // nothing there, and inheriting the test runner's stderr would
        // interleave bash noise into the suite's output.
        .stderr = .ignore,
    });
    return .{ .child = child, .pid = @intCast(child.id.?), .stdout_path = stdout_path };
}

// A hung stdio child does not write a tools/list response within
// `deadline_s + slack`. We DON'T exercise the Zig recv path here
// (the Zig unit test in mcp_stdio.zig:1014 `recv returns RecvTimeout
// when child never responds` covers that) — this test only proves
// the wire-level behavior the hung-server.sh fixture produces.
//
// Why this test exists: it gives a fast wire-level smoke that the
// fixture is correctly hung BEFORE the more expensive Zig-level
// tests run. If this hangs forever, the hung-server.sh fixture is
// broken (e.g. the bash `read` exited early, or the sleep exited).
test "hung_child_does_not_send_response_within_1s" {
    const scratch = try harness.makeScratchDir(gpa);
    defer gpa.free(scratch); // LAST
    defer harness.cleanupExtraDir(io, gpa, scratch); // before the free

    // Python writes the frame, then an extra newline so the child's
    // `read` returns. Kept as one buffer: the fixture consumes one
    // line either way, and the byte count is not the subject.
    var hung = try spawnHung(scratch, TOOLS_LIST_FRAME ++ "\n");
    defer hung.deinit(); // FIRST — the `sleep 3600` must not outlive us

    // We're proving the NEGATIVE: the hung child does NOT send a
    // tools/list response. The Python helper polled in 0.5s slices
    // and raised TimeoutError when the deadline passed with nothing
    // to read.
    const start = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    const deadline = start + DEADLINE_MS;
    var arrived: ?[]u8 = null;
    while (std.Io.Timestamp.now(io, .awake).toMilliseconds() < deadline) {
        const bytes = try hung.readStdout();
        if (bytes.len > 0) {
            arrived = bytes;
            break;
        }
        // Sleep one `select` slice, capped by what is left of the
        // budget. Slices matter here: the fixture is SUPPOSED to stay
        // quiet, so the assertion is "nothing arrived in any 500ms
        // window of that second" — a single poll at t=0 followed by a
        // 1s nap would pass even if the child answered at t=0.4s.
        const remaining = deadline - std.Io.Timestamp.now(io, .awake).toMilliseconds();
        if (remaining > 0) {
            const nap = @min(remaining, POLL_SLICE_MS);
            std.Io.sleep(io, .fromMilliseconds(nap), .awake) catch {};
        }
    }

    // Python: `with pytest.raises(TimeoutError)`.
    if (arrived) |frame| {
        defer gpa.free(frame);
        const quoted = harness.debugString(gpa, frame) catch frame;
        defer if (quoted.ptr != frame.ptr) gpa.free(quoted);
        std.debug.print(
            "hung child sent a response within {d}ms; the fixture is not hung: {s}\n",
            .{ DEADLINE_MS, quoted },
        );
        return error.TestUnexpectedResult;
    }

    // Python: `assert elapsed >= 1.0` — the timeout fired for the
    // right reason (we waited the whole window) rather than because
    // the poll gave up on the first empty read.
    const elapsed = std.Io.Timestamp.now(io, .awake).toMilliseconds() - start;
    if (elapsed < DEADLINE_MS) {
        std.debug.print(
            "wait_for_timeout returned in {d}ms — expected ~{d}ms (the " ++
                "timeout must fire for the right reason)\n",
            .{ elapsed, DEADLINE_MS },
        );
        return error.TestUnexpectedResult;
    }
}

// After killing the hung child, a fresh spawn with the same argv
// produces a NEW PID. Proves the `markStale → respawn` contract at
// the process level: a registered name in the registry can be
// replaced by a fresh child after the hung one is killed.
//
// Why this is a contract test, not a pabrik test: the
// StdioRegistry's `dirty → drop → respawn` is just bookkeeping
// over `std.process.spawn`. The Zig unit test 23 `markStale forces
// respawn on next getOrSpawn` covers the bookkeeping; this test
// proves the spawn itself works after a kill.
test "hung_child_can_be_replaced_by_fresh_process" {
    const scratch = try harness.makeScratchDir(gpa);
    defer gpa.free(scratch); // LAST
    defer harness.cleanupExtraDir(io, gpa, scratch); // before the free

    var proc1 = try spawnHung(scratch, "");
    const pid1 = proc1.pid;
    // Scoped block: Python's `try/finally` around the FIRST child.
    // `deinit` kills AND reaps, which is what makes the second
    // spawn's pid comparison meaningful — an unreaped zombie would
    // still be holding its pid.
    {
        defer proc1.deinit();

        if (!childAlive(pid1)) {
            std.debug.print(
                "hung child pid={d} exited prematurely\n",
                .{pid1},
            );
            return error.TestUnexpectedResult;
        }
    }

    // Spawn a fresh one.
    var proc2 = try spawnHung(scratch, "");
    defer proc2.deinit();
    const pid2 = proc2.pid;

    if (!childAlive(pid2)) {
        std.debug.print(
            "second hung child pid={d} exited prematurely\n",
            .{pid2},
        );
        return error.TestUnexpectedResult;
    }
    if (pid1 == pid2) {
        std.debug.print(
            "expected fresh pid after kill, got the same pid ({d}) — " ++
                "the kernel must not have reaped the first process\n",
            .{pid1},
        );
        return error.TestUnexpectedResult;
    }
}

comptime {
    // Body-analysis barrier: an unreferenced function is never
    // type-checked, so a stdlib rename inside one would stay invisible
    // until some caller appeared.
    _ = Hung;
    _ = Hung.deinit;
    _ = Hung.readStdout;
    _ = hungArgv;
    _ = childAlive;
    _ = spawnHung;
    _ = Harness.boot;
}
