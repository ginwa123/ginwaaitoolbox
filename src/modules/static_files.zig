// src/modules/static_files.zig
//
// Pure-function static-file resolution for the `--static-dir` HTTP handler.
//
// `resolve()` maps a request path (e.g. "/assets/index-abc.js") to a
// concrete file inside the configured root directory, with three guards:
//   1. Path traversal is rejected by substring match ("..") — defense in depth.
//   2. The resolved absolute path must live inside the canonicalized root.
//   3. Directory requests fall back to "index.html" if one exists.
//
// `serve()` is the HTTP-facing entry point (Task 3 will fill it in). It
// currently mirrors the skeleton stub.
const std = @import("std");

/// Configuration for the static-file handler. Constructed once at startup,
/// passed by pointer to every request handler invocation.
pub const StaticDirConfig = struct {
    /// Absolute, canonicalized path to the directory whose contents should be served.
    root_dir: []const u8,
    allocator: std.mem.Allocator,
};

/// Result of a static-file lookup. The handler converts this into an HTTP response.
///
/// Memory ownership: on `.file`, `abs_path` is allocated with `cfg.allocator`
/// and must be freed by the caller (use the same allocator).
pub const LookupResult = union(enum) {
    file: struct {
        abs_path: []const u8,
        mime: []const u8,
        size: u64,
    },
    not_found,
    forbidden,
    not_a_file,
};

// ---------------------------------------------------------------------------
// Mime detection
// ---------------------------------------------------------------------------

const MimeEntry = struct {
    ext: []const u8,
    mime: []const u8,
};

const mime_table = [_]MimeEntry{
    .{ .ext = ".html", .mime = "text/html; charset=utf-8" },
    .{ .ext = ".css", .mime = "text/css; charset=utf-8" },
    .{ .ext = ".js", .mime = "application/javascript; charset=utf-8" },
    .{ .ext = ".mjs", .mime = "application/javascript; charset=utf-8" },
    .{ .ext = ".json", .mime = "application/json; charset=utf-8" },
    .{ .ext = ".svg", .mime = "image/svg+xml" },
    .{ .ext = ".png", .mime = "image/png" },
    .{ .ext = ".jpg", .mime = "image/jpeg" },
    .{ .ext = ".jpeg", .mime = "image/jpeg" },
    .{ .ext = ".gif", .mime = "image/gif" },
    .{ .ext = ".webp", .mime = "image/webp" },
    .{ .ext = ".ico", .mime = "image/x-icon" },
    .{ .ext = ".woff", .mime = "font/woff" },
    .{ .ext = ".woff2", .mime = "font/woff2" },
    .{ .ext = ".ttf", .mime = "font/ttf" },
    .{ .ext = ".map", .mime = "application/json; charset=utf-8" },
    .{ .ext = ".txt", .mime = "text/plain; charset=utf-8" },
};

/// Returns the mime string for `path`'s extension. Uses the last `.` in
/// the path (after the final `/`) as the extension boundary, matching
/// standard practice. Case-insensitive on ASCII. Returns
/// `application/octet-stream` for unknown or missing extensions.
fn mimeForPath(path: []const u8) []const u8 {
    var dot_idx: ?usize = null;
    for (path, 0..) |c, i| {
        if (c == '/') {
            dot_idx = null;
        } else if (c == '.') {
            dot_idx = i;
        }
    }
    const ext_start = dot_idx orelse return "application/octet-stream";
    const ext = path[ext_start..];
    for (mime_table) |entry| {
        if (std.ascii.eqlIgnoreCase(ext, entry.ext)) return entry.mime;
    }
    return "application/octet-stream";
}

/// Returns true when `resolved` lives inside `root` (or equals it).
/// Prevents the false-positive match where `/tmp/abc` is a prefix of
/// `/tmp/abcd/...`.
fn isInsideRoot(root: []const u8, resolved: []const u8) bool {
    if (!std.mem.startsWith(u8, resolved, root)) return false;
    if (resolved.len == root.len) return true;
    return resolved[root.len] == '/';
}

// ---------------------------------------------------------------------------
// resolve()
// ---------------------------------------------------------------------------

/// Resolve a request path (e.g. "/assets/index-abc.js") against the static
/// dir. Returns the resolved file's absolute path, mime type, and size —
/// or an error describing why the request can't be served.
///
/// `io` is passed in by the caller (typically `std.testing.io` from tests
/// or the request's `Io` instance from the HTTP handler). All filesystem
/// operations go through it, per Zig 0.16's Io-based API.
///
/// On `.file`, the returned `abs_path` is allocated with `cfg.allocator`
/// and must be freed by the caller.
pub fn resolve(
    cfg: *const StaticDirConfig,
    io: std.Io,
    request_path: []const u8,
) !LookupResult {
    // 1. Strip query string.
    var clean_path: []const u8 = request_path;
    if (std.mem.indexOfScalar(u8, request_path, '?')) |q| {
        clean_path = request_path[0..q];
    }

    // 2. Reject path traversal (defense in depth — the canonicalization
    //    step below is the real protection).
    if (std.mem.indexOf(u8, clean_path, "..") != null) {
        return .forbidden;
    }

    // 3. Build the candidate relative path inside the static dir.
    var rel_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var rel: []const u8 = undefined;
    if (std.mem.eql(u8, clean_path, "/") or std.mem.eql(u8, clean_path, "")) {
        rel = "index.html";
    } else {
        const stripped = if (clean_path.len > 0 and clean_path[0] == '/') clean_path[1..] else clean_path;
        if (stripped.len == 0) {
            rel = "index.html";
        } else if (stripped[stripped.len - 1] == '/') {
            rel = try std.fmt.bufPrint(&rel_buf, "{s}index.html", .{stripped});
        } else {
            rel = stripped;
        }
    }

    // 4. Open the root dir.
    const root_dir = std.Io.Dir.openDirAbsolute(io, cfg.root_dir, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied, error.PermissionDenied => return .not_found,
        else => return .not_found,
    };
    defer root_dir.close(io);

    // 5. Try to open the candidate as a file. `allow_directory = false`
    //    forces a deterministic `error.IsDir` for directory paths so the
    //    fallback below is unambiguous.
    const file = root_dir.openFile(io, rel, .{ .allow_directory = false }) catch |err| switch (err) {
        error.IsDir, error.FileNotFound => return resolveDirFallback(io, cfg, root_dir, rel),
        else => return .not_found,
    };
    defer file.close(io);

    const stat = file.stat(io) catch return .not_found;

    // 6. Resolve to an absolute path and verify it stays inside the root.
    //    We use `realPathFile` (caller-supplied buffer) + `dupe` (non-sentinel
    //    alloc) so the returned slice can be `allocator.free`'d by the caller
    //    with the exact byte count — `realPathFileAlloc` would give a `[:0]u8`
    //    whose size info is lost when the slice is coerced to `[]const u8`.
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try root_dir.realPathFile(io, rel, &path_buf);
    const resolved = try cfg.allocator.dupe(u8, path_buf[0..n]);
    errdefer cfg.allocator.free(resolved);

    if (!isInsideRoot(cfg.root_dir, resolved)) return .forbidden;

    return .{ .file = .{
        .abs_path = resolved,
        .mime = mimeForPath(resolved),
        .size = stat.size,
    } };
}

/// Try to resolve `rel` as a directory and serve its `index.html`. Returns
/// `.not_a_file` if the directory has no index.html; `.forbidden` if the
/// index.html would escape the root; `.file` with the index's metadata
/// on success.
fn resolveDirFallback(
    io: std.Io,
    cfg: *const StaticDirConfig,
    root_dir: std.Io.Dir,
    rel: []const u8,
) !LookupResult {
    const sub = root_dir.openDir(io, rel, .{}) catch return .not_a_file;
    defer sub.close(io);

    const idx = sub.openFile(io, "index.html", .{}) catch return .not_a_file;
    defer idx.close(io);

    const idx_stat = idx.stat(io) catch return .not_a_file;

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try sub.realPathFile(io, "index.html", &path_buf);
    const idx_abs = try cfg.allocator.dupe(u8, path_buf[0..n]);
    errdefer cfg.allocator.free(idx_abs);

    if (!isInsideRoot(cfg.root_dir, idx_abs)) return .forbidden;

    return .{ .file = .{
        .abs_path = idx_abs,
        .mime = mimeForPath(idx_abs),
        .size = idx_stat.size,
    } };
}

// ---------------------------------------------------------------------------
// serve() — placeholder for Task 3
// ---------------------------------------------------------------------------

/// Send a static file as an HTTP response.
///
/// Doesn't mutate `cfg` — all writes go to the `writer` parameter. Task 3
/// will likely swap `writer` for the real httpz response type; this signature
/// is the placeholder shape we expect.
/// (Stub for now; fleshed out in Task 3.)
pub fn serve(
    cfg: *const StaticDirConfig,
    request_path: []const u8,
    range_header: ?[]const u8,
    writer: std.Io.Writer,
) !LookupResult {
    _ = cfg;
    _ = request_path;
    _ = range_header;
    _ = writer;
    return .not_found;
}
