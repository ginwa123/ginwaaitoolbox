// src/apps/desktop_app/smoke_test.zig
//
// Tests for `smoke.verifyWebappDir` — the headless 404 guard behind
// `nalar-desktop --smoke-test`.
//
// All tests use `std.testing.tmpDir` (cross-platform, auto-cleaned) and
// only `std.Io.Dir` APIs, so they run on Linux + macOS + Windows CI
// cells alike.

const std = @import("std");
const smoke = @import("smoke.zig");
const testing = std.testing;

test "verifyWebappDir: happy path returns index.html size" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const dir = dir_buf[0..dir_len];

    const body = "<!doctype html><div id=\"app\"></div>";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "index.html", .data = body });

    const size = try smoke.verifyWebappDir(allocator, testing.io, dir);
    try testing.expectEqual(@as(u64, body.len), size);
}

test "verifyWebappDir: missing dir returns WebappDirNotFound" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);

    // A child that was never created — openDirAbsolute must fail.
    const missing = try std.fmt.allocPrint(
        allocator,
        "{s}/does-not-exist",
        .{dir_buf[0..dir_len]},
    );
    defer allocator.free(missing);

    const result = smoke.verifyWebappDir(allocator, testing.io, missing);
    try testing.expectError(error.WebappDirNotFound, result);
}

test "verifyWebappDir: dir without index.html returns IndexHtmlMissing" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const dir = dir_buf[0..dir_len];

    // Only an asset, no index.html — this is the empty-STUB shape
    // (`-Dno-webapp-rebuild` with no cached assets) that 404s at /.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "assets_app.js", .data = "console.log(1)" });

    const result = smoke.verifyWebappDir(allocator, testing.io, dir);
    try testing.expectError(error.IndexHtmlMissing, result);
}

test "verifyWebappDir: empty index.html returns IndexHtmlEmpty" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const dir = dir_buf[0..dir_len];

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "index.html", .data = "" });

    const result = smoke.verifyWebappDir(allocator, testing.io, dir);
    try testing.expectError(error.IndexHtmlEmpty, result);
}
