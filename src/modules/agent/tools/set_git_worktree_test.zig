const std = @import("std");
const testing = std.testing;
const swt = @import("set_git_worktree.zig");

const TOOL_PATH = "src/modules/agent/tools/set_git_worktree.zig";

/// Read a source file from disk, relative to the project root.
fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
}

// ─── Static source-check tests ────────────────────────────────────────────

test "set_git_worktree tool definition has correct name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, ".name = \"set_git_worktree\"") == null) {
        std.debug.print("!! set_git_worktree.zig does not define the tool with .name = \"set_git_worktree\" !!\n", .{});
        return error.ToolNameMissing;
    }
}

test "set_git_worktree tool description mentions absolute path" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "absolute path") == null) {
        std.debug.print("!! set_git_worktree.zig description does not mention 'absolute path' !!\n", .{});
        return error.AbsolutePathMissing;
    }
}

test "set_git_worktree input struct has path + clear + branch fields" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "path: []const u8") == null) {
        std.debug.print("!! SetGitWorktreeInput is missing the 'path' field !!\n", .{});
        return error.PathFieldMissing;
    }
    if (std.mem.indexOf(u8, source, "clear: bool") == null) {
        std.debug.print("!! SetGitWorktreeInput is missing the 'clear' field !!\n", .{});
        return error.ClearFieldMissing;
    }
    if (std.mem.indexOf(u8, source, "branch: []const u8") == null) {
        std.debug.print("!! SetGitWorktreeInput is missing the 'branch' field !!\n", .{});
        return error.BranchFieldMissing;
    }
}

// ─── Behavioral tests for validatePath ────────────────────────────────────

test "validatePath accepts valid absolute paths" {
    const valid_paths = [_][]const u8{
        "/home/me/proj/.worktrees/auth-fix",
        "/tmp/experiments/rpc-rewrite",
        "/a/b/c",
        "/x",
    };
    for (valid_paths) |p| {
        try testing.expect(swt.validatePath(p) == null);
    }
}

test "validatePath rejects empty path" {
    try testing.expect(swt.validatePath("") != null);
}

test "validatePath rejects relative path" {
    try testing.expect(swt.validatePath("foo/bar") != null);
}

test "validatePath rejects path with .." {
    try testing.expect(swt.validatePath("/home/me/../etc/passwd") != null);
}

test "validatePath rejects null byte" {
    try testing.expect(swt.validatePath("/foo\x00bar") != null);
}

test "validatePath rejects too-long path" {
    var long_path: [5000]u8 = undefined;
    @memset(long_path[0..], '/');
    long_path[0] = '/';
    for (1..5000) |i| long_path[i] = 'a';
    try testing.expect(swt.validatePath(long_path[0..]) != null);
}

test "validatePath rejects illegal basename" {
    const bad_paths = [_][]const u8{
        "/foo/hello world",
        "/foo/bad!char",
        "/foo/.",
        "/foo/..",
    };
    for (bad_paths) |p| {
        try testing.expect(swt.validatePath(p) != null);
    }
}

// ─── Behavioral tests for validateBasename ────────────────────────────────

test "validateBasename accepts legal names" {
    const ok = [_][]const u8{ "auth-fix", "v2", "x", "a..b" };
    for (ok) |n| {
        try testing.expect(swt.validateBasename(n) == null);
    }
}

test "validateBasename rejects illegal names" {
    const bad = [_][]const u8{ "hello world", "a/b", ".", ".." };
    for (bad) |n| {
        try testing.expect(swt.validateBasename(n) != null);
    }
}

// ─── Behavioral tests for deriveBranchFromPath ────────────────────────────

test "deriveBranchFromPath returns worktree/<basename>" {
    const allocator = testing.allocator;

    const b1 = try swt.deriveBranchFromPath(allocator, "/abs/.worktrees/auth-fix");
    defer allocator.free(b1);
    try testing.expectEqualStrings("worktree/auth-fix", b1);

    const b2 = try swt.deriveBranchFromPath(allocator, "/tmp/foo");
    defer allocator.free(b2);
    try testing.expectEqualStrings("worktree/foo", b2);

    const b3 = try swt.deriveBranchFromPath(allocator, "/Users/me/proj/.worktrees/fix-bug-123");
    defer allocator.free(b3);
    try testing.expectEqualStrings("worktree/fix-bug-123", b3);
}
