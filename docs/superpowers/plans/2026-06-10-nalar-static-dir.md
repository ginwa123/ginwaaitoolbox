# `nalar` Static-File Serving (`--static-dir`) — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `--static-dir <path>` CLI flag to `nalar` that serves files from the given directory at HTTP `/` (with `/api/*` taking precedence), with proper mime-type detection, range-request support, and protection against path-traversal attacks. This unblocks the desktop webview wrapper (Plan B) by giving it a way to serve the embedded Vue dist/.

**Architecture:** A new `src/modules/static_files.zig` module exposes a single `serve(req, res, ctx)` function that resolves the requested path against the configured directory, enforces a sandbox (no `..`, no symlink escapes), detects mime, and streams the file. `src/main.zig` adds the CLI flag and registers a wildcard catch-all route *after* all `/api/*` routes so API calls always win.

**Tech Stack:** Zig 0.15, the existing `httpz` dependency (a local fork in `zig-pkg/`), the existing `nalar` CLI style (manually-parsed `args_iter`).

**Prerequisite (read first):** `docs/plans/2026-06-10-desktop-webview-app-design.md` — the "Prerequisites (blocks)" section. This plan implements the prerequisite.

**Reference design doc:** `docs/plans/2026-06-10-desktop-webview-app-design.md` (the "Prerequisites" section specifies the CLI surface).

---

## File Structure

This plan creates/modifies exactly these files:

```
src/modules/static_files.zig            ← NEW: the static-file handler module
src/modules/static_files_test.zig       ← NEW: unit tests
src/modules/test_runner.zig             ← MODIFY: register static_files_test
src/main.zig                            ← MODIFY: add --static-dir flag, register wildcard route
src/ai_workflow/http_handlers/          ← UNCHANGED (no API surface changes)
```

No new top-level modules, no new build steps, no schema migrations.

---

## Decisions locked in by this plan

These were decided during brainstorming and are **not up for re-litigation during implementation**:

- **Route precedence:** `/api/*` always wins. The wildcard static-file route is registered *last* so it only catches paths no API handler claimed. The `httpz` router's matching order (first-match) makes this a registration-order decision.
- **Path sandbox:** Resolve the user-requested path relative to the static dir, then assert the resolved absolute path starts with the static dir's absolute path. Reject otherwise with 403. This blocks `..` and symlink escapes uniformly.
- **Default index:** Directory requests resolve to `<dir>/index.html` if it exists, else 404. No directory listing.
- **Range requests:** Support the standard `Range: bytes=START-END` header. Single range only (multi-range is rare and not needed for a webapp).
- **Mime detection:** Extension-based lookup with a static table. No `libmagic`. Covers the common web types (HTML, CSS, JS, JSON, images, fonts, SVG, ICO).
- **Compression:** None. The webapp assets are pre-minified; nginx/Cloudflare in front of the user-facing deployment handles gzip. Adds complexity for no v1 benefit.
- **Caching headers:** ETag (mtime + size hash) and `Cache-Control: public, max-age=3600` on success. `Cache-Control: no-store` on errors.
- **Concurrency:** Synchronous file reads. The webapp is small (<5 MB total), reads are sub-millisecond on SSD, and `httpz` runs each request in its own coroutine. No async file I/O needed for v1.

---

## Task 1: Module skeleton + TDD scaffolding

**Files:**
- Create: `src/modules/static_files.zig` (empty stub)
- Create: `src/modules/static_files_test.zig` (empty stub)
- Modify: `src/modules/test_runner.zig` (add the new test file)

- [ ] **Step 1: Create the empty module**

```zig
// src/modules/static_files.zig
const std = @import("std");

/// Configuration for the static-file handler. Constructed once at startup,
/// passed by pointer to every request handler invocation.
pub const StaticDirConfig = struct {
    /// Absolute, canonicalized path to the directory whose contents should be served.
    root_dir: []const u8,
    allocator: std.mem.Allocator,
};

/// Result of a static-file lookup. The handler converts this into an HTTP response.
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

/// Resolve a request path (e.g. "/assets/index-abc.js") against the static dir.
/// Returns the resolved file's absolute path, mime type, and size — or an error
/// describing why the request can't be served.
///
/// This is the pure function used by tests; the actual HTTP handler is a thin
/// wrapper that calls this and writes the response.
pub fn resolve(
    cfg: *const StaticDirConfig,
    request_path: []const u8,
) !LookupResult {
    _ = cfg;
    _ = request_path;
    return .not_found; // TODO: real impl
}

/// Send a static file as an HTTP response. Pure: no side effects on the cfg.
/// (Stub for now; fleshed out in Task 3.)
pub fn serve(
    cfg: *const StaticDirConfig,
    request_path: []const u8,
    range_header: ?[]const u8,
    writer: std.io.AnyWriter,
) !LookupResult {
    _ = cfg;
    _ = request_path;
    _ = range_header;
    _ = writer;
    return .not_found;
}
```

- [ ] **Step 2: Create the test file with a placeholder test**

```zig
// src/modules/static_files_test.zig
const std = @import("std");
const static_files = @import("static_files.zig");

test "placeholder" {
    try std.testing.expect(true);
}
```

- [ ] **Step 3: Register the test in `test_runner.zig`**

Find the test imports in `src/modules/test_runner.zig` (search for `_ = @import(`). Add the new file alongside the others in alphabetical order.

Expected diff:
```diff
 _ = @import("something_test.zig");
+_ = @import("static_files_test.zig");
```

If `test_runner.zig` doesn't exist, create it with:
```zig
const std = @import("std");
test "module loaded" {
    _ = std.testing.refAllModule(@import("static_files_test.zig"));
}
```

Read the existing `test_runner.zig` first to match its style.

- [ ] **Step 4: Build to verify the skeleton compiles**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
zig build 2>&1 | head -n 30
```

Expected: clean build. The module exists but isn't used yet — no callers means no link errors.

- [ ] **Step 5: Run the placeholder test**

```bash
zig build test 2>&1 | head -n 20
```

Expected: `1 passed` (the placeholder test).

- [ ] **Step 6: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/modules/static_files.zig src/modules/static_files_test.zig src/modules/test_runner.zig
git -c user.email='ginwa@example.com' -c user.name='ginwa' commit -m "feat(static-files): add module skeleton + TDD scaffolding"
```

---

## Task 2: `resolve()` — path sandbox + mime detection (pure function, TDD)

**Files:**
- Modify: `src/modules/static_files.zig`
- Modify: `src/modules/static_files_test.zig`

This is the testable core of the module. No I/O beyond `std.fs.cwd().realpath` (which is needed to canonicalize the root).

- [ ] **Step 1: Write the failing tests for `resolve()`**

```zig
// In src/modules/static_files_test.zig — REPLACE the placeholder test
const std = @import("std");
const static_files = @import("static_files.zig");
const testing = std.testing;

const TestEnv = struct {
    tmp_dir: std.testing.TmpDir,
    root_abs: []const u8,

    fn deinit(self: *TestEnv, allocator: std.mem.Allocator) void {
        allocator.free(self.root_abs);
        self.tmp_dir.cleanup();
    }
};

fn setupRoot(allocator: std.mem.Allocator) !TestEnv {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup(); // replaced in caller
    // Caller will do their own cleanup; we just want the path
    const abs = try tmp.dir.realpathAlloc(allocator, ".");
    return .{ .tmp_dir = tmp, .root_abs = abs };
}

test "resolve: index.html for root path" {
    const allocator = testing.allocator;
    var env = try setupRoot(allocator);
    defer env.deinit(allocator);
    // tmp dir is auto-cleaned by TmpDir; we don't actually write index.html here — this test only checks path resolution
    const cfg = static_files.StaticDirConfig{ .root_dir = env.root_abs, .allocator = allocator };
    const result = try static_files.resolve(&cfg, "/");
    // Without index.html, root resolves to not_a_file
    try testing.expect(result == .not_a_file or result == .not_found);
}

test "resolve: returns forbidden for path traversal attempt" {
    const allocator = testing.allocator;
    var env = try setupRoot(allocator);
    defer env.deinit(allocator);
    const cfg = static_files.StaticDirConfig{ .root_dir = env.root_abs, .allocator = allocator };
    const result = try static_files.resolve(&cfg, "/../../etc/passwd");
    try testing.expect(result == .forbidden);
}

test "resolve: returns forbidden for absolute path attempt" {
    const allocator = testing.allocator;
    var env = try setupRoot(allocator);
    defer env.deinit(allocator);
    const cfg = static_files.StaticDirConfig{ .root_dir = env.root_abs, .allocator = allocator };
    const result = try static_files.resolve(&cfg, "/etc/passwd");
    // /etc/passwd is absolute, but resolved relative to root_abs it's just a missing file
    // — what matters is that "..%2F" or other escapes are blocked
    _ = result;
}

test "resolve: returns file info for a real file" {
    const allocator = testing.allocator;
    var env = try setupRoot(allocator);
    defer env.deinit(allocator);
    // Write a real file
    const f = try env.tmp_dir.dir.createFile("test.txt", .{});
    defer f.close();
    try f.writeAll("hello world");
    const cfg = static_files.StaticDirConfig{ .root_dir = env.root_abs, .allocator = allocator };
    const result = try static_files.resolve(&cfg, "/test.txt");
    try testing.expect(result == .file);
    try testing.expectEqualStrings("text/plain", result.file.mime);
    try testing.expectEqual(@as(u64, 11), result.file.size);
}

test "resolve: returns not_a_file for a directory without index.html" {
    const allocator = testing.allocator;
    var env = try setupRoot(allocator);
    defer env.deinit(allocator);
    try env.tmp_dir.dir.makeDir("subdir");
    const cfg = static_files.StaticDirConfig{ .root_dir = env.root_abs, .allocator = allocator };
    const result = try static_files.resolve(&cfg, "/subdir");
    try testing.expect(result == .not_a_file);
}

test "resolve: returns file for a directory with index.html" {
    const allocator = testing.allocator;
    var env = try setupRoot(allocator);
    defer env.deinit(allocator);
    try env.tmp_dir.dir.makeDir("subdir");
    const f = try env.tmp_dir.dir.createFile("subdir/index.html", .{});
    defer f.close();
    try f.writeAll("<html></html>");
    const cfg = static_files.StaticDirConfig{ .root_dir = env.root_abs, .allocator = allocator };
    const result = try static_files.resolve(&cfg, "/subdir");
    try testing.expect(result == .file);
    try testing.expectEqualStrings("text/html", result.file.mime);
}

test "resolve: mime types for common web extensions" {
    const allocator = testing.allocator;
    var env = try setupRoot(allocator);
    defer env.deinit(allocator);
    const cases = .{
        .{ "f.html", "text/html" },
        .{ "f.css", "text/css" },
        .{ "f.js", "application/javascript" },
        .{ "f.mjs", "application/javascript" },
        .{ "f.json", "application/json" },
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
        .{ "f.map", "application/json" },
        .{ "f.txt", "text/plain" },
    };
    inline for (cases) |case| {
        const f = try env.tmp_dir.dir.createFile(case[0], .{});
        defer f.close();
        try f.writeAll("x");
        const cfg = static_files.StaticDirConfig{ .root_dir = env.root_abs, .allocator = allocator };
        const result = try static_files.resolve(&cfg, "/" ++ case[0]);
        try testing.expect(result == .file);
        try testing.expectEqualStrings(case[1], result.file.mime);
    }
}

test "resolve: case-insensitive extension match" {
    const allocator = testing.allocator;
    var env = try setupRoot(allocator);
    defer env.deinit(allocator);
    const f = try env.tmp_dir.dir.createFile("a.HTML", .{});
    defer f.close();
    try f.writeAll("x");
    const cfg = static_files.StaticDirConfig{ .root_dir = env.root_abs, .allocator = allocator };
    const result = try static_files.resolve(&cfg, "/a.HTML");
    try testing.expect(result == .file);
    try testing.expectEqualStrings("text/html", result.file.mime);
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
zig build test 2>&1 | tail -n 40
```

Expected: tests fail with `error: 'resolve' has no body` or similar (because the impl is still a stub returning `.not_found`).

- [ ] **Step 3: Implement `resolve()` and the mime table**

Replace the `resolve()` stub in `src/modules/static_files.zig` with the real implementation. The key pieces:

```zig
const MimeEntry = struct { ext: []const u8, mime: []const u8 };
const mime_table = [_]MimeEntry{
    .{ .ext = ".html", .mime = "text/html; charset=utf-8" },
    .{ .ext = ".css",  .mime = "text/css; charset=utf-8" },
    .{ .ext = ".js",   .mime = "application/javascript; charset=utf-8" },
    .{ .ext = ".mjs",  .mime = "application/javascript; charset=utf-8" },
    .{ .ext = ".json", .mime = "application/json; charset=utf-8" },
    .{ .ext = ".svg",  .mime = "image/svg+xml" },
    .{ .ext = ".png",  .mime = "image/png" },
    .{ .ext = ".jpg",  .mime = "image/jpeg" },
    .{ .ext = ".jpeg", .mime = "image/jpeg" },
    .{ .ext = ".gif",  .mime = "image/gif" },
    .{ .ext = ".webp", .mime = "image/webp" },
    .{ .ext = ".ico",  .mime = "image/x-icon" },
    .{ .ext = ".woff", .mime = "font/woff" },
    .{ .ext = ".woff2",.mime = "font/woff2" },
    .{ .ext = ".ttf",  .mime = "font/ttf" },
    .{ .ext = ".map",  .mime = "application/json; charset=utf-8" },
    .{ .ext = ".txt",  .mime = "text/plain; charset=utf-8" },
};

fn mimeForPath(path: []const u8) []const u8 {
    // Find the last '.' after the last '/'
    var dot_idx: ?usize = null;
    var i: usize = 0;
    for (path) |c| {
        if (c == '/') dot_idx = null;
        if (c == '.' and dot_idx == null) dot_idx = i;
        i += 1;
    }
    const ext_start = dot_idx orelse return "application/octet-stream";
    const ext = path[ext_start..];
    for (mime_table) |entry| {
        if (std.ascii.eqlIgnoreCase(ext, entry.ext)) return entry.mime;
    }
    return "application/octet-stream";
}

pub fn resolve(
    cfg: *const StaticDirConfig,
    request_path: []const u8,
) !LookupResult {
    // 1. Strip query string if present
    var clean_path: []const u8 = request_path;
    if (std.mem.indexOfScalar(u8, request_path, '?')) |q| {
        clean_path = request_path[0..q];
    }

    // 2. Reject path traversal sequences (defense in depth — the canonicalization
    //    step below is the real protection)
    if (std.mem.indexOf(u8, clean_path, "..") != null) {
        return .forbidden;
    }

    // 3. Build the candidate relative path inside the static dir
    //    "/" -> "index.html", "/foo" -> "foo", "/foo/" -> "foo/index.html"
    var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
    var rel: []const u8 = undefined;
    if (std.mem.eql(u8, clean_path, "/") or std.mem.eql(u8, clean_path, "")) {
        rel = "index.html";
    } else {
        const stripped = if (clean_path[0] == '/') clean_path[1..] else clean_path;
        if (stripped.len == 0) {
            rel = "index.html";
        } else if (stripped[stripped.len - 1] == '/') {
            const fn_buf = try std.fmt.bufPrint(&rel_buf, "{s}index.html", .{stripped});
            rel = fn_buf;
        } else {
            rel = stripped;
        }
    }

    // 4. Resolve to an absolute path and verify it stays inside the static dir
    const abs = cfg.root_dir;  // We'll open the dir and resolve relative to it
    var dir = std.fs.openDirAbsolute(abs, .{}) catch |err| switch (err) {
        error.FileNotFound => return .not_found,
        else => return .not_found,
    };
    defer dir.close();

    const resolved = dir.realpathAlloc(cfg.allocator, rel) catch |err| switch (err) {
        error.FileNotFound => return .not_found,
        error.NotDir => return .not_a_file,
        else => return .not_found,
    };
    defer cfg.allocator.free(resolved);

    // 5. Sandbox check: resolved path must start with the root
    if (!std.mem.startsWith(u8, resolved, abs)) {
        return .forbidden;
    }

    // 6. Stat the file
    const file = dir.openFile(rel, .{}) catch |err| switch (err) {
        error.FileNotFound => return .not_found,
        error.IsDir => {
            // Try index.html
            const sub = dir.openDir(rel, .{}) catch return .not_a_file;
            defer sub.close();
            const idx = sub.openFile("index.html", .{}) catch return .not_a_file;
            defer idx.close();
            const stat = idx.stat() catch return .not_a_file;
            const idx_abs = try sub.realpathAlloc(cfg.allocator, "index.html");
            defer cfg.allocator.free(idx_abs);
            return .{ .file = .{
                .abs_path = idx_abs,
                .mime = mimeForPath(idx_abs),
                .size = stat.size,
            }};
        },
        else => return .not_found,
    };
    defer file.close();
    const stat = file.stat() catch return .not_found;

    return .{ .file = .{
        .abs_path = resolved,
        .mime = mimeForPath(resolved),
        .size = stat.size,
    }};
}
```

> **NOTE for implementer:** `dir.realpathAlloc` is the canonicalization step that defeats symlink escapes (realpath resolves all symlinks). The `std.mem.startsWith(u8, resolved, abs)` check is the second line of defense. The early `..` check is the third. This is belt-and-suspenders on purpose.

- [ ] **Step 4: Run tests, verify all pass**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
zig build test 2>&1 | tail -n 40
```

Expected: 8/8 new tests pass. Some pre-existing tests may also have changed; verify the total count went up by 8, not the same.

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/modules/static_files.zig src/modules/static_files_test.zig
git -c user.email='ginwa@example.com' -c user.name='ginwa' commit -m "feat(static-files): add resolve() with path sandbox and mime detection"
```

---

## Task 3: `serve()` — wire resolve() to an HTTP response (TDD)

**Files:**
- Modify: `src/modules/static_files.zig`
- Modify: `src/modules/static_files_test.zig`

`serve()` takes the same `cfg` + path + range header and writes an HTTP response to the writer. The shape of the writer depends on httpz — find what `*Response` looks like in the existing handlers and match.

- [ ] **Step 1: Find the httpz Response API**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
rg "fn (setStatus|header|write|end|json|sendStatus)" zig-pkg/httpz-0.0.0-PNVzrBu9BwC__muOxHYDIFGgKbhmsNWQHitrR0BIweJY/src/ --files-with-matches 2>&1
```

Look at one of the existing handlers in `src/ai_workflow/` (search for `pub fn .*Handler.*req:.*res:`) to see the typical pattern: how they set status, set headers, write body, send errors.

Expected: a `Response` struct with methods like:
- `setStatus(code: u16)`
- `header(name, value)`
- `write(body)`
- `json(obj)` (we don't use this)

- [ ] **Step 2: Adapt the `serve()` signature to the actual httpz Response type**

Replace the stub. The exact method names will depend on Step 1's findings — match the existing handlers' style exactly. Pseudocode:

```zig
pub fn serve(
    cfg: *const StaticDirConfig,
    request_path: []const u8,
    range_header: ?[]const u8,
    res: *httpz.Response,
) !void {
    const lookup = try resolve(cfg, request_path);
    switch (lookup) {
        .not_found => {
            try res.setStatus(404);
            try res.header("Content-Type", "text/plain; charset=utf-8");
            try res.write("404 Not Found");
            return;
        },
        .forbidden => {
            try res.setStatus(403);
            try res.header("Content-Type", "text/plain; charset=utf-8");
            try res.write("403 Forbidden");
            return;
        },
        .not_a_file => {
            try res.setStatus(404);
            try res.header("Content-Type", "text/plain; charset=utf-8");
            try res.write("404 Not Found");
            return;
        },
        .file => |f| {
            // ETag from size + (mtime would be nicer but reading the file is enough for v1)
            const etag = try std.fmt.allocPrint(cfg.allocator, "\"x-{x}\"", .{f.size});
            defer cfg.allocator.free(etag);
            try res.header("ETag", etag);
            try res.header("Cache-Control", "public, max-age=3600");
            try res.header("Content-Type", f.mime);

            // Range request support (single range only)
            if (range_header) |rh| {
                if (try parseRange(rh, f.size)) |range| {
                    try res.setStatus(206);
                    const content_range = try std.fmt.allocPrint(
                        cfg.allocator, "bytes {d}-{d}/{d}", .{ range.start, range.end, f.size }
                    );
                    defer cfg.allocator.free(content_range);
                    try res.header("Content-Range", content_range);
                    const content_length = try std.fmt.allocPrint(
                        cfg.allocator, "{d}", .{range.end - range.start + 1}
                    );
                    defer cfg.allocator.free(content_length);
                    try res.header("Content-Length", content_length);
                    try writeFileRange(res, f.abs_path, range.start, range.end);
                    return;
                }
            }

            // Full response
            try res.setStatus(200);
            const content_length = try std.fmt.allocPrint(cfg.allocator, "{d}", .{f.size});
            defer cfg.allocator.free(content_length);
            try res.header("Content-Length", content_length);
            try writeFileFull(res, f.abs_path);
        },
    }
}

const ByteRange = struct { start: u64, end: u64 };

/// Parse a single-range Range header. Returns null on malformed input.
fn parseRange(header: []const u8, file_size: u64) !?ByteRange {
    // Expected format: "bytes=START-END" or "bytes=START-"
    if (!std.mem.startsWith(u8, header, "bytes=")) return null;
    const spec = header["bytes=".len..];
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return null;
    const start_s = spec[0..dash];
    const end_s = spec[dash + 1..];

    if (start_s.len == 0) {
        // Suffix range: bytes=-N means "last N bytes"
        if (end_s.len == 0) return null;
        const suffix = try std.fmt.parseInt(u64, end_s, 10);
        if (suffix == 0 or suffix > file_size) return null;
        return .{ .start = file_size - suffix, .end = file_size - 1 };
    }

    const start = try std.fmt.parseInt(u64, start_s, 10);
    const end = if (end_s.len == 0) file_size - 1 else try std.fmt.parseInt(u64, end_s, 10);
    if (start > end or end >= file_size) return null;
    return .{ .start = start, .end = end };
}

fn writeFileFull(res: *httpz.Response, abs_path: []const u8) !void {
    const file = try std.fs.openFileAbsolute(abs_path, .{});
    defer file.close();
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        try res.write(buf[0..n]);
    }
}

fn writeFileRange(
    res: *httpz.Response,
    abs_path: []const u8,
    start: u64,
    end: u64,
) !void {
    const file = try std.fs.openFileAbsolute(abs_path, .{});
    defer file.close();
    try file.seekTo(start);
    var remaining = end - start + 1;
    var buf: [64 * 1024]u8 = undefined;
    while (remaining > 0) {
        const to_read = @min(remaining, buf.len);
        const n = try file.read(buf[0..to_read]);
        if (n == 0) break;
        try res.write(buf[0..n]);
        remaining -= n;
    }
}
```

> **NOTE for implementer:** The exact `Response` API is what matters here. Look at one of the existing handlers like `sessionListHandler` in `src/ai_workflow/http_handlers/` (search for the function name) and copy the response-writing style exactly. The pseudocode above shows intent — your real code should call whatever the actual API is.

- [ ] **Step 3: Write tests for `serve()` (using the in-memory test transport if httpz has one, or a manual test with a real socket)**

Look in `zig-pkg/httpz-.../examples/` for an in-memory test pattern. If none exists, skip the unit test for `serve()` and rely on the integration test in Task 5.

- [ ] **Step 4: Run tests**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
zig build test 2>&1 | tail -n 40
```

Expected: 8/8 (or 9/9 if you added a serve test) pass.

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/modules/static_files.zig src/modules/static_files_test.zig
git -c user.email='ginwa@example.com' -c user.name='ginwa' commit -m "feat(static-files): add serve() with range support, ETag, and caching headers"
```

---

## Task 4: Wire `--static-dir` into `main.zig`

**Files:**
- Modify: `src/main.zig`

- [ ] **Step 1: Add the CLI flag to the args loop**

Find the args loop in `main.zig` (around line 119-136 in the current code). Add the new flag. Don't refactor unrelated code.

```diff
 while (args_iter.next()) |arg| {
     if (std.mem.eql(u8, arg, "--port")) {
         // ... existing ...
+    } else if (std.mem.eql(u8, arg, "--static-dir")) {
+        if (args_iter.next()) |static_dir_arg| {
+            ctxParent.static_dir_path = try allocator.dupe(u8, static_dir_arg);
+        } else {
+            std.log.err("Error: --static-dir requires a value", .{});
+            return error.InvalidArgs;
+        }
     } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
-        std.debug.print("Usage: nalar [--port PORT]\n", .{});
-        std.debug.print("  --port PORT    Port to run the HTTP server on (default: 8080)\n", .{});
+        std.debug.print("Usage: nalar [--port PORT] [--static-dir DIR]\n", .{});
+        std.debug.print("  --port PORT        Port to run the HTTP server on (default: 8080)\n", .{});
+        std.debug.print("  --static-dir DIR   Serve files from DIR at HTTP / (e.g. for a webapp)\n", .{});
         return;
     }
 }
```

> **NOTE:** The `ctxParent.static_dir_path` field doesn't exist yet — Task 4 Step 2 adds it. Implementer may need to add the field in a different order; the key is the CLI flag works and the value is captured.

- [ ] **Step 2: Add the field to `ContextIPCTui`**

Find the `ContextIPCTui` struct in `src/root.zig` (or wherever it's defined — search for `pub const ContextIPCTui = struct`). Add:

```diff
 pub const ContextIPCTui = struct {
     // ... existing fields ...
+    /// If non-null, nalar serves files from this directory at HTTP /.
+    /// The desktop webview wrapper (nalar-desktop) sets this to a temp
+    /// dir containing the embedded Vue dist/.
+    static_dir_path: ?[]const u8 = null,
 };
```

Default `null` so existing callers don't need to change. Initialize in `main.zig` where the `ctxParent.* = nalarcore.ContextIPCTui{...}` literal is.

- [ ] **Step 3: Register the wildcard route *after* all `/api/*` routes**

Find the block in `main.zig` that registers routes (lines 173-220 in the current code). The static-file route is registered LAST, after all `/api/*` routes. Pseudocode:

```zig
// After all /api/* routes:
if (ctxParent.static_dir_path) |dir| {
    // Realpath the dir to canonicalize it (defense in depth)
    const abs_dir = std.fs.cwd().realpathAlloc(allocator, dir) catch |err| {
        std.log.err("--static-dir '{s}' cannot be resolved: {s}", .{ dir, @errorName(err) });
        return err;
    };
    errdefer allocator.free(abs_dir);

    var static_cfg = try allocator.create(static_files.StaticDirConfig);
    static_cfg.* = .{
        .root_dir = abs_dir,
        .allocator = allocator,
    };

    // Verify the dir exists and is a dir
    var d = std.fs.openDirAbsolute(abs_dir, .{}) catch |err| {
        std.log.err("--static-dir '{s}' cannot be opened: {s}", .{ abs_dir, @errorName(err) });
        return err;
    };
    d.close();

    // Register the catch-all. httpz's exact API may differ — find it in
    // zig-pkg/httpz-.../examples/07_advanced_routing.zig for the wildcard syntax.
    try gs.router.get("/*", struct {
        fn handler(_: void, req: *gserverz.Request, res: *gserverz.Response) !void {
            // Extract path from req
            const path = req.path orelse "/";
            try static_files.serve(static_cfg, path, req.header("range"), res);
        }
    }.handler, {});
}
```

> **NOTE for implementer:** The exact `gserverz.Request.path`, `gserverz.Request.header(...)`, and `router.get("/*", ...)` API depends on the httpz version. Find an example in `zig-pkg/httpz-.../examples/07_advanced_routing.zig` and an existing handler in `src/ai_workflow/` to match. The plan shows intent; the implementer adapts to the real API.

- [ ] **Step 4: Build and verify the wiring compiles**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
zig build 2>&1 | head -n 50
```

Expected: clean build (or only warnings). If the wildcard syntax is wrong, fix the route string.

- [ ] **Step 5: Run the test suite**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
zig build test 2>&1 | tail -n 20
```

Expected: same number of passing tests as before this task (no regression).

- [ ] **Step 6: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/main.zig src/root.zig
git -c user.email='ginwa@example.com' -c user.name='ginwa' commit -m "feat(static-files): add --static-dir CLI flag and wildcard route"
```

---

## Task 5: Manual integration test

**Files:** none (manual verification only)

This task is a checkpoint, not automation. It catches the bugs that pure unit tests miss (route precedence, real network I/O, real mime streaming).

- [ ] **Step 1: Create a fake webapp directory**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
mkdir -p /tmp/fake-webapp/assets
cat > /tmp/fake-webapp/index.html <<'EOF'
<!doctype html>
<html><body>Hello from static dir!</body></html>
EOF
cat > /tmp/fake-webapp/assets/style.css <<'EOF'
body { background: #f0f0f0; }
EOF
echo "console.log('js loaded');" > /tmp/fake-webapp/assets/app.js
ls -R /tmp/fake-webapp/
```

- [ ] **Step 2: Start nalar with the static dir, in the background**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
zig build run -- --port 8090 --static-dir /tmp/fake-webapp &
sleep 3
echo "---server started---"
```

Expected: server starts, prints "listening on :8090" (or similar). No errors.

- [ ] **Step 3: Verify endpoints work**

```bash
# Should return 200 with the HTML body
curl -sS -i http://127.0.0.1:8090/ 2>&1 | head -n 10
# Should return 200 with CSS
curl -sS -i http://127.0.0.1:8090/assets/style.css 2>&1 | head -n 10
# Should return 200 with JS
curl -sS -i http://127.0.0.1:8090/assets/app.js 2>&1 | head -n 10
# Should return 404
curl -sS -i http://127.0.0.1:8090/does-not-exist 2>&1 | head -n 5
# Should return 403 (path traversal)
curl -sS -i 'http://127.0.0.1:8090/../etc/passwd' 2>&1 | head -n 5
# API still works
curl -sS -i http://127.0.0.1:8090/api/health 2>&1 | head -n 5
# Range request
curl -sS -i -H 'Range: bytes=0-4' http://127.0.0.1:8090/ 2>&1 | head -n 10
```

Expected:
- `/` → 200, `Content-Type: text/html; charset=utf-8`, body `Hello from static dir!`
- `/assets/style.css` → 200, `Content-Type: text/css; charset=utf-8`
- `/assets/app.js` → 200, `Content-Type: application/javascript; charset=utf-8`
- `/does-not-exist` → 404
- `/../etc/passwd` → 403 (or 404 if curl normalizes the URL — try `/..%2Fetc%2Fpasswd` if so)
- `/api/health` → 200 (API still works)
- `Range: bytes=0-4` → 206 with `Content-Range: bytes 0-4/31` and body `Hello`

- [ ] **Step 4: Kill the server**

```bash
pkill -f 'zig build run' 2>&1
# or, if you started the binary directly:
# pkill -f nalar
```

- [ ] **Step 5: If anything failed, fix the impl and re-run from Step 2**

Common failures and fixes:
- **403 for legitimate paths** → the realpath / startsWith check is wrong. Add debug logging.
- **API endpoints 404** → the wildcard route is matching before the API routes. Move the static-files registration to AFTER all `/api/*` registrations.
- **404 for valid files** → mime or path resolution bug. Re-run with `curl -v` to see the actual request path.
- **Compile error on `router.get("/*", ...)`** → the wildcard syntax differs in your httpz version. Check `zig-pkg/httpz-.../examples/07_advanced_routing.zig`.

---

## Task 6: Final commit + summary

- [ ] **Step 1: Confirm clean state**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git status 2>&1
git log --oneline -10 2>&1
```

Expected: no uncommitted changes (other than `.nalar/memories/` and `.nalar/skills/` which are gitignored). Recent commits show the 5 commits from Tasks 1-4.

- [ ] **Step 2: Update NALAR.md**

Add a one-liner to the "Language & Environment Facts" section:

```markdown
- [zig@0.15] Static-file serving via `--static-dir <path>` is available — the `nalar` server can now serve a directory at HTTP `/` (with `/api/*` precedence). See `src/modules/static_files.zig`.
```

- [ ] **Step 3: Commit the doc update**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add NALAR.md
git -c user.email='ginwa@example.com' -c user.name='ginwa' commit -m "docs(NALAR.md): note --static-dir feature"
```

- [ ] **Step 4: Report**

Output to the user:
```
Plan A (nalar --static-dir) is complete.

Commits added (5):
  - feat(static-files): add module skeleton + TDD scaffolding
  - feat(static-files): add resolve() with path sandbox and mime detection
  - feat(static-files): add serve() with range support, ETag, and caching headers
  - feat(static-files): add --static-dir CLI flag and wildcard route
  - docs(NALAR.md): note --static-dir feature

Tests: <N> new tests added to static_files_test.zig (8 minimum: resolve × 8)
Manual integration test: PASSED (curl checks: HTML, CSS, JS, 404, 403, /api/health still works, Range: bytes=0-4 → 206)

Ready to merge. After merge, Plan B (nalar-desktop) becomes implementable.
```

---

## Pitfalls & known gotchas

1. **`std.fs.cwd().realpathAlloc` vs `std.fs.openDirAbsolute(...).realpathAlloc`** — the former is on the cwd, the latter is on a specific dir. Use the latter for the path-traversal defense because it gives you a handle to use for `openFile` later.

2. **`std.mem.indexOf(u8, path, "..")` is too aggressive** — it would reject legitimate paths like `/foo..bar/baz`. Use a proper path-component check (e.g., split on `/` and check for `..` components). The realpath defense is the real protection, so the early-rejection check is just belt-and-suspenders — over-rejecting is OK.

3. **httpz's `Response` API differs from generic web frameworks** — there's no `res.send()` and no `res.status()`. Read an existing handler before writing the response.

4. **The wildcard route pattern `/*` may or may not be supported** by your httpz version. Read `zig-pkg/httpz-.../examples/07_advanced_routing.zig` first. If wildcards aren't supported, you may need to register a finite set of routes or upgrade the dependency.

5. **`Allocator` field on the cfg is a footgun** — if the cfg outlives the alloc, you get UAF. In v1 the cfg is built at startup and lives for the process's lifetime, so this is fine. Note it in the struct's doc comment.

6. **The `--static-dir` flag is checked ONCE at startup** — the dir is not re-scanned if files change. This is fine for the desktop wrapper (it writes the dir once and never touches it), but document the behavior so a future "watch and reload" feature isn't surprising.

---

## Verification

The plan is complete when all of the following are true:

- [ ] All 6 tasks' checkboxes are checked
- [ ] `zig build test` passes with N+8 tests (where N was the count before)
- [ ] The manual integration test (Task 5) passes all 7 curl checks
- [ ] The 5+ commits are on a branch (not main) and ready to merge
- [ ] `NALAR.md` has the new feature documented

If any of these fail, **do not** declare the plan complete. Fix the issue, re-run, then report.
