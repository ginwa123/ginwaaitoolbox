// src/modules/agent/tools/path_security_test.zig
//
// Regression tests for the shared absolute-path validator + cwd resolver.
// Used by every tool's exec wrapper to reject absolute paths (security
// policy) and to resolve relative cwd-style params against the active
// session cwd.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const path_security = @import("path_security.zig");

// -------------------------------------------------------------------------
// rejectAbsolutePath — relative paths return null (caller proceeds)
// -------------------------------------------------------------------------

test "rejectAbsolutePath: relative path returns null (ok)" {
    const alloc = testing.allocator;

    const result = try path_security.rejectAbsolutePath(
        alloc,
        "read_file",
        "path",
        "src/main.zig",
        "/home/user/project",
    );
    defer if (result) |s| alloc.free(s);

    try testing.expect(result == null);
}

test "rejectAbsolutePath: \".\" returns null (ok)" {
    const alloc = testing.allocator;

    const result = try path_security.rejectAbsolutePath(
        alloc,
        "list_directory",
        "path",
        ".",
        "/home/user/project",
    );
    defer if (result) |s| alloc.free(s);

    try testing.expect(result == null);
}

test "rejectAbsolutePath: \"\" empty string returns null (ok)" {
    const alloc = testing.allocator;

    const result = try path_security.rejectAbsolutePath(
        alloc,
        "bash",
        "cwd",
        "",
        "/home/user/project",
    );
    defer if (result) |s| alloc.free(s);

    try testing.expect(result == null);
}

test "rejectAbsolutePath: \"../foo\" parent-traversal returns null (still relative)" {
    // Out of scope for this PR (path-traversal protection is a separate
    // follow-up per the design spec), but the function should not
    // accidentally reject parent-relative paths — only true absolutes.
    const alloc = testing.allocator;

    const result = try path_security.rejectAbsolutePath(
        alloc,
        "read_file",
        "path",
        "../foo.txt",
        "/home/user/project",
    );
    defer if (result) |s| alloc.free(s);

    try testing.expect(result == null);
}

// -------------------------------------------------------------------------
// rejectAbsolutePath — absolute paths return an error envelope
// -------------------------------------------------------------------------

test "rejectAbsolutePath: \"/etc/passwd\" returns error envelope naming the rule" {
    const alloc = testing.allocator;

    const result = try path_security.rejectAbsolutePath(
        alloc,
        "read_file",
        "path",
        "/etc/passwd",
        "/home/user/project",
    );
    defer if (result) |s| alloc.free(s);

    try testing.expect(result != null);
    try testing.expect(std.mem.indexOf(u8, result.?, "absolute paths are not allowed") != null);
    try testing.expect(std.mem.indexOf(u8, result.?, "read_file") != null);
    try testing.expect(std.mem.indexOf(u8, result.?, "path") != null);
    try testing.expect(std.mem.indexOf(u8, result.?, "/etc/passwd") != null);
    try testing.expect(std.mem.indexOf(u8, result.?, "/home/user/project") != null);
}

test "rejectAbsolutePath: \"/\" alone (root) is rejected" {
    // Edge case: a path that is just `/` is also absolute and must be rejected.
    const alloc = testing.allocator;

    const result = try path_security.rejectAbsolutePath(
        alloc,
        "read_file",
        "path",
        "/",
        "/home/user/project",
    );
    defer if (result) |s| alloc.free(s);

    try testing.expect(result != null);
    try testing.expect(std.mem.indexOf(u8, result.?, "absolute paths are not allowed") != null);
}

// -------------------------------------------------------------------------
// resolveCwd — null/empty raw → base cwd; relative raw → joined
// -------------------------------------------------------------------------

test "resolveCwd: null raw returns base cwd (duplicated)" {
    const alloc = testing.allocator;

    const result = try path_security.resolveCwd(alloc, "/proj", null, null);
    defer alloc.free(result);

    try testing.expectEqualStrings("/proj", result);
}

test "resolveCwd: empty string raw returns base cwd" {
    const alloc = testing.allocator;

    const result = try path_security.resolveCwd(alloc, "/proj", null, "");
    defer alloc.free(result);

    try testing.expectEqualStrings("/proj", result);
}

test "resolveCwd: relative raw joins against base cwd" {
    const alloc = testing.allocator;

    const result = try path_security.resolveCwd(alloc, "/proj", null, "src/main.zig");
    defer alloc.free(result);

    try testing.expectEqualStrings("/proj/src/main.zig", result);
}

test "resolveCwd: relative raw with nested segments joins correctly" {
    const alloc = testing.allocator;

    const result = try path_security.resolveCwd(alloc, "/proj", null, "a/b/c.txt");
    defer alloc.free(result);

    try testing.expectEqualStrings("/proj/a/b/c.txt", result);
}

test "resolveCwd: ctx_cwd_override wins over ctx_cwd" {
    const alloc = testing.allocator;

    const result = try path_security.resolveCwd(
        alloc,
        "/proj",
        "/home/user/project/.worktrees/feature",
        "src/foo.zig",
    );
    defer alloc.free(result);

    try testing.expectEqualStrings(
        "/home/user/project/.worktrees/feature/src/foo.zig",
        result,
    );
}

test "resolveCwd: ctx_cwd_override with null raw returns override (worktree binding)" {
    const alloc = testing.allocator;

    const result = try path_security.resolveCwd(
        alloc,
        "/proj",
        "/home/user/project/.worktrees/feature",
        null,
    );
    defer alloc.free(result);

    try testing.expectEqualStrings("/home/user/project/.worktrees/feature", result);
}
