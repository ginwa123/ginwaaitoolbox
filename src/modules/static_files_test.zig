// src/modules/static_files_test.zig
//
// Tests for src/modules/static_files.zig's `resolve()` function.
//
// The function takes a `StaticDirConfig` and a request path, and returns a
// `LookupResult` describing what (if anything) should be served. The tests
// exercise the path-sandbox logic, mime detection, and the fallback to
// `index.html` for directory requests.
//
// Zig 0.16 API notes:
//   * `std.testing.tmpDir(opts)` takes `Io.Dir.OpenOptions`, returns a
//     `TmpDir` with a `dir: Io.Dir` handle and a `cleanup()` method.
//   * `Io.Dir.realPath(io, out_buffer)` returns the canonicalized absolute
//     path of a dir as a length-N byte slice (no sentinel). We use this in
//     `setupRoot` so `allocator.free` matches the alloc size exactly.
//   * File I/O methods all take an explicit `io: std.Io` parameter.
//   * `Io.Dir.openFile(io, sub_path, .{ .allow_directory = false })` makes
//     `error.IsDir` the deterministic return for directory paths.
//
// Memory ownership: on `.file`, `result.file.abs_path` is allocated with
// the cfg's allocator and must be freed by the caller. Each test that
// expects `.file` does `defer allocator.free(result.file.abs_path);`.

const std = @import("std");
const static_files = @import("static_files.zig");
const testing = std.testing;

/// Per-test environment: a fresh temp directory plus its realpath so the
/// sandbox check inside `resolve()` has an absolute, canonical root to
/// compare against.
const TestEnv = struct {
    tmp_dir: std.testing.TmpDir,
    root_abs: []const u8,
    io: std.Io,

    fn deinit(self: *TestEnv, allocator: std.mem.Allocator) void {
        allocator.free(self.root_abs);
        self.tmp_dir.cleanup();
    }
};

fn setupRoot(allocator: std.mem.Allocator) !TestEnv {
    var tmp = std.testing.tmpDir(.{});
    // Use `realPath` (non-sentinel, caller buffer) + `dupe` so the free
    // size matches the alloc size. `realPathFileAlloc` would give `[:0]u8`
    // which loses the sentinel when stored in a `[]const u8` field.
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &path_buf);
    const abs = try allocator.dupe(u8, path_buf[0..n]);
    return .{ .tmp_dir = tmp, .root_abs = abs, .io = testing.io };
}

// ---------------------------------------------------------------------------
// Path resolution behavior
// ---------------------------------------------------------------------------

test "resolve: index.html for root path" {
    const allocator = testing.allocator;
    var env = try setupRoot(allocator);
    defer env.deinit(allocator);
    // Create an empty index.html so the root path resolves to a real file
    const f = try env.tmp_dir.dir.createFile(env.io, "index.html", .{});
    defer f.close(env.io);
    const cfg = static_files.StaticDirConfig{ .root_dir = env.root_abs, .allocator = allocator };
    const result = try static_files.resolve(&cfg, env.io, "/");
    defer if (result == .file) allocator.free(result.file.abs_path);
    try testing.expect(result == .file);
    try testing.expectEqualStrings("text/html; charset=utf-8", result.file.mime);
    try testing.expectEqual(@as(u64, 0), result.file.size);
}

test "resolve: returns forbidden for path traversal attempt" {
    const allocator = testing.allocator;
    var env = try setupRoot(allocator);
    defer env.deinit(allocator);

    const cfg = static_files.StaticDirConfig{ .root_dir = env.root_abs, .allocator = allocator };
    const result = try static_files.resolve(&cfg, env.io, "/../../etc/passwd");
    try testing.expect(result == .forbidden);
}

test "resolve: returns file info for a real file" {
    const allocator = testing.allocator;
    var env = try setupRoot(allocator);
    defer env.deinit(allocator);

    {
        const f = try env.tmp_dir.dir.createFile(env.io, "test.txt", .{});
        defer f.close(env.io);
        try f.writeStreamingAll(env.io, "hello world");
    }

    const cfg = static_files.StaticDirConfig{ .root_dir = env.root_abs, .allocator = allocator };
    const result = try static_files.resolve(&cfg, env.io, "/test.txt");
    defer if (result == .file) allocator.free(result.file.abs_path);

    try testing.expect(result == .file);
    try testing.expectEqualStrings("text/plain; charset=utf-8", result.file.mime);
    try testing.expectEqual(@as(u64, 11), result.file.size);
}

test "resolve: returns not_a_file for a directory without index.html" {
    const allocator = testing.allocator;
    var env = try setupRoot(allocator);
    defer env.deinit(allocator);

    try env.tmp_dir.dir.createDirPath(env.io, "subdir");

    const cfg = static_files.StaticDirConfig{ .root_dir = env.root_abs, .allocator = allocator };
    const result = try static_files.resolve(&cfg, env.io, "/subdir");
    try testing.expect(result == .not_a_file);
}

test "resolve: returns file for a directory with index.html" {
    const allocator = testing.allocator;
    var env = try setupRoot(allocator);
    defer env.deinit(allocator);

    try env.tmp_dir.dir.createDirPath(env.io, "subdir");
    {
        const f = try env.tmp_dir.dir.createFile(env.io, "subdir/index.html", .{});
        defer f.close(env.io);
        try f.writeStreamingAll(env.io, "<html></html>");
    }

    const cfg = static_files.StaticDirConfig{ .root_dir = env.root_abs, .allocator = allocator };
    const result = try static_files.resolve(&cfg, env.io, "/subdir");
    defer if (result == .file) allocator.free(result.file.abs_path);

    try testing.expect(result == .file);
    try testing.expectEqualStrings("text/html; charset=utf-8", result.file.mime);
}

// ---------------------------------------------------------------------------
// SPA fallback — paths under `spa_fallback_prefix` that don't resolve to
// a real file or directory AND don't have a file extension are served as
// the root index.html so the SPA's router can take over. This is the
// standard HTML5-history SPA fallback for SPAs (Vue/React/etc. using
// `createWebHistory` or `BrowserRouter`).
// ---------------------------------------------------------------------------

test "resolve SPA: returns root index.html for a route-style path like /app" {
    // Mirrors the bug: reloading the desktop app at `/app/settings` 404'd
    // because the SPA build output has no `/app/settings` file, only
    // `index.html` + `assets/`. After the fix, this returns the same
    // index.html that `/` returns, so the Vue Router can take over.
    const allocator = testing.allocator;
    var env = try setupRoot(allocator);
    defer env.deinit(allocator);

    {
        const f = try env.tmp_dir.dir.createFile(env.io, "index.html", .{});
        defer f.close(env.io);
        try f.writeStreamingAll(env.io, "<!doctype html><title>SPA</title>");
    }

    const cfg = static_files.StaticDirConfig{
        .root_dir = env.root_abs,
        .allocator = allocator,
        .spa_fallback_prefix = "/app",
    };
    const result = try static_files.resolve(&cfg, env.io, "/app");
    defer if (result == .file) allocator.free(result.file.abs_path);

    try testing.expect(result == .file);
    try testing.expectEqualStrings("text/html; charset=utf-8", result.file.mime);
}

test "resolve SPA: returns root index.html for nested route /app/chat/session_xyz" {
    const allocator = testing.allocator;
    var env = try setupRoot(allocator);
    defer env.deinit(allocator);

    {
        const f = try env.tmp_dir.dir.createFile(env.io, "index.html", .{});
        defer f.close(env.io);
        try f.writeStreamingAll(env.io, "<!doctype html><title>SPA</title>");
    }

    const cfg = static_files.StaticDirConfig{
        .root_dir = env.root_abs,
        .allocator = allocator,
        .spa_fallback_prefix = "/app",
    };
    const result = try static_files.resolve(&cfg, env.io, "/app/chat/session_xyz");
    defer if (result == .file) allocator.free(result.file.abs_path);

    try testing.expect(result == .file);
    try testing.expectEqualStrings("text/html; charset=utf-8", result.file.mime);
}

test "resolve SPA: second prefix serves index.html for /login (refresh-safe)" {
    // The standalone login page lives outside /app but from the same
    // index.html. Refreshing at /login?redirect=/app (query is stripped
    // before matching, so this is /login) must serve the SPA shell,
    // not 404.
    const allocator = testing.allocator;
    var env = try setupRoot(allocator);
    defer env.deinit(allocator);

    {
        const f = try env.tmp_dir.dir.createFile(env.io, "index.html", .{});
        defer f.close(env.io);
        try f.writeStreamingAll(env.io, "<!doctype html><title>SPA</title>");
    }

    const cfg = static_files.StaticDirConfig{
        .root_dir = env.root_abs,
        .allocator = allocator,
        .spa_fallback_prefix = "/app",
        .spa_fallback_prefix2 = "/login",
    };
    const result = try static_files.resolve(&cfg, env.io, "/login");
    defer if (result == .file) allocator.free(result.file.abs_path);

    try testing.expect(result == .file);
    try testing.expectEqualStrings("text/html; charset=utf-8", result.file.mime);
}

test "resolve SPA: /login still 404s when second prefix is unset" {
    // prefix2 defaults to null — callers that only set /app keep the
    // old behavior for /login.
    const allocator = testing.allocator;
    var env = try setupRoot(allocator);
    defer env.deinit(allocator);

    {
        const f = try env.tmp_dir.dir.createFile(env.io, "index.html", .{});
        defer f.close(env.io);
        try f.writeStreamingAll(env.io, "<!doctype html>");
    }

    const cfg = static_files.StaticDirConfig{
        .root_dir = env.root_abs,
        .allocator = allocator,
        .spa_fallback_prefix = "/app",
    };
    try testing.expect((try static_files.resolve(&cfg, env.io, "/login")) == .not_found);
}

test "resolve SPA: still returns 404 for missing assets that DO have an extension" {
    // The SPA fallback must NOT silently mask missing JS/CSS/etc. as
    // index.html — that would hide real build/deploy bugs.
    const allocator = testing.allocator;
    var env = try setupRoot(allocator);
    defer env.deinit(allocator);

    // index.html exists, but /missing.js does NOT.
    {
        const f = try env.tmp_dir.dir.createFile(env.io, "index.html", .{});
        defer f.close(env.io);
        try f.writeStreamingAll(env.io, "<!doctype html>");
    }

    const cfg = static_files.StaticDirConfig{
        .root_dir = env.root_abs,
        .allocator = allocator,
        .spa_fallback_prefix = "/app",
    };
    const result = try static_files.resolve(&cfg, env.io, "/assets/missing.js");
    try testing.expect(result == .not_found);
}

test "resolve SPA: returns not_found when root has no index.html" {
    // If the SPA isn't even deployed, route-style paths under the prefix
    // should 404 (not serve some garbage file). The fallback only kicks
    // in when a real index.html exists.
    const allocator = testing.allocator;
    var env = try setupRoot(allocator);
    defer env.deinit(allocator);

    // No index.html created.

    const cfg = static_files.StaticDirConfig{
        .root_dir = env.root_abs,
        .allocator = allocator,
        .spa_fallback_prefix = "/app",
    };
    const result = try static_files.resolve(&cfg, env.io, "/app/settings");
    try testing.expect(result == .not_found);
}

test "resolve SPA: real file with extension still wins over fallback" {
    // Sanity: if a file with the requested name DOES exist (has an
    // extension AND is present), serve it directly — don't fall back.
    // This guards against the fallback accidentally swallowing real
    // asset requests because of a future regression.
    const allocator = testing.allocator;
    var env = try setupRoot(allocator);
    defer env.deinit(allocator);

    {
        const f = try env.tmp_dir.dir.createFile(env.io, "robots.txt", .{});
        defer f.close(env.io);
        try f.writeStreamingAll(env.io, "User-agent: *");
    }
    {
        const f = try env.tmp_dir.dir.createFile(env.io, "index.html", .{});
        defer f.close(env.io);
        try f.writeStreamingAll(env.io, "<!doctype html>");
    }

    const cfg = static_files.StaticDirConfig{
        .root_dir = env.root_abs,
        .allocator = allocator,
        .spa_fallback_prefix = "/app",
    };
    const result = try static_files.resolve(&cfg, env.io, "/robots.txt");
    defer if (result == .file) allocator.free(result.file.abs_path);

    try testing.expect(result == .file);
    try testing.expectEqualStrings("text/plain; charset=utf-8", result.file.mime);
}

test "resolve SPA: paths OUTSIDE the prefix still 404 (no regression for /api, /test, etc.)" {
    // Critical: the SPA fallback must NOT catch arbitrary unregistered
    // paths. `/api/health` (not a registered API route) and similar
    // should 404, not silently serve index.html — that would mask real
    // API bugs as "the SPA shell is fine".
    const allocator = testing.allocator;
    var env = try setupRoot(allocator);
    defer env.deinit(allocator);

    {
        const f = try env.tmp_dir.dir.createFile(env.io, "index.html", .{});
        defer f.close(env.io);
        try f.writeStreamingAll(env.io, "<!doctype html>");
    }

    const cfg = static_files.StaticDirConfig{
        .root_dir = env.root_abs,
        .allocator = allocator,
        .spa_fallback_prefix = "/app",
    };

    // Each is a route-style path (no extension) but OUTSIDE the
    // configured /app prefix — all should 404.
    const cases = [_][]const u8{
        "/api/health",          // API-style
        "/api/not-a-real-path", // API-style, unregistered
        "/health",              // operational
        "/test/missing",        // test endpoints
        "/something-else",      // unrelated path
        "/apple",               // would-be /app if not boundary-anchored
    };
    for (cases) |path| {
        const r = try static_files.resolve(&cfg, env.io, path);
        try testing.expect(r == .not_found);
    }
}

test "resolve SPA: opt-out via spa_fallback_prefix = null (default behavior)" {
    // Backward compatibility: callers that don't set the prefix get the
    // old "404 for any missing path" behavior — no silent index.html
    // fallback. This guards the 3 non-SPA use cases (docs sites, etc.).
    const allocator = testing.allocator;
    var env = try setupRoot(allocator);
    defer env.deinit(allocator);

    {
        const f = try env.tmp_dir.dir.createFile(env.io, "index.html", .{});
        defer f.close(env.io);
        try f.writeStreamingAll(env.io, "<!doctype html>");
    }

    // Default config: spa_fallback_prefix = null.
    const cfg = static_files.StaticDirConfig{
        .root_dir = env.root_abs,
        .allocator = allocator,
    };

    // Without the prefix, "/app" and "/app/settings" both 404 even
    // though index.html exists — the old behavior.
    try testing.expect((try static_files.resolve(&cfg, env.io, "/app")) == .not_found);
    try testing.expect((try static_files.resolve(&cfg, env.io, "/app/settings")) == .not_found);
    // "/" still works (always serves index.html via the existing
    // root-path branch).
    const root = try static_files.resolve(&cfg, env.io, "/");
    defer if (root == .file) allocator.free(root.file.abs_path);
    try testing.expect(root == .file);
}

// ---------------------------------------------------------------------------
// Mime detection
// ---------------------------------------------------------------------------

test "resolve: mime types for common web extensions" {
    const allocator = testing.allocator;
    var env = try setupRoot(allocator);
    defer env.deinit(allocator);

    const cases = .{
        .{ "f.html", "text/html; charset=utf-8" },
        .{ "f.css", "text/css; charset=utf-8" },
        .{ "f.js", "application/javascript; charset=utf-8" },
        .{ "f.mjs", "application/javascript; charset=utf-8" },
        .{ "f.json", "application/json; charset=utf-8" },
        .{ "f.svg", "image/svg+xml" },
        .{ "f.png", "image/png" },
        .{ "f.jpg", "image/jpeg" },
        .{ "f.jpeg", "image/jpeg" },
        .{ "f.gif", "image/gif" },
        .{ "f.webp", "image/webp" },
        .{ "f.ico", "image/x-icon" },
        .{ "f.woff", "font/woff" },
        .{ "f.woff2", "font/woff2" },
        .{ "f.ttf", "font/ttf" },
        .{ "f.map", "application/json; charset=utf-8" },
        .{ "f.txt", "text/plain; charset=utf-8" },
    };
    inline for (cases) |case| {
        {
            const f = try env.tmp_dir.dir.createFile(env.io, case[0], .{});
            defer f.close(env.io);
            try f.writeStreamingAll(env.io, "x");
        }
        const cfg = static_files.StaticDirConfig{ .root_dir = env.root_abs, .allocator = allocator };
        const result = try static_files.resolve(&cfg, env.io, "/" ++ case[0]);
        defer if (result == .file) allocator.free(result.file.abs_path);

        try testing.expect(result == .file);
        try testing.expectEqualStrings(case[1], result.file.mime);
    }
}

test "resolve: case-insensitive extension match" {
    const allocator = testing.allocator;
    var env = try setupRoot(allocator);
    defer env.deinit(allocator);

    {
        const f = try env.tmp_dir.dir.createFile(env.io, "a.HTML", .{});
        defer f.close(env.io);
        try f.writeStreamingAll(env.io, "x");
    }

    const cfg = static_files.StaticDirConfig{ .root_dir = env.root_abs, .allocator = allocator };
    const result = try static_files.resolve(&cfg, env.io, "/a.HTML");
    defer if (result == .file) allocator.free(result.file.abs_path);

    try testing.expect(result == .file);
    try testing.expectEqualStrings("text/html; charset=utf-8", result.file.mime);
}

// ---------------------------------------------------------------------------
// parseRange() — HTTP `Range:` header parser
// ---------------------------------------------------------------------------

test "parseRange: full range bytes=0-99 with file_size=200" {
    const result = try static_files.parseRange("bytes=0-99", 200);
    try testing.expect(result != null);
    try testing.expectEqual(@as(u64, 0), result.?.start);
    try testing.expectEqual(@as(u64, 99), result.?.end);
}

test "parseRange: open-ended range bytes=0- with file_size=200" {
    const result = try static_files.parseRange("bytes=0-", 200);
    try testing.expect(result != null);
    try testing.expectEqual(@as(u64, 0), result.?.start);
    try testing.expectEqual(@as(u64, 199), result.?.end);
}

test "parseRange: zero-length file rejects every range form" {
    // `bytes=0-` on an empty file used to compute `0u64 - 1` before the
    // bounds check ran, which is an unsigned-underflow safety panic and
    // aborted the process. Any HTTP client could trigger it with a single
    // Range header against any empty static asset.
    for ([_][]const u8{ "bytes=0-", "bytes=0-0", "bytes=0-99", "bytes=-1", "bytes=-50", "bytes=5-" }) |header| {
        const result = try static_files.parseRange(header, 0);
        try testing.expect(result == null);
    }
}

test "parseRange: single-byte file open-ended returns byte 0" {
    // file_size == 1 is the smallest non-zero size; `file_size - 1` is
    // legal here and must still produce a usable range.
    const result = try static_files.parseRange("bytes=0-", 1);
    try testing.expect(result != null);
    try testing.expectEqual(@as(u64, 0), result.?.start);
    try testing.expectEqual(@as(u64, 0), result.?.end);
}

test "parseRange: suffix range bytes=-50 with file_size=200" {
    const result = try static_files.parseRange("bytes=-50", 200);
    try testing.expect(result != null);
    try testing.expectEqual(@as(u64, 150), result.?.start);
    try testing.expectEqual(@as(u64, 199), result.?.end);
}

test "parseRange: invalid suffix bytes=-0" {
    const result = try static_files.parseRange("bytes=-0", 200);
    try testing.expect(result == null);
}

test "parseRange: malformed bytes=abc-def" {
    const result = try static_files.parseRange("bytes=abc-def", 200);
    try testing.expect(result == null);
}

test "parseRange: end out of bounds bytes=0-999" {
    const result = try static_files.parseRange("bytes=0-999", 200);
    try testing.expect(result == null);
}

test "parseRange: empty bytes=" {
    const result = try static_files.parseRange("bytes=", 200);
    try testing.expect(result == null);
}

test "parseRange: wrong prefix BYTES=0-99" {
    const result = try static_files.parseRange("BYTES=0-99", 200);
    try testing.expect(result == null);
}

test "parseRange: start > end bytes=100-50" {
    const result = try static_files.parseRange("bytes=100-50", 200);
    try testing.expect(result == null);
}

test "parseRange: no dash bytes=50" {
    const result = try static_files.parseRange("bytes=50", 200);
    try testing.expect(result == null);
}
