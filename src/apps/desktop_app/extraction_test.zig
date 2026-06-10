// src/apps/desktop_app/extraction_test.zig
//
// Tests for the runtime extraction module. Two test cases:
//
//   1. extract() writes every asset's bytes to a fresh temp dir, returns
//      an absolute path, and the on-disk files match the source content
//      byte-for-byte (including files in subdirectories, which test
//      extract's makePath-for-parent logic).
//   2. cleanup() removes the temp dir recursively.
//
// Both tests are pure CPU + filesystem; no networking or subprocesses.
// They use the system's default temp dir (`$TMPDIR` / `$XDG_RUNTIME_DIR` /
// `/tmp`), so a parallel test run on the same host could in theory
// collide — but `extract` puts each run in a per-pid subdir, so the
// collision window is essentially zero.
//
// Zig 0.16 API notes:
//   * `std.fs.cwd()` is gone, so file reads in the test use raw
//     `std.os.linux.open` + `read` syscalls (matching the patterns in
//     subprocess_test.zig and path_resolve.zig). The actual SUT code
//     (extraction.zig) also uses raw syscalls internally for the same
//     reason.
//   * The cwd-only stat for "did cleanup succeed?" uses faccessat(2)
//     with AT.FDCWD, which is a single syscall and doesn't need an
//     Io runtime.

const std = @import("std");
const extraction = @import("extraction.zig");
const testing = std.testing;

test "extract: writes all assets to a temp dir, returns absolute path" {
    const allocator = testing.allocator;

    // Use a tiny in-memory asset list. The "/assets/app.js" path tests
    // that extract() handles the parent-dir creation for nested files.
    const assets = [_]extraction.AssetEntry{
        .{ .path = "/index.html", .content = "<html>hi</html>", .mime = "text/html" },
        .{ .path = "/assets/app.js", .content = "console.log('x')", .mime = "application/javascript" },
    };

    const dir = try extraction.extract(allocator, &assets);
    defer extraction.cleanup(allocator, dir);

    // Returned path must be absolute so the webview can resolve it
    // regardless of cwd.
    try testing.expect(std.fs.path.isAbsolute(dir));

    // Verify both files exist with the right content. Read the files
    // back via raw open(2) + read(2) since std.fs.cwd() is gone in 0.16.
    try readBackAndExpect(dir, "index.html", "<html>hi</html>");
    try readBackAndExpect(dir, "assets/app.js", "console.log('x')");
}

test "extract: cleanup removes the dir" {
    const allocator = testing.allocator;

    const assets = [_]extraction.AssetEntry{
        .{ .path = "/index.html", .content = "x", .mime = "text/html" },
    };
    const dir = try extraction.extract(allocator, &assets);
    try testing.expect(std.fs.path.isAbsolute(dir));

    // Sanity: the dir exists right after extract.
    try testing.expect(dirExists(dir));

    // `cleanup` frees the `dir` slice (it owns the path), so copy it
    // first if we want to inspect the on-disk state after.
    const dir_copy = try allocator.dupe(u8, dir);
    defer allocator.free(dir_copy);

    extraction.cleanup(allocator, dir);

    // After cleanup, the dir should not exist. Read via the copy
    // (the original `dir` is now freed).
    try testing.expect(!dirExists(dir_copy));
}

/// Read `subpath` (relative to `dir`) and assert its content equals
/// `expected`. Uses raw syscalls because `std.fs.cwd()` is gone in 0.16.
fn readBackAndExpect(dir: []const u8, subpath: []const u8, expected: []const u8) !void {
    const allocator = testing.allocator;
    const full = try std.fs.path.join(allocator, &.{ dir, subpath });
    defer allocator.free(full);

    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const path_z = copyToNull(&path_buf, full);

    const fd_rc = std.os.linux.open(
        path_z,
        .{ .ACCMODE = .RDONLY, .CLOEXEC = true },
        0,
    );
    try testing.expect(fd_rc <= std.math.maxInt(i32));
    const fd: i32 = @intCast(fd_rc);
    defer _ = std.os.linux.close(fd);

    // statx to size the read.
    var statbuf: std.os.linux.Statx = undefined;
    const stat_rc = std.os.linux.statx(
        std.os.linux.AT.FDCWD,
        path_z,
        0,
        .{ .SIZE = true },
        &statbuf,
    );
    try testing.expect(stat_rc == 0);
    const size: usize = @intCast(statbuf.size);
    const content = try readAll(allocator, fd, size);
    defer allocator.free(content);
    try testing.expectEqualStrings(expected, content);
}

fn readAll(allocator: std.mem.Allocator, fd: i32, size: usize) ![]u8 {
    const buf = try allocator.alloc(u8, size);
    var total: usize = 0;
    while (total < size) {
        const n_rc = std.os.linux.read(fd, buf[total..].ptr, size - total);
        try testing.expect(n_rc <= std.math.maxInt(usize));
        const n: usize = @intCast(n_rc);
        if (n == 0) break;
        total += n;
    }
    return buf[0..total];
}

fn dirExists(path: []const u8) bool {
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const path_z = copyToNull(&path_buf, path);
    const rc = std.os.linux.faccessat(std.os.linux.AT.FDCWD, path_z, 0, 0);
    return rc == 0;
}

fn copyToNull(buf: *[std.fs.max_path_bytes:0]u8, path: []const u8) [*:0]const u8 {
    if (path.len >= buf.len) @panic("path too long for null-terminated buffer");
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf;
}
