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
    /// Optional SPA fallback prefix (e.g. `"/app"`).
    ///
    /// When set (non-null), missing paths that start with this prefix
    /// (the prefix itself, or `<prefix>/<anything>`) AND don't look
    /// like asset requests (no file extension) are served as the
    /// root directory's `index.html` — the SPA shell. This is the
    /// standard HTML5-history SPA fallback (nginx `try_files $uri
    /// /index.html`, Vite's history fallback). It's needed so
    /// reloading the page at `<prefix>/chat/session_xyz` doesn't
    /// 404, since the SPA build output has no such file on disk —
    /// only `index.html` + `assets/`.
    ///
    /// When null (default), no SPA fallback occurs — missing paths
    /// return 404 as before. This preserves backward compatibility
    /// for callers that don't serve an SPA (e.g. serving plain docs)
    /// or that want hard 404s on missing paths.
    ///
    /// Matching is prefix-anchored: `<prefix>` itself OR `<prefix>/<rest>`.
    /// `prefix` MUST start with `/`. `<prefix>x` (no separator) does NOT
    /// match — `/app` doesn't accidentally swallow `/apple`.
    ///
    /// Match examples (with prefix = "/app"):
    ///   /app             → matches (exact)
    ///   /app/settings    → matches (prefix + "/")
    ///   /app/chat/xyz    → matches (prefix + "/")
    ///   /apple           → does NOT match
    ///   /api/app         → does NOT match
    spa_fallback_prefix: ?[]const u8 = null,
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
        /// Last-modified time, used for content-derived ETag generation.
        /// Two files with identical byte counts get distinct ETags because
        /// their mtimes almost always differ, avoiding browser cache poisoning
        /// when the size alone would collide.
        mtime: std.Io.Timestamp,
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
/// `/tmp/abcd/...`. Accepts both `/` and `\` as the path separator so
/// this works on Windows (where realPath returns backslash-separated
/// paths) AND on POSIX (where realPath returns forward-slash paths).
fn isInsideRoot(root: []const u8, resolved: []const u8) bool {
    if (!std.mem.startsWith(u8, resolved, root)) return false;
    if (resolved.len == root.len) return true;
    const next_char = resolved[root.len];
    return next_char == '/' or next_char == '\\';
}

/// Returns true if the request path looks like a static ASSET (i.e. the
/// final path component has a file extension). Used by the SPA fallback
/// inside `resolve()` to decide whether a missing path is a 404 or a
/// missing client-side route that should be served as `index.html`.
///
/// Examples:
///   /app                  → false (route — fall back to index.html)
///   /app/settings         → false (route)
///   /app/chat/session_xyz → false (route — no `.` after the last `/`)
///   /assets/index-Abc.js  → true  (asset — 404 if missing)
///   /favicon.ico          → true  (asset)
///
/// The check is intentionally simple: look for the last `/`, then check
/// whether the bytes after it contain a `.`. This matches the
/// nginx `try_files $uri /index.html` convention (and Vite's SPA
/// fallback in dev/prod). It is NOT a comprehensive mimetype sniff —
/// `/foo.bar/baz` has a `.` before the last `/` but the final
/// component is `baz`, which has no `.` and is correctly treated as a
/// route. The "after the last `/`" framing catches that.
fn looksLikeAssetPath(path: []const u8) bool {
    const last_slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return false;
    const after_last_slash = path[last_slash + 1 ..];
    return std.mem.indexOfScalar(u8, after_last_slash, '.') != null;
}

/// Returns true if `clean_path` is `<prefix>` or `<prefix>/...`. The
/// boundary check (prefix-anchored) prevents `/app` from matching
/// `/apple`, `/api/foo`, etc. — only routes the SPA actually owns.
///
/// Examples (prefix = "/app"):
///   /app            → true  (exact)
///   /app/settings   → true  (prefix + "/")
///   /app/chat/xyz   → true  (prefix + "/")
///   /apple          → false (no separator after /app)
///   /api/app        → false (no separator after /app)
///   /               → false
fn pathMatchesSpaPrefix(clean_path: []const u8, prefix: []const u8) bool {
    if (std.mem.eql(u8, clean_path, prefix)) return true;
    if (!std.mem.startsWith(u8, clean_path, prefix)) return false;
    // After the prefix, the next char must be '/' — otherwise we'd
    // match unrelated names like `/apple` against prefix `/app`.
    const next = clean_path[prefix.len];
    return next == '/';
}

// ---------------------------------------------------------------------------
// resolve()
// ---------------------------------------------------------------------------

/// Buffer size for streaming file responses. 64 KB matches a typical
/// filesystem read-ahead and keeps memory usage bounded for large files.
const FILE_BUF_SIZE: usize = 64 * 1024;

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
        // The path resolves to an actual directory — serve that dir's
        // index.html (the canonical "directory request" path matching
        // what nginx's `index` directive does).
        error.IsDir => return resolveDirIndexHtml(io, cfg, root_dir, rel),
        // The path doesn't exist as a file or directory. Decide:
        //   - Asset-style path (has a file extension in the final
        //     segment, e.g. /missing.js): return 404. A missing JS/CSS
        //     bundle is genuinely an error and should not be silently
        //     masked by index.html.
        //   - Route-style path UNDER the configured SPA prefix
        //     (e.g. /app/settings when `spa_fallback_prefix = "/app"`):
        //     serve the root's index.html so the SPA's client-side
        //     router can take over. This is the standard SPA fallback
        //     (nginx `try_files $uri /index.html`, Vite's history
        //     fallback, http-server `-P` proxy-fallback). Without it,
        //     reloading the page at /app/settings 404s because there
        //     is no `/app/settings` file on disk — only `index.html`
        //     exists, and the JS app's router decides what to render.
        //   - Anything else (e.g. /api/not-a-route, /test/foo): 404.
        //     The API/operational routers handle their own paths; if
        //     they didn't match, the path is genuinely unknown and a
        //     404 is correct.
        error.FileNotFound => {
            if (looksLikeAssetPath(clean_path)) return .not_found;
            if (cfg.spa_fallback_prefix) |prefix| {
                if (pathMatchesSpaPrefix(clean_path, prefix)) {
                    return resolveRootIndexHtml(io, cfg, root_dir);
                }
            }
            return .not_found;
        },
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

    // Path-traversal defense: if `realPathFile` resolved to a path
    // outside the root (e.g. via symlinks), reject as forbidden AND
    // free the duplicated path (the errdefer above only fires on
    // error, not on regular returns like this one — this is a
    // classic Zig pitfall; the prior code leaked `resolved` here).
    if (!isInsideRoot(cfg.root_dir, resolved)) {
        cfg.allocator.free(resolved);
        return .forbidden;
    }

    return .{ .file = .{
        .abs_path = resolved,
        .mime = mimeForPath(resolved),
        .size = stat.size,
        .mtime = stat.mtime,
    } };
}

/// Try to resolve `rel` as a directory and serve its `index.html`. Returns
/// `.not_a_file` if the directory has no index.html; `.forbidden` if the
/// index.html would escape the root; `.file` with the index's metadata
/// on success.
fn resolveDirIndexHtml(
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
        .mtime = idx_stat.mtime,
    } };
}

/// SPA fallback: serve the ROOT directory's `index.html`. Invoked when a
/// path doesn't resolve to a real file or directory AND doesn't look
/// like an asset request (no extension). This is the standard SPA
/// fallback pattern (nginx `try_files $uri /index.html`, Vite's
/// history fallback). Returns `.not_found` if the root has no
/// `index.html` — in that case, the SPA can't actually serve anything,
/// and a 404 is correct.
fn resolveRootIndexHtml(
    io: std.Io,
    cfg: *const StaticDirConfig,
    root_dir: std.Io.Dir,
) !LookupResult {
    const idx = root_dir.openFile(io, "index.html", .{}) catch return .not_found;
    defer idx.close(io);

    const idx_stat = idx.stat(io) catch return .not_found;

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try root_dir.realPathFile(io, "index.html", &path_buf);
    const idx_abs = try cfg.allocator.dupe(u8, path_buf[0..n]);
    errdefer cfg.allocator.free(idx_abs);

    // Defense in depth: even though "index.html" is a fixed name inside
    // the root_dir handle, a symlink in the root pointing outside the
    // configured root_dir would be served here. `isInsideRoot` rejects.
    if (!isInsideRoot(cfg.root_dir, idx_abs)) return .forbidden;

    return .{ .file = .{
        .abs_path = idx_abs,
        .mime = mimeForPath(idx_abs),
        .size = idx_stat.size,
        .mtime = idx_stat.mtime,
    } };
}

// ---------------------------------------------------------------------------
// parseRange() — HTTP `Range:` header parser
// ---------------------------------------------------------------------------

/// Parsed byte range from an HTTP `Range: bytes=...` header.
pub const ByteRange = struct {
    start: u64,
    end: u64,
};

/// Parse an HTTP `Range:` header value into a `ByteRange`, validating against
/// `file_size`. Returns `null` for any malformed, unsupported, or out-of-bounds
/// spec — the caller should fall back to a full 200 response in that case.
///
/// Recognized forms (per RFC 9110 §14.1.2):
///   * `bytes=START-END`     — closed range
///   * `bytes=START-`        — open-ended (resolves END to file_size-1)
///   * `bytes=-SUFFIX`       — last SUFFIX bytes of the file
///
/// Returns `null` for:
///   * missing or wrong-case `bytes=` prefix
///   * missing dash separator
///   * non-numeric bytes
///   * empty `bytes=` (no digits at all)
///   * suffix of 0 (no bytes requested)
///   * suffix larger than file_size
///   * closed range where END >= file_size or START > END
///
/// The function is intentionally strict: anything ambiguous is rejected
/// rather than silently coerced, because the caller's fallback path
/// (a full 200 response) is always correct.
pub fn parseRange(header: []const u8, file_size: u64) !?ByteRange {
    if (!std.mem.startsWith(u8, header, "bytes=")) return null;
    const spec = header["bytes=".len..];
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return null;
    const start_s = spec[0..dash];
    const end_s = spec[dash + 1..];

    // Suffix form: bytes=-SUFFIX  (the first half is empty)
    if (start_s.len == 0) {
        if (end_s.len == 0) return null;
        const suffix = std.fmt.parseInt(u64, end_s, 10) catch return null;
        if (suffix == 0 or suffix > file_size) return null;
        return .{ .start = file_size - suffix, .end = file_size - 1 };
    }

    // Closed or open-ended form: bytes=START-END or bytes=START-
    const start = std.fmt.parseInt(u64, start_s, 10) catch return null;
    const end = if (end_s.len == 0) file_size - 1 else std.fmt.parseInt(u64, end_s, 10) catch return null;
    if (start > end or end >= file_size) return null;
    return .{ .start = start, .end = end };
}

// ---------------------------------------------------------------------------
// serve() — HTTP response writer
// ---------------------------------------------------------------------------

/// Send a static file as an HTTP response.
///
/// Doesn't mutate `cfg` — all writes go to the `writer` parameter. On
/// `.file`, frees the abs_path allocated by `resolve()`.
///
/// Supports HTTP/1.1 byte-range requests: if `range_header` parses to a valid
/// range, responds with 206 Partial Content and the requested slice.
/// Otherwise responds with 200 OK and the full file body.
///
/// 404 / 403 are returned for the corresponding `LookupResult` variants;
/// these are short text bodies with no Content-Range, no ETag.
pub fn serve(
    cfg: *const StaticDirConfig,
    io: std.Io,
    request_path: []const u8,
    range_header: ?[]const u8,
    writer: std.Io.Writer,
) !void {
    const lookup = try resolve(cfg, io, request_path);
    switch (lookup) {
        .not_found, .not_a_file => {
            const body = "Not Found";
            try writer.writeAll("HTTP/1.1 404 Not Found\r\n");
            try writer.print("Content-Length: {d}\r\n", .{body.len});
            try writer.writeAll("Content-Type: text/plain; charset=utf-8\r\n");
            try writer.writeAll("\r\n");
            try writer.writeAll(body);
        },
        .forbidden => {
            const body = "Forbidden";
            try writer.writeAll("HTTP/1.1 403 Forbidden\r\n");
            try writer.print("Content-Length: {d}\r\n", .{body.len});
            try writer.writeAll("Content-Type: text/plain; charset=utf-8\r\n");
            try writer.writeAll("\r\n");
            try writer.writeAll(body);
        },
        .file => |f| {
            defer cfg.allocator.free(f.abs_path);

            // Content-derived ETag: combines file size and mtime so two
            // same-size files (common with minified JS/CSS) get distinct ETags
            // and don't trigger browser cache poisoning on size collision.
            const etag = try std.fmt.allocPrint(cfg.allocator, "\"x-{x}-{x}\"", .{ f.size, f.mtime.nanoseconds });
            defer cfg.allocator.free(etag);

            if (range_header) |rh| {
                if (try parseRange(rh, f.size)) |range| {
                    try writer.writeAll("HTTP/1.1 206 Partial Content\r\n");
                    try writer.print("Content-Range: bytes {d}-{d}/{d}\r\n", .{ range.start, range.end, f.size });
                    const content_length: u64 = range.end - range.start + 1;
                    try writer.print("Content-Length: {d}\r\n", .{content_length});
                    try writer.print("Content-Type: {s}\r\n", .{f.mime});
                    try writer.print("ETag: {s}\r\n", .{etag});
                    try writer.writeAll("Cache-Control: public, max-age=3600\r\n");
                    try writer.writeAll("\r\n");
                    try writeFileRange(io, f.abs_path, range.start, range.end, writer);
                    return;
                }
            }

            try writer.writeAll("HTTP/1.1 200 OK\r\n");
            try writer.print("Content-Length: {d}\r\n", .{f.size});
            try writer.print("Content-Type: {s}\r\n", .{f.mime});
            try writer.print("ETag: {s}\r\n", .{etag});
            try writer.writeAll("Cache-Control: public, max-age=3600\r\n");
            try writer.writeAll("\r\n");
            try writeFileFull(io, f.abs_path, writer);
        },
    }
}

/// Stream the entire file at `abs_path` to `writer`.
///
/// Uses `readPositionalAll` (not seek + read) — that's the Zig 0.16 idiom
/// for positional reads, and it's the path that's safe in Io.Threaded's
/// blocking recv model.
fn writeFileFull(io: std.Io, abs_path: []const u8, writer: std.Io.Writer) !void {
    const file = try std.Io.Dir.openFileAbsolute(io, abs_path, .{});
    defer file.close(io);
    var buf: [FILE_BUF_SIZE]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try file.readPositionalAll(io, &buf, offset);
        if (n == 0) break;
        try writer.writeAll(buf[0..n]);
        offset += n;
    }
}

/// Stream the byte range `[start, end]` (inclusive on both ends) of the
/// file at `abs_path` to `writer`. Caller is responsible for ensuring
/// `start <= end < file_size`.
fn writeFileRange(
    io: std.Io,
    abs_path: []const u8,
    start: u64,
    end: u64,
    writer: std.Io.Writer,
) !void {
    const file = try std.Io.Dir.openFileAbsolute(io, abs_path, .{});
    defer file.close(io);
    var remaining: u64 = end - start + 1;
    var offset: u64 = start;
    var buf: [FILE_BUF_SIZE]u8 = undefined;
    while (remaining > 0) {
        const to_read: usize = @intCast(@min(remaining, buf.len));
        const n = try file.readPositionalAll(io, buf[0..to_read], offset);
        if (n == 0) break;
        try writer.writeAll(buf[0..n]);
        offset += n;
        remaining -= n;
    }
}
