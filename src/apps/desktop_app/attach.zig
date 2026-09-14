// src/apps/desktop_app/attach.zig
//
// Desktop's "find nalar" logic (Chunk 4 of the decoupled-nalar-service plan).
//
// On launch, the desktop probes for a running nalar daemon that can serve
// the webapp and attaches the webview. If none is found and --no-auto-start
// is NOT set, the desktop spawns a detached nalar via `subprocess.spawn`
// and waits for it to come up.
//
// "Can serve the webapp" is deliberately stronger than "is running": a
// daemon answers /health with 200 even when its --static-dir no longer
// exists, and attaching to such a daemon opens the webview on
// `404 Not Found`. Every candidate must pass `probeWebapp` (2xx on GET /
// with an HTML body) before we hand it to the webview, and a freshly
// spawned child must pass it too before we return it.
//
// The desktop never signals nalar on close — closing the window does
// NOT stop the daemon. Only `nalar service stop` (a separate CLI
// invocation) ends the daemon's life.

const std = @import("std");
const builtin = @import("builtin");
const nalarcore = @import("nalarcore");
const helpers = @import("helpers");
const subprocess = @import("subprocess.zig");
const path_resolve = @import("path_resolve.zig");
const port = @import("port.zig");

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
///
/// A server is only attachable when it serves the WEBAPP (`probeWebapp`),
/// not merely when it answers `/health`. A daemon whose `--static-dir`
/// vanished is still "healthy" while answering `GET /` with
/// `404 Not Found`; attaching the webview to it is the blank-page bug
/// this guards against. When the only daemon around is unusable we fall
/// through to the auto-spawn path instead of giving up.
pub fn resolveAttachTarget(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: AttachOptions,
) AttachError!AttachTarget {
    // 1. State file: read it, check the pid is alive, probe the port.
    if (try nalarcore.state_file.readStateFile(allocator, io, opts.state_path)) |state| {
        defer nalarcore.state_file.freeState(allocator, state);
        if (isUsableWebappServer(state.host, state.port, io)) {
            // Caller now owns state.host — it outlives this function. We
            // can't pass a slice into a returned struct without making a
            // copy; for v1, copy the strings.
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
    if (isUsableWebappServer("127.0.0.1", opts.default_port, io)) {
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

/// True when `port` hosts a nalar that actually serves the webapp.
/// Logs (loudly) why a merely-healthy server was rejected, because the
/// user's next question is always "my nalar is running, why did it
/// start a second one?".
fn isUsableWebappServer(host: []const u8, backend_port: u16, io: std.Io) bool {
    if (!probeHealth(host, backend_port, io)) return false;
    if (subprocess.probeWebapp(backend_port)) return true;
    std.log.warn(
        "nalar on port {d} is alive but does not serve the webapp at / (GET / is not HTML) — ignoring it",
        .{backend_port},
    );
    return false;
}

fn probeHealth(host: []const u8, backend_port: u16, io: std.Io) bool {
    _ = host;
    _ = io;
    // 1-second connect+GET /health probe. Returns true on 2xx, false
    // otherwise. Health alone is NOT enough to attach — see
    // `isUsableWebappServer`.
    return subprocess.probeHealth(backend_port);
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

    // 2. Pick a port the child can actually bind. Prefer the well-known
    //    one (keeps 8081 / --attach-port working), but if something else
    //    holds it — typically a nalar that does not serve the webapp,
    //    which steps 1/2 above refused to attach to — take an ephemeral
    //    port instead. Spawning into an occupied port would fail to bind
    //    while the squatter's own `/health` kept answering our readiness
    //    probe, so we'd report success for a port we don't own.
    const spawn_port = chooseSpawnPort(allocator, io, opts.default_port);

    std.log.info("No usable nalar daemon found — spawning a new one at {s} --port {d} (static dir: {s})", .{
        nalar_path,
        spawn_port,
        if (opts.static_dir.len > 0) opts.static_dir else "(none)",
    });

    // 3. Spawn the child process. Pass `opts.static_dir` so the spawned
    //    nalar serves the webapp at `/`. If static_dir is empty (caller
    //    didn't provide one), `nalar` only serves API endpoints and the
    //    webapp check in step 5 below fails — which is the honest answer
    //    for a desktop that exists to show the webapp. In practice
    //    main.zig always populates this with a persistent dir.
    var child = subprocess.spawn(
        allocator,
        io,
        nalar_path,
        spawn_port,
        if (opts.static_dir.len > 0) opts.static_dir else null,
    ) catch |err| {
        std.log.err("Spawning nalar at {s} failed: {s}", .{ nalar_path, @errorName(err) });
        std.log.err("Hint: the desktop doesn't manage nalar's lifecycle.", .{});
        std.log.err("      If `nalar service start` is more reliable, prefer that.", .{});
        return error.AutoSpawnFailed;
    };

    // 4. Wait for /health to respond with 200. The child is now running;
    //    if the desktop closes, the child is NOT auto-terminated (that's
    //    the chunk 4 architectural commitment — desktop doesn't signal
    //    nalar on close). The child becomes a long-lived daemon the user
    //    has to stop manually via `nalar service stop` — which is
    //    precisely why its --static-dir must be a persistent directory.
    subprocess.waitForHealth(spawn_port, 5_000, 100) catch |err| {
        std.log.err("Spawned nalar but /health never came up: {s}", .{@errorName(err)});
        // Don't leak the orphan: kill it before bailing.
        child.terminate(io);
        return error.AutoSpawnFailed;
    };

    // 5. Verify the child can serve the APP, not just /health. Handing
    //    the webview a URL that 404s is exactly the bug this path exists
    //    to prevent, so fail loudly (and don't leave a useless daemon
    //    behind) instead of opening a blank window.
    if (!subprocess.probeWebapp(spawn_port)) {
        std.log.err(
            "Spawned nalar on port {d} but it does not serve the webapp at / — refusing to open a 404 window.",
            .{spawn_port},
        );
        std.log.err("Check that the webapp dir contains index.html and is readable.", .{});
        child.terminate(io);
        return error.AutoSpawnFailed;
    }

    // 6. Persist state.json so the NEXT launch finds this daemon via step 1
    //    instead of spawning a duplicate. Without this, every launch that
    //    lands on an ephemeral port is invisible to the next one (which
    //    only probes the state file + the well-known port), so each
    //    `--browser` click leaks another detached daemon — e.g. :51165
    //    then :8081 side by side. Best-effort: the daemon is already
    //    healthy and usable, so a write failure only warns.
    const state: nalarcore.state_file.State = .{
        .pid = child.pid,
        .port = spawn_port,
        .host = "127.0.0.1",
        .started_at = helpers.unixTimestamp(),
        .version = "0.4.0",
        .static_dir = if (opts.static_dir.len > 0) opts.static_dir else null,
    };
    nalarcore.state_file.writeStateFile(allocator, io, opts.state_path, state) catch |err| {
        std.log.warn(
            "Spawned nalar on port {d} but could not write state file {s}: {s} — the next launch may spawn a duplicate",
            .{ spawn_port, opts.state_path, @errorName(err) },
        );
    };

    return .{
        .host = try allocator.dupe(u8, "127.0.0.1"),
        .port = spawn_port,
        .we_spawned = true,
    };
}

/// Prefer `preferred` unless something is already listening there, in
/// which case hand back an ephemeral free port.
fn chooseSpawnPort(allocator: std.mem.Allocator, io: std.Io, preferred: u16) u16 {
    if (port.isFree(allocator, io, preferred)) return preferred;
    const free = port.findFree(allocator, io) catch {
        // Couldn't probe for a free port — try the preferred one anyway
        // rather than refusing to start at all.
        std.log.warn("Could not allocate a free port; trying {d} anyway", .{preferred});
        return preferred;
    };
    if (free.port == preferred) return preferred;
    // Tell the user how to get back to the well-known port — otherwise
    // every launch keeps spawning a fresh daemon on a random port because
    // the squatter never goes away. The spawned daemon's port is recorded
    // in the state file (step 6 of the auto-spawn path) so the next launch
    // attaches to it instead of spawning again.
    std.log.warn(
        "Port {d} is already in use by a server that does not serve the webapp; spawning on {d} instead",
        .{ preferred, free.port },
    );
    std.log.warn(
        "To stop that server and go back to port {d}, run:  nalar service stop  (or kill the process listening on {d})",
        .{ preferred, preferred },
    );
    return free.port;
}