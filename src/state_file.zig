// src/state_file.zig
//
// Reads and writes the nalar service state file (state.json).
//
// The state file is the source of truth for `nalar service` lifecycle
// commands: `service start` writes the daemon's pid + port; `service stop`
// reads it to send SIGTERM; `service status` reads it to report state.
// The desktop's `attach.zig` also reads it to find a running nalar.
//
// File format (JSON):
//   {
//     "pid": 12345,
//     "port": 8081,
//     "host": "127.0.0.1",
//     "started_at": 1751558400,
//     "version": "0.4.0",
//     "static_dir": "/run/user/1000/nalar-desktop-webapp-1234" | null
//   }
//
// Writes use the standard "write to <path>.tmp, then rename" pattern for
// atomicity — readers never see a half-written file. Reads return `null`
// for missing files (the desktop interprets this as "no daemon running")
// and silently treat unreadable / corrupt state as absent (stale-state
// recovery is handled by `service start` before this read).

const std = @import("std");
const builtin = @import("builtin");

/// Schema for state.json. The string fields are owned by the caller —
/// callers must hold them alive for as long as the State is in use.
pub const State = struct {
    pid: i32,
    port: u16,
    host: []const u8,
    started_at: i64,
    version: []const u8,
    static_dir: ?[]const u8,
};

pub const StateFileError = error{
    OutOfMemory,
};

/// Read state.json from `path`. Returns `null` for missing files and
/// silently treats parse / IO errors as absent (returns null). Caller is
/// expected to check `pidAlive(state.pid)` before trusting the result.
///
/// Strings in the returned `State` are owned by the caller and must be
/// freed individually (host, version, and any static_dir).
pub fn readStateFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) StateFileError!?State {
    const data = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(64 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return null, // graceful: stale or unreadable → treat as absent
    };
    defer allocator.free(data);

    // Parse into a generic Value tree inside a transient arena. The arena
    // is deinit'd before we return — the strings we dupe below are
    // independent of the parsed Value tree's memory. This avoids leaking
    // the parser's internal allocations (which parseFromSliceLeaky
    // routes to the passed allocator and never reclaims).
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const parsed = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena_alloc,
        data,
        .{},
    ) catch return null;

    return parseState(allocator, parsed) catch null;
}

/// Free slices owned by `state`. Callers that take ownership of the
/// State returned from `readStateFile` MUST call this when done to
/// avoid leaking `host`, `version`, and (optionally) `static_dir`.
pub fn freeState(allocator: std.mem.Allocator, state: State) void {
    allocator.free(state.host);
    allocator.free(state.version);
    if (state.static_dir) |sd| allocator.free(sd);
}

fn parseState(allocator: std.mem.Allocator, v: std.json.Value) !State {
    const obj = v.object;
    const pid_val = obj.get("pid") orelse return error.Malformed;
    const port_val = obj.get("port") orelse return error.Malformed;
    const host_val = obj.get("host") orelse return error.Malformed;
    const started_at_val = obj.get("started_at") orelse return error.Malformed;
    const version_val = obj.get("version") orelse return error.Malformed;
    return .{
        .pid = @intCast(pid_val.integer),
        .port = @intCast(port_val.integer),
        .host = try allocator.dupe(u8, host_val.string),
        .started_at = started_at_val.integer,
        .version = try allocator.dupe(u8, version_val.string),
        .static_dir = if (obj.get("static_dir")) |sd| switch (sd) {
            .string => try allocator.dupe(u8, sd.string),
            .null => null,
            else => null,
        } else null,
    };
}

/// Write state.json atomically. Serializes `state` via std.fmt, writes
/// to <path>.tmp first, then rename(2)s over the destination. POSIX
/// rename is atomic — readers see either the old or new file, never a
/// half-written one.
pub fn writeStateFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    state: State,
) !void {
    // 1. Serialize to a JSON string. static_dir's value is wrapped in
    //    quotes via the `{s}` formatter for strings; null is a literal.
    //    We track ownership via `sd_owned` so the defer cleanup only
    //    frees when we actually allocated. (`"null"` is a literal
    //    *const [N:0]u8 pointing at static read-only memory and MUST
    //    NOT be passed to allocator.free.)
    const sd_field: []const u8 = sd: {
        if (state.static_dir) |sd| {
            const owned = try std.fmt.allocPrint(allocator, "\"{s}\"", .{sd});
            errdefer allocator.free(owned);
            break :sd owned;
        }
        break :sd "null";
    };
    defer if (state.static_dir != null) allocator.free(sd_field);

    const json = try std.fmt.allocPrint(
        allocator,
        "{{\"pid\":{d},\"port\":{d},\"host\":\"{s}\",\"started_at\":{d},\"version\":\"{s}\",\"static_dir\":{s}}}",
        .{
            state.pid,
            state.port,
            state.host,
            state.started_at,
            state.version,
            sd_field,
        },
    );
    defer allocator.free(json);

    // 2. Write to <path>.tmp first. Use @memcpy for the suffix because
    //    std.fs.path.join treats every arg as a path component (and
    //    would produce "<path>/.tmp" with an unwanted slash).
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len + 4 >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..path.len], path);
    @memcpy(path_buf[path.len..][0..4], ".tmp");
    path_buf[path.len + 4] = 0;
    const tmp_path: []const u8 = path_buf[0..path.len + 4];

    // mkdir -p the parent directory of the state file (POSIX only;
    // on Windows, %LOCALAPPDATA% always exists). This lets the daemon
    // be the first nalar process on a fresh $HOME — no manual `mkdir
    // -p ~/.local/state/nalar` required. We use the same
    // componentIterator trick as daemon.zig: each yielded `.path` is the
    // cumulative path-so-far.
    //
    // Use std.c.mkdirat (cross-platform libc wrapper) instead of
    // std.os.linux.mkdirat (Linux syscall only — wrong on macOS where
    // AT.FDCWD is -2 instead of -100).
    if (builtin.os.tag != .windows) {
        if (std.fs.path.dirname(path)) |parent_dir| {
            var iter = std.fs.path.componentIterator(parent_dir);
            while (iter.next()) |component| {
                var dpath_z: [std.fs.max_path_bytes:0]u8 = undefined;
                if (component.path.len >= dpath_z.len) return error.PathTooLong;
                @memcpy(dpath_z[0..component.path.len], component.path);
                dpath_z[component.path.len] = 0;
                const rc = std.c.mkdirat(std.c.AT.FDCWD, &dpath_z, 0o755);
                if (rc != 0) {
                    const err = std.c.errno(rc);
                    if (err != .EXIST) return error.WriteFailed;
                }
            }
        }
    }

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_path, .data = json });
    // std.Io.Dir.renameAbsolute(old_path, new_path, io) — atomic on POSIX
    // (rename(2) is atomic), readers see either the old or new file.
    try std.Io.Dir.renameAbsolute(tmp_path, path, io);
}

pub const PathError = error{
    PathResolutionFailed,
    OutOfMemory,
};

/// Compute the canonical state.json path for the current platform:
///   Linux/macOS: $XDG_STATE_HOME/nalar/state.json, fallback to
///                $HOME/.local/state/nalar/state.json (creates parent dirs).
///   Windows:     %LOCALAPPDATA%\nalar\state.json.
///
/// Caller owns the returned slice. Returns `PathResolutionFailed` if
/// neither XDG_STATE_HOME nor HOME is set (extremely unusual).
pub fn defaultStatePath(allocator: std.mem.Allocator) PathError![]u8 {
    // std.c.getenv returns `?[*:0]u8` (nullable NUL-terminated). For path
    // joining we need a `[]const u8` slice; `std.mem.sliceTo` walks to
    // the NUL terminator and returns a length-counted slice.
    if (builtin.os.tag == .windows) {
        const appdata_z = std.c.getenv("LOCALAPPDATA") orelse
            return error.PathResolutionFailed;
        const appdata = std.mem.sliceTo(appdata_z, 0);
        return std.fs.path.join(allocator, &.{ appdata, "nalar", "state.json" });
    }
    // POSIX: XDG_STATE_HOME wins; fall back to ~/.local/state.
    const home_z = std.c.getenv("HOME") orelse return error.PathResolutionFailed;
    const home = std.mem.sliceTo(home_z, 0);
    if (std.c.getenv("XDG_STATE_HOME")) |xdg_z| {
        const xdg = std.mem.sliceTo(xdg_z, 0);
        return std.fs.path.join(allocator, &.{ xdg, "nalar", "state.json" });
    }
    return std.fs.path.join(allocator, &.{ home, ".local", "state", "nalar", "state.json" });
}