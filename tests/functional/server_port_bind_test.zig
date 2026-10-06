// Starting pabrik on an already-occupied port must fail cleanly.
//
// Zig port of `tests/functional/server_port_bind_test.py`
// (same test name).
//
// Regression test for a bug that made the functional suite
// untrustworthy: `Address.init` returns `error.BindFailed` when the
// port is taken, `try` carried it out of `main`, and the process died
// on the runtime's error path with **SIGSEGV (exit code -11)** plus a
// bare stack trace. The harness reads that as
// `pabrik exited rc=-11 during boot` and reports it as a crash of the
// binary, so an ordinary port collision — which the harness can cause
// itself, see the RANDOM_PORT_* comment in harness.zig — looks like a
// memory-safety bug in an unrelated test.
//
// Contract pinned here:
//   * exit code is a plain positive non-zero (NOT a negative signal
//     code),
//   * stderr names the port and says the address is already in use,
//   * no `BindFailed` stack trace (the operator message replaces it).
//
// Run:
//     zig build install:linux
//     PABRIK_BIN=$(pwd)/zig-out/bin/pabrikcore-linux-x86_64 \
//         zig build test --summary all   # from tests/functional/

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");

const gpa = testing.allocator;
const io = testing.io;

/// `subprocess.run(timeout=90)`'s budget, in ms. Mirrors the Python
/// original's `timeout=90`.
///
/// It also determines the WALL CLOCK of this test: `runPabrikCommand`
/// joins its kill-watchdog thread, and that thread sleeps the FULL
/// budget before returning, so the call blocks for ~90 s even though the
/// child itself exits in ~50 ms. See the note on the elapsed-time
/// sanity check below.
const SPAWN_TIMEOUT_MS: u32 = 90_000;

/// Python sliced `stderr[-2000:]` into every assertion message. Same
/// here, so a failure shows the tail of the binary's own diagnostics
/// rather than a 40 KiB stack dump.
const STDERR_TAIL: usize = 2000;

/// Allocate a fresh `pabrik-func-<random>` tempdir and return its
/// absolute path, owned by the caller.
///
/// `harness.zig`'s own `makeTempDir` is private (nothing in this suite
/// needs it), so this is a local re-implementation of exactly what the
/// Python test did with
/// `tempfile.mkdtemp(prefix=REQUIRED_TMP_SUBSTR)`: pick a candidate
/// under the OS temp root, `createDirPath` it, and RETRY on
/// `PathAlreadyExists` rather than hand back a name someone else owns.
///
/// The `pabrik-func-` namespace substring is mandatory — `isSafeTmp`
/// refuses to delete anything without it, so a tempdir named anything
/// else would leak on every run.
fn makeTempDir() ![]u8 {
    const base = try harness.tmpRoot(gpa);
    defer gpa.free(base);

    var attempt: usize = 0;
    while (attempt < 32) : (attempt += 1) {
        const ts: u64 = @bitCast(@as(i64, std.Io.Timestamp.now(io, .awake).toMilliseconds()));
        const seed = ts ^ @as(u64, @intCast(attempt));

        const leaf = try std.fmt.allocPrint(gpa, "{s}{x}", .{ harness.REQUIRED_TMP_SUBSTR, seed });
        defer gpa.free(leaf);

        // No `defer gpa.free(name)` below: that slice IS the return
        // value and would be freed before the caller ever read it.
        const name = try harness.harnessPath(gpa, base, &.{leaf});
        std.Io.Dir.cwd().createDirPath(io, name) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => {
                gpa.free(name);
                return err;
            },
        };
        return name;
    }
    return error.BootFailed;
}

/// Delete `temp_dir` through the SAME safety gate every harness
/// teardown uses. Refuses (rather than deleting) if `isSafeTmp` fails.
fn removeTempDir(temp_dir: []const u8, orig_home: []const u8) void {
    const safe = harness.isSafeTmp(io, gpa, temp_dir, orig_home) catch false;
    if (!safe) {
        std.debug.print(
            "REFUSING to rmtree unsafe path: {s}\n",
            .{temp_dir},
        );
        return;
    }
    std.Io.Dir.cwd().deleteTree(io, temp_dir) catch |err| {
        std.debug.print("could not delete {s}: {s}\n", .{ temp_dir, @errorName(err) });
    };
}

/// The last `STDERR_TAIL` bytes of `s` — borrowed, never allocated.
fn tail(s: []const u8) []const u8 {
    return if (s.len > STDERR_TAIL) s[s.len - STDERR_TAIL ..] else s;
}

// A taken port ⇒ rc > 0, never a negative (signal) code.
test "occupied_port_exits_nonzero_not_by_signal" {
    try harness.requirePabrikBin(io, gpa);

    const orig_home = testing.environ.getAlloc(gpa, "HOME") catch try gpa.dupe(u8, "");
    defer gpa.free(orig_home);

    const port = try harness.findFreePortRandom(gpa);

    const temp_dir = try makeTempDir();
    defer gpa.free(temp_dir);
    if (!try harness.isSafeTmp(io, gpa, temp_dir, orig_home)) {
        std.debug.print("mkdtemp produced {s}\n", .{temp_dir});
        return error.TestUnexpectedResult;
    }
    defer removeTempDir(temp_dir, orig_home);

    // The binary writes config into these before it ever reaches
    // `Address.init`. Python created them with
    // `mkdir(parents=True, exist_ok=True)` and pointed the env vars at
    // the results; a missing parent here could turn "port taken" into
    // "config write failed" and the assertion would pass for the wrong
    // reason.
    const xdg_dirs = [_][]const []const u8{
        &.{".config"},
        &.{ ".local", "state" },
        &.{ ".local", "share" },
        &.{".cache"},
    };
    for (xdg_dirs) |parts| {
        const dir = try harness.harnessPath(gpa, temp_dir, parts);
        defer gpa.free(dir);
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }

    // Squat the port: bind + listen so the child's bind() must fail.
    //
    // `Io.net`'s `reuse_address` sets SO_REUSEADDR (and SO_REUSEPORT on
    // POSIX) — a superset of the Python socket's SO_REUSEADDR-only
    // setup. That is still a hard block, because the listener under
    // test (kabelweb `http_server.zig` `setReuseAddr`) sets SO_REUSEADDR
    // and NOT SO_REUSEPORT: SO_REUSEPORT lets two sockets share a port
    // only when BOTH set it, so the child gets EADDRINUSE.
    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var squatter = try addr.listen(io, .{ .reuse_address = true });
    defer squatter.deinit(io);

    const port_str = try std.fmt.allocPrint(gpa, "{d}", .{port});
    defer gpa.free(port_str);

    var run = try harness.runPabrikCommand(io, gpa, temp_dir, &.{
        "--port", port_str,
    }, SPAWN_TIMEOUT_MS);
    defer run.deinit(gpa);

    const stderr = tail(run.stderr);

    // Python: `assert proc.returncode > 0`.
    //
    // `RunResult.exit_code` is `?u8` and is null precisely when the
    // child was killed by a signal rather than exiting — the Zig
    // spelling of Python's negative `-signal` returncode (-11 SIGSEGV,
    // -6 SIGABRT). That is the whole bug: an expected operator error
    // took the process down the runtime's error path. So null fails
    // here, exactly as a negative value failed in Python.
    const rc = run.exit_code orelse {
        std.debug.print(
            "expected a plain non-zero exit on a taken port, but the " ++
                "child died from a signal\n--- stderr ---\n{s}\n",
            .{stderr},
        );
        return error.TestUnexpectedResult;
    };
    if (rc == 0) {
        std.debug.print(
            "expected a plain non-zero exit on a taken port, got 0\n" ++
                "--- stderr ---\n{s}\n",
            .{stderr},
        );
        return error.TestUnexpectedResult;
    }

    // Python: `assert proc.returncode == 1`.
    try testing.expectEqual(@as(u8, 1), rc);

    if (std.mem.indexOf(u8, stderr, "already in use") == null) {
        std.debug.print(
            "stderr should tell the operator the port is taken, got:\n{s}\n",
            .{stderr},
        );
        return error.TestUnexpectedResult;
    }

    if (std.mem.indexOf(u8, stderr, port_str) == null) {
        std.debug.print("stderr should name the port {s}:\n{s}\n", .{ port_str, stderr });
        return error.TestUnexpectedResult;
    }

    // The stack trace is what made this read as a crash; the operator
    // message should have replaced it.
    if (std.mem.indexOf(u8, stderr, "BindFailed") != null) {
        std.debug.print(
            "BindFailed stack trace should be replaced by an operator message:\n{s}\n",
            .{stderr},
        );
        return error.TestUnexpectedResult;
    }

    // Python's closing sanity check — `time.monotonic() - started < 90`
    // — is NOT reproduced as a wall-clock measurement here, and the
    // reason is worth recording: `runPabrikCommand` joins a watchdog
    // thread that sleeps the FULL timeout before returning, so a
    // stopwatch around the call always reads ~90 s and the assertion
    // would fail on a perfectly healthy binary. The check's actual
    // content — "the child was still holding the port for the whole
    // attempt, so a fast success cannot be mistaken for a pass" — is
    // carried by `error.RunTimedOut` instead: `runPabrikCommand` kills
    // and returns that error when the child outlives its budget, which
    // is the same condition `subprocess.run(timeout=90)` turned into a
    // `TimeoutExpired` the Python `try` let escape as a test failure.
    // The `try` above already enforces it.
}
