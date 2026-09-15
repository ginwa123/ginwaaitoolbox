//! Tests for src/commands/pr_status.zig (GET /api/git/pr/status).
//!
//! Real arg-parser tests live in `commands/root.zig`; path-building
//! unit tests live here next to the command.

const std = @import("std");
const testing = std.testing;
const pr_status = @import("pr_status.zig");

test "pr_status buildPath: defaults omit empty pr/provider" {
    const p = try pr_status.buildPath(testing.allocator, .{});
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("/api/git/pr/status?path=.", p);
}

test "pr_status buildPath: encodes pr URL and provider" {
    const p = try pr_status.buildPath(testing.allocator, .{
        .pr = "https://github.com/acme/app/pull/42",
        .path = "/tmp/repo",
        .provider = "github",
    });
    defer testing.allocator.free(p);
    try testing.expect(std.mem.indexOf(u8, p, "/api/git/pr/status?path=") != null);
    try testing.expect(std.mem.indexOf(u8, p, "%3A%2F%2F") != null);
    try testing.expect(std.mem.indexOf(u8, p, "&provider=github") != null);
}
