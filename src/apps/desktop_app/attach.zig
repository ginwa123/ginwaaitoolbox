// src/apps/desktop_app/attach.zig
//
// Desktop's "find nalar" logic (Chunk 4 of the decoupled-nalar-service plan).
//
// On launch, the desktop probes for a running nalar daemon and attaches
// the webview. If none is found and --no-auto-start is NOT set, the
// desktop spawns a detached nalar via `nalar service start` and waits
// for it to come up.
//
// The desktop never signals nalar on close — closing the window does
// NOT stop the daemon. Only `nalar service stop` (a separate CLI
// invocation) ends the daemon's life.

const std = @import("std");
const builtin = @import("builtin");
const nalarcore = @import("nalarcore");
const subprocess = @import("subprocess.zig");
const path_resolve = @import("path_resolve.zig");

pub const AttachOptions = struct {
    /// Path to the nalar state file (from `state_file.defaultStatePath`).
    /// The desktop reads this to find an existing daemon's host+port.
    state_path: []const u8,
    /// Port to probe as a fallback if no state file exists. Default 8081.
    default_port: u16 = 8081,
    /// When true, refuse to auto-spawn nalar if none is running; the
    /// caller surfaces an actionable error to the user.
    no_auto_start: bool = false,
    /// Path to the nalar binary (used by the auto-spawn path).
    /// Optional — when null, we attempt to spawn using `path_resolve`
    /// against the desktop's own location.
    nalar_path: ?[]const u8 = null,
    /// The desktop's own executable path. Used by `path_resolve` to
    /// check if `nalar` lives next to the desktop binary. Optional —
    /// when null, the auto-spawn path skips the "next-to-self"
    /// resolution strategy and goes straight to $PATH lookup.
    self_exe_path: ?[]const u8 = null,
    /// $PATH string (colon-separated on Unix). Required for the $PATH
    /// resolution strategy when `nalar_path` is null AND there's no
    /// nalar next to the desktop binary.
    path_env: []const u8 = "",
    /// Absolute path to the extracted webapp assets. When the auto-spawn
    /// path fires, the spawned nalar is started with `--static-dir <this>`
    /// so it serves the desktop's webapp at `/`. When attaching to an
    /// existing nalar, this field is ignored (the user manages their
    /// own nalar's static-dir). Always provided by main.zig; treat as
    /// non-null in the auto-spawn path.
    static_dir: []const u8 = "",
};

pub const AttachTarget = struct {
    host: []const u8,
    port: u16,
    /// Whether the desktop spawned a fresh daemon to satisfy this
    /// attach. `we_spawned = true` means the daemon outlives the
    /// desktop; `false` means we attached to one the user started
    /// independently.
    we_spawned: bool,
};

pub const AttachError = error{
    AutoStartDisabled,
    AutoSpawnFailed,
    NalarNotFound,
    OutOfMemory,
};

/// Probe state.json, then the default port, then auto-spawn as needed.
/// Returns the AttachTarget. Never returns "we_spawned=true" without
/// having actually launched a daemon — the caller can trust this.
pub fn resolveAttachTarget(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: AttachOptions,
) AttachError!AttachTarget {
    // 1. State file: read it, check the pid is alive, probe the port.
    if (try nalarcore.state_file.readStateFile(allocator, io, opts.state_path)) |state| {
        defer nalarcore.state_file.freeState(allocator, state);
        if (probeHealth(state.host, state.port, io)) {
            // Caller now owns state.host/version/static_dir — they
            // outlive this function. We can't pass a slice into a
            // returned struct without making a copy; for v1, copy
            // the strings.
            const host_dup = try allocator.dupe(u8, state.host);
            errdefer allocator.free(host_dup);
            return .{
                .host = host_dup,
                .port = state.port,
                .we_spawned = false,
            };
        }
    }
    // 2. Fallback: probe the well-known port. The host string is
    //    duped so the caller can free it with the same allocator it
    //    would use for the state-file success path (matches the
    //    ownership convention — the returned AttachTarget is always
    //    caller-owned).
    if (probeHealth("127.0.0.1", opts.default_port, io)) {
        return .{
            .host = try allocator.dupe(u8, "127.0.0.1"),
            .port = opts.default_port,
            .we_spawned = false,
        };
    }
    // 3. Auto-spawn (unless disabled).
    if (opts.no_auto_start) return error.AutoStartDisabled;
    return try autoSpawnAndWaitForHealth(allocator, io, opts);
}

fn probeHealth(host: []const u8, port: u16, io: std.Io) bool {
    _ = host;
    _ = io;
    // 1-second connect+GET /health probe. Returns true on 2xx, false
    // otherwise. The desktop's main.zig owns the actual probe impl
    // (this stub is a placeholder; tests verify the function pointer
    // works, not the wire details).
    //
    // Implementation: subprocess.waitForHealth blocks until /api/health
    // returns 2xx (or `timeout_ms` elapses, returning error.HealthCheckTimeout).
    // We treat timeout AND any error as "not healthy yet".
    subprocess.waitForHealth(port, 1000, 100) catch return false;
    return true;
}

fn autoSpawnAndWaitForHealth(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: AttachOptions,
) AttachError!AttachTarget {
    // 1. Resolve nalar's absolute path. Order is: explicit
    //    `--nalar-path` flag → next to self → $PATH lookup.
    const nalar_path = blk: {
        const explicit = opts.nalar_path orelse null;
        const self_exe = opts.self_exe_path orelse ".";
        const resolved = path_resolve.resolve(
            allocator,
            explicit,
            self_exe,
            opts.path_env,
        );
        break :blk resolved orelse {
            std.log.err("Cannot find 'nalar' binary.", .{});
            std.log.err("Hint: launch the desktop from a directory containing nalar, OR", .{});
            std.log.err("      run `nalar service start --port {d}` in a terminal first.", .{
                opts.default_port,
            });
            return error.NalarNotFound;
        };
    };
    defer allocator.free(nalar_path);

    std.log.info("No nalar daemon found — spawning a new one at {s} --port {d}", .{
        nalar_path,
        opts.default_port,
    });

    // 2. Spawn the child process. Pass `opts.static_dir` so the spawned
    //    nalar serves the extracted webapp at `/`. If static_dir is
    //    empty (caller didn't provide one), we still pass it through;
    //    nalar treats `--static-dir ""` as "no static dir" and the
    //    spawned process will only serve API endpoints, not the webapp.
    //    In practice main.zig always populates this.
    var child = subprocess.spawn(
        allocator,
        io,
        nalar_path,
        opts.default_port,
        if (opts.static_dir.len > 0) opts.static_dir else null,
    ) catch |err| {
        std.log.err("Spawning nalar at {s} failed: {s}", .{ nalar_path, @errorName(err) });
        std.log.err("Hint: the desktop doesn't manage nalar's lifecycle.", .{});
        std.log.err("      If `nalar service start` is more reliable, prefer that.", .{});
        return error.AutoSpawnFailed;
    };

    // 3. Wait for /health to respond with 200. The child is now running;
    //    if the desktop closes, the child is NOT auto-terminated (that's
    //    the chunk 4 architectural commitment — desktop doesn't signal
    //    nalar on close). The child becomes a long-lived daemon the user
    //    has to stop manually via `nalar service stop`.
    subprocess.waitForHealth(opts.default_port, 5_000, 100) catch |err| {
        std.log.err("Spawned nalar but /health never came up: {s}", .{@errorName(err)});
        // Don't leak the orphan: kill it before bailing.
        child.terminate(io);
        return error.AutoSpawnFailed;
    };

    return .{
        .host = try allocator.dupe(u8, "127.0.0.1"),
        .port = opts.default_port,
        .we_spawned = true,
    };
}