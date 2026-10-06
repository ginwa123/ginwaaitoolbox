// Graceful shutdown: Ctrl+C (SIGINT) and SIGTERM drain cleanly.
//
// Zig port of `tests/functional/graceful_shutdown_test.py` (same test
// names, same order).
//
// Regression test for "are we using graceful shutdown for backend":
// before the fix, the foreground server installed no SIGINT/SIGTERM
// handler, so Ctrl+C killed the process with the default disposition —
// no listener close, no cron/SSE join, no SQLite deinit (rely on WAL
// recovery), truncated in-flight responses.
//
// After the fix, `main` installs `signal_handlers.installShutdownHandlers`
// which calls `GinwaServer.shutdown()` (stop accept + unblock `listen()`)
// so the existing `cronjob_manager.stop() / sse_manager.stop() / defer`
// unwind runs. A second signal force-exits (130).
//
// Method: boot a real binary via the functional harness (isolated tmpdir
// HOME, random free port — never 8081), assert /health serves, send
// SIGINT to the child pid, assert the process exits promptly with a
// clean status (0, not -SIGINT/-SIGTERM/-SEGV), and assert the port stops
// serving. SIGTERM path covered the same way (docker/systemd/`service
// stop` send TERM).
//
// WHY THIS SUITE CALLS `waitpid` DIRECTLY
//
// The Python harness owned the `subprocess.Popen` and reaped it with
// `os.waitpid(pid, WNOHANG)`. The Zig harness spawns the child with
// `std.process.spawn` and keeps only the PID (`Harness.pid`) — the
// `Child` handle is dropped, so nothing in `Harness` ever reaps it.
// That is also why `kill(pid, 0)` is useless as an exit probe here: a
// dead-but-unreaped child answers 0 (zombie), so a liveness poll would
// spin the whole deadline and then report "did not exit" for a process
// that exited in 50ms. `waitpid(WNOHANG)` is the only call that both
// reaps AND reports EXITED-vs-SIGNALLED, which is precisely the
// distinction this suite exists to assert.
//
// TODO(port): `std.posix` exposes no non-libc `waitpid`, and this
// package deliberately links no libc (see build.zig), so the reaping is
// spelled against `std.os.linux` and the suite skips on every other
// OS. The macOS/Windows port is a `std.c.waitpid` call behind that
// package's libc link.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const builtin = @import("builtin");

const gpa = testing.allocator;
const io = testing.io;

/// Seconds the Python `_wait_exit` allowed before declaring the
/// graceful handler hung. Kept verbatim: this IS the regression budget.
const exit_timeout_ms: i64 = 10_000;

/// Monotonic milliseconds. Zig 0.16 dropped `std.time.milliTimestamp`; the
/// monotonic clock now hangs off the Io handle. `.awake`, not `.real` — a
/// wall-clock step backwards (NTP) must not extend the deadline.
fn nowMs() i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

/// Signal `pid` and block until it exits (or `exit_timeout_ms` elapses),
/// then assert the status word says "exited cleanly".
///
/// Returns `error.SkipZigTest` off Linux — see the file header.
fn awaitCleanExit(pid: u32, sig: std.posix.SIG, sig_name: []const u8) !void {
    if (comptime builtin.os.tag == .linux) {
        std.posix.kill(@intCast(pid), sig) catch |err| {
            std.debug.print("kill({d}, {s}) failed: {s}\n", .{ pid, sig_name, @errorName(err) });
            return err;
        };

        const deadline = nowMs() + exit_timeout_ms;
        var status: u32 = 0;
        var reaped = false;
        while (nowMs() < deadline) {
            const rc = std.os.linux.waitpid(@intCast(pid), &status, std.os.linux.W.NOHANG);
            switch (std.posix.errno(rc)) {
                .SUCCESS => {
                    // WNOHANG returns 0 when the child has not changed
                    // state yet; anything else is the pid that exited.
                    if (rc != 0) {
                        reaped = true;
                        break;
                    }
                    std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
                },
                // ECHILD: already reaped elsewhere, so there is no status
                // word to read. Python's `_wait_exit` mapped the same
                // `ChildProcessError` to "already reaped" and returned its
                // still-`None` status, which failed the very next assert.
                .CHILD => break,
                else => {
                    std.debug.print("waitpid({d}) failed: {t}\n", .{ pid, std.posix.errno(rc) });
                    break;
                },
            }
        }

        if (!reaped) {
            std.debug.print(
                "server did not exit within {d}s of {s} (graceful shutdown hung?)\n",
                .{ exit_timeout_ms / 1000, sig_name },
            );
            return error.TestUnexpectedResult;
        }

        if (std.os.linux.W.IFEXITED(status)) {
            const code = std.os.linux.W.EXITSTATUS(status);
            // 0 = clean unwind through listen() return + defers;
            // 130 = second-signal force-exit path (acceptable, still
            // graceful intent, never a crash).
            if (code != 0 and code != 130) {
                std.debug.print("{s} exit code {d}, expected 0 (clean) or 130 (force)\n", .{ sig_name, code });
                return error.TestUnexpectedResult;
            }
        } else if (std.os.linux.W.IFSIGNALED(status)) {
            std.debug.print(
                "server died by signal {d} after {s} — graceful handler did not run (default disposition killed it)\n",
                .{ @as(u32, @intFromEnum(std.os.linux.W.TERMSIG(status))), sig_name },
            );
            return error.TestUnexpectedResult;
        } else {
            std.debug.print("unexpected waitpid status 0x{x} after {s}\n", .{ status, sig_name });
            return error.TestUnexpectedResult;
        }
    } else {
        // The `if`/`else` is comptime-resolved, but Zig still ANALYZES
        // the untaken branch, so a plain `_ = x` is a "pointless
        // discard" on Linux. `doNotOptimizeAway` is the idiomatic
        // "genuinely dead on this platform" marker.
        std.mem.doNotOptimizeAway(pid);
        std.mem.doNotOptimizeAway(sig);
        std.mem.doNotOptimizeAway(sig_name);
        return error.SkipZigTest;
    }
}

/// Is `h`'s port still serving `/health`?
///
/// Python's `_port_serves` swallowed EVERY exception (including
/// `ConnectionRefusedError`, which is the expected answer once the
/// process is gone) and returned False. A failed request is therefore a
/// "not serving", not a test failure.
///
/// WHY A RAW CLIENT AND NOT `Harness.http`
///
/// This is the one call in the suite that runs against a DEAD server,
/// so `client.request(...)` fails with `ConnectionRefused` — and
/// `Harness.http` only frees its `buildUrl` allocation on the two
/// paths it wrote `gpa.free(url)` into. The early-error path leaks it,
/// which `testing.allocator` reports as a leak against THIS test.
/// Python reached for `urllib.request.urlopen` directly here for the
/// same reason; this is the Zig spelling of that.
fn portServes(h: *Harness) bool {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    // `portServes` answers a boolean, so an allocation failure is a
    // "cannot prove it is serving" rather than a propagated error.
    const url = std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/health", .{h.port}) catch return false;
    defer gpa.free(url);

    var req = client.request(.GET, std.Uri.parse(url) catch return false, .{}) catch return false;
    defer req.deinit();
    req.sendBodiless() catch return false;

    var resp = req.receiveHead(&.{}) catch return false;
    var sink: std.Io.Writer.Discarding = .init(&.{});
    _ = resp.reader(&.{}).streamRemaining(&sink.writer) catch {};

    return @intFromEnum(resp.head.status) == 200;
}

/// The half of each test that is identical between SIGINT and SIGTERM:
/// health-check, signal, await the clean exit, release the harness's
/// pid, and confirm the listener is gone.
fn exerciseSignal(h: *Harness, sig: std.posix.SIG, sig_name: []const u8) !void {
    if (!h.health(io)) {
        std.debug.print("server should serve /health before {s}\n", .{sig_name});
        return error.TestUnexpectedResult;
    }

    const pid = h.pid orelse return error.TestUnexpectedResult;

    try awaitCleanExit(pid, sig, sig_name);

    // Mark reaped so `Harness.deinit` skips the redundant kill ladder
    // (it tolerates dead pids anyway, but this keeps the log clean —
    // exactly what the Python `harness._stopped = True` did).
    h.stopped = true;
    h.pid = null;

    if (portServes(h)) {
        std.debug.print("port should stop serving after graceful {s} shutdown\n", .{sig_name});
        return error.TestUnexpectedResult;
    }
}

// Ctrl+C (SIGINT) stops the server cleanly instead of killing it.
test "sigint_ctrl_c_shuts_down_gracefully" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try exerciseSignal(&h, .INT, "SIGINT");
}

// SIGTERM (docker/systemd/service stop) stops the server cleanly.
test "sigterm_shuts_down_gracefully" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try exerciseSignal(&h, .TERM, "SIGTERM");
}