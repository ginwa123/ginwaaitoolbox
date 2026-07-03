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
        defer {
            allocator.free(state.host);
            allocator.free(state.version);
            if (state.static_dir) |sd| allocator.free(sd);
        }
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
    // 2. Fallback: probe the well-known port.
    if (probeHealth("127.0.0.1", opts.default_port, io)) {
        return .{
            .host = "127.0.0.1",
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
    _ = port;
    return false;
}

fn autoSpawnAndWaitForHealth(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: AttachOptions,
) AttachError!AttachTarget {
    _ = allocator;
    _ = io;
    _ = opts;
    // Calls `<self_dir>/nalar service start --port <port>` and waits
    // for the state file to appear + the port to be healthy.
    //
    // Implementation deferred (Chunk 4 follow-up): the desktop's
    // subprocess.zig already has a probe helper
    // (subprocess.waitForHealth); we need to wire that into the
    // auto-spawn flow here. For v1, callers fall back to the
    // explicit-spawn path (`subprocess.spawn` invokes `nalar service
    // start`) when no daemon is running.
    return error.AutoSpawnFailed;
}