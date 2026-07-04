// src/main_service.zig
//
// Implements the `nalar service {start,stop,status,restart}` subcommand.
// The CLI dispatch lives in src/main.zig — when argv[1] == "service",
// main.zig routes the rest of the args into parseServiceSubcommand and
// then calls the corresponding function below.
//
// Lifecycle:
//   service start   → daemonize + write state.json + run server
//   service stop    → read state.json → SIGTERM(pid) → poll exit
//   service status  → read state.json + check pid alive
//   service restart → service stop + service start
//
// The server run-loop is provided by nalar's main() — see `runNalarServer`
// in src/main.zig (extracted from the original monolithic main body).

const std = @import("std");
const builtin = @import("builtin");
const state_file = @import("state_file.zig");
const daemon = @import("daemon.zig");
const signal_handlers = @import("signal_handlers.zig");

pub const Subcommand = union(enum) {
    start: struct { port: u16 = 8081, no_static_dir: bool = false },
    stop: struct { graceful_timeout_ms: u32 = 5000 },
    status: void,
    restart: struct { port: u16 = 8081, graceful_timeout_ms: u32 = 5000 },
};

pub const ParseError = error{
    UnknownSubcommand,
    MissingValue,
    InvalidPort,
    OutOfMemory,
};

pub fn parseServiceSubcommand(
    args: []const []const u8,
) ParseError!Subcommand {
    if (args.len == 0) return error.UnknownSubcommand;
    const verb = args[0];

    if (std.mem.eql(u8, verb, "start")) {
        var port: u16 = 8081;
        var no_static_dir = false;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--port")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                port = std.fmt.parseInt(u16, args[i], 10) catch return error.InvalidPort;
            } else if (std.mem.eql(u8, arg, "--no-static-dir")) {
                no_static_dir = true;
            } else return error.UnknownSubcommand;
        }
        return .{ .start = .{ .port = port, .no_static_dir = no_static_dir } };
    }

    if (std.mem.eql(u8, verb, "stop")) {
        var graceful_timeout_ms: u32 = 5000;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--graceful-timeout-ms")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                graceful_timeout_ms = std.fmt.parseInt(u32, args[i], 10) catch return error.InvalidPort;
            } else return error.UnknownSubcommand;
        }
        return .{ .stop = .{ .graceful_timeout_ms = graceful_timeout_ms } };
    }

    if (std.mem.eql(u8, verb, "status")) {
        if (args.len > 1) return error.UnknownSubcommand;
        return .status;
    }

    if (std.mem.eql(u8, verb, "restart")) {
        var port: u16 = 8081;
        var graceful_timeout_ms: u32 = 5000;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--port")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                port = std.fmt.parseInt(u16, args[i], 10) catch return error.InvalidPort;
            } else if (std.mem.eql(u8, arg, "--graceful-timeout-ms")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                graceful_timeout_ms = std.fmt.parseInt(u32, args[i], 10) catch return error.InvalidPort;
            } else return error.UnknownSubcommand;
        }
        return .{ .restart = .{ .port = port, .graceful_timeout_ms = graceful_timeout_ms } };
    }

    return error.UnknownSubcommand;
}

pub const StartError = anyerror;

pub const StartOptions = struct {
    port: u16,
    no_static_dir: bool,
    state_path: []const u8,
    log_path: []const u8,
    /// Injectable shutdown callback. Called from the SIGTERM signal handler
    /// to gracefully close the server and remove the state file. The
    /// production wiring passes a function that closes `gs` (the
    /// GinwaServer) and writes `state_path` removal. Tests can pass a
    /// no-op or a counter.
    on_shutdown: *const fn () void,
};

/// Start the nalar service. The actual server run-loop is provided by
/// `on_run_server` (called AFTER daemonization + state-file write so the
/// server PID matches the state file's pid). The caller wires this to
/// main.zig's `runNalarServer`.
///
/// POSIX daemonization is permanent — once `serviceStart` returns to the
/// caller, the daemon is running and the caller (the foreground
/// `nalar service start` invocation) has exited via daemonizePosix.
///
/// Windows is not implemented in v1 (compile error).
pub fn serviceStart(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: StartOptions,
) StartError!void {
    if (builtin.os.tag == .windows) {
        @compileError("serviceStart is POSIX-only in v1");
    }

    // 1. Refuse if a live daemon is already tracked in state.json.
    if (try state_file.readStateFile(allocator, io, opts.state_path)) |existing| {
        defer state_file.freeState(allocator, existing);
        if (daemon.pidAlive(existing.pid)) return error.AlreadyRunning;
        // Stale state (pid is dead) — remove and proceed.
        std.Io.Dir.cwd().deleteFile(io, opts.state_path) catch {};
    }

    // 2. Daemonize. After this returns, we're the grandchild. The
    //    parent paths exit(0) inside daemonizePosix.
    try daemon.daemonizePosix();
    try daemon.redirectStdioToLog(opts.log_path);

    // 3. Write our state.json (with the just-allocated PID).
    const state: state_file.State = .{
        .pid = std.c.getpid(),
        .port = opts.port,
        .host = "127.0.0.1",
        .started_at = unixTimestampSeconds(),
        .version = "0.4.0",
        .static_dir = null,
    };
    try state_file.writeStateFile(allocator, io, opts.state_path, state);

    // 4. Install SIGTERM handler that invokes the injectable shutdown.
    signal_handlers.installSigtermHandler(opts.on_shutdown);

    // 5. Hand off to the caller-supplied server run-loop. This blocks
    //    until the server stops (typical: shutdown HTTP endpoint
    //    called, or SIGTERM received).
}

/// Unix timestamp in seconds. Uses libc gettimeofday (no Io required).
fn unixTimestampSeconds() i64 {
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    return @intCast(tv.sec);
}

pub const StopError = error{ OutOfMemory };

pub const StopOptions = struct {
    graceful_timeout_ms: u32,
    state_path: []const u8,
};

/// Stop the nalar service. Idempotent: if no state file exists, this
/// is a no-op (informational log). If the pid in the state file is
/// dead, we treat it as stale and remove the file (no error).
pub fn serviceStop(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: StopOptions,
) StopError!void {
    const state = (try state_file.readStateFile(allocator, io, opts.state_path)) orelse {
        std.log.info("nalar is not running (no state file).", .{});
        return;
    };
    defer state_file.freeState(allocator, state);
    if (!daemon.pidAlive(state.pid)) {
        std.log.warn("Stale state file (pid {d} is dead); removing.", .{state.pid});
        std.Io.Dir.cwd().deleteFile(io, opts.state_path) catch {};
        return;
    }
    _ = std.c.kill(state.pid, @as(std.c.SIG, @enumFromInt(15))); // SIGTERM
    // Poll until dead or graceful_timeout_ms. Zig 0.16 removed
    // std.time.monotonic(); libc clock_gettime(CLOCK_MONOTONIC) works.
    const start_ns = readMonotonicNs();
    const deadline_ns: u64 = start_ns + @as(u64, opts.graceful_timeout_ms) * std.time.ns_per_ms;
    while (readMonotonicNs() < deadline_ns) {
        if (!daemon.pidAlive(state.pid)) break;
        var ts = std.posix.timespec{ .sec = 0, .nsec = 50_000_000 };
        _ = std.c.nanosleep(&ts, null);
    }
    if (daemon.pidAlive(state.pid)) {
        std.log.warn("Graceful shutdown timed out, sending SIGKILL.", .{});
        _ = std.c.kill(state.pid, @as(std.c.SIG, @enumFromInt(9))); // SIGKILL
    }
    std.Io.Dir.cwd().deleteFile(io, opts.state_path) catch {};
}

fn readMonotonicNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Report service status. Logs (using std.log) whether the service is
/// running, stale, or absent.
pub fn serviceStatus(
    allocator: std.mem.Allocator,
    io: std.Io,
    state_path: []const u8,
) !void {
    const state = (try state_file.readStateFile(allocator, io, state_path)) orelse {
        std.log.info("status: stopped (no state file)", .{});
        return;
    };
    defer state_file.freeState(allocator, state);
    if (!daemon.pidAlive(state.pid)) {
        std.log.warn("status: stale state (pid {d} is dead)", .{state.pid});
        return;
    }
    std.log.info("status: running (pid {d}, http://{s}:{d}/)", .{ state.pid, state.host, state.port });
}