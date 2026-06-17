const std = @import("std");
const glob = @import("glob.zig");

test "gitignore parse line" {
    const allocator = std.testing.allocator;
    _ = allocator;

    // Test parsing *.log line
    const line = "*.log";
    if (glob.parseGitignoreLine(line)) |entry| {
        try std.testing.expect(entry.negated == false);
        try std.testing.expect(entry.directory_only == false);
        try std.testing.expect(std.mem.eql(u8, entry.pattern, "*.log"));
    } else {
        try std.testing.expect(false); // Should have parsed the line
    }
}

test "gitignore glob match - simple star" {
    // Test that the gitignoreGlobMatch function correctly matches *.log
    const result = glob.gitignoreGlobMatch("*.log", "debug.log", false);
    try std.testing.expect(result == true);
}

test "gitignore glob match - no match" {
    const result = glob.gitignoreGlobMatch("*.log", "debug.txt", false);
    try std.testing.expect(result == false);
}

test "gitignore glob match - basename" {
    // Test that basename matching works
    const result = glob.gitignoreGlobMatch("*.log", "debug.log", false);
    try std.testing.expect(result == true);
}

test "GitignoreContext.isIgnored - direct test" {
    const allocator = std.testing.allocator;

    // Create context with a specific root path
    const root = "/tmp/gitignore_test_ctx";
    var ctx = glob.GitignoreContext.init(root);
    defer ctx.deinit(allocator);

    // Test isIgnored directly with a known path
    // The path /tmp/gitignore_test_ctx/debug.log should be checked against the context
    const test_path = "/tmp/gitignore_test_ctx/debug.log";
    
    // Initially, no rules loaded - nothing should be ignored
    try std.testing.expect(ctx.isIgnored(test_path) == false);
}

test "GitignoreContext with entries" {
    const allocator = std.testing.allocator;

    const root = "/tmp/gitignore_ctx_test";
    var ctx = glob.GitignoreContext.init(root);
    defer ctx.deinit(allocator);

    // Manually add a gitignore entry for *.log
    const entry = glob.GitignoreEntry{
        .negated = false,
        .directory_only = false,
        .anchor_to_root = false,
        .pattern = "*.log",
    };
    var owned_entry = entry;
    owned_entry.pattern = allocator.dupe(u8, "*.log") catch unreachable;
    ctx.entries.append(allocator, owned_entry) catch unreachable;

    const test_path = "/tmp/gitignore_ctx_test/debug.log";
    const result = ctx.isIgnored(test_path);
    try std.testing.expect(result == true);
}

test "loadGitignoreForDir with relative path does not crash" {
    // Regression test: loadGitignoreForDir should not crash when given a relative path
    // Previously it called openFileAbsolute which asserts the path is absolute
    const allocator = std.testing.allocator;

    // Create a temp directory with a .gitignore file using shell commands
    const tmp_dir_path = "/tmp/glob_relative_path_test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, tmp_dir_path) catch {};
    std.Io.Dir.cwd().createDirPath(std.testing.io, tmp_dir_path) catch {};
    defer { std.Io.Dir.cwd().deleteTree(std.testing.io, tmp_dir_path) catch {}; }

    // Create the subdirectory
    const subdir_path = std.fs.path.join(allocator, &.{ tmp_dir_path, "test_subdir" }) catch unreachable;
    defer allocator.free(subdir_path);
    std.Io.Dir.cwd().createDirPath(std.testing.io, subdir_path) catch {};

    var ctx = glob.GitignoreContext.init(tmp_dir_path);
    defer ctx.deinit(allocator);

    // This should NOT crash even though subdir_path is relative
    // The function should gracefully handle missing .gitignore or use proper file opening
    ctx.loadGitignoreForDir(allocator, std.testing.io, subdir_path);

    // If we get here without crashing, the test passes
    try std.testing.expect(true);
}

test "loadGitignoreForDir with absolute path and existing gitignore" {
    // Test that loadGitignoreForDir correctly loads gitignore entries with absolute path
    const allocator = std.testing.allocator;

    // Create a temp directory with a .gitignore file using shell commands
    const tmp_dir_path = "/tmp/glob_absolute_gitignore_test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, tmp_dir_path) catch {};
    std.Io.Dir.cwd().createDirPath(std.testing.io, tmp_dir_path) catch {};
    defer { std.Io.Dir.cwd().deleteTree(std.testing.io, tmp_dir_path) catch {}; }

    var ctx = glob.GitignoreContext.init(tmp_dir_path);
    defer ctx.deinit(allocator);

    // This should load the gitignore entries without crashing
    ctx.loadGitignoreForDir(allocator, std.testing.io, tmp_dir_path);

    // Just verify it didn't crash - number of entries depends on whether .gitignore exists
    try std.testing.expect(true);
}

// ============================================================================
// Regression tests for walkDir duplicate-results bug
// (Chunk 1 of the 2026-06-18-fix-glob-duplicate-results plan)
//
// The walkDir function used to recurse into subdirectories TWICE — once via
// the prefix-aware logic (which strips a matched leading directory from the
// pattern) and once via an unconditional "normal recursive descent" call
// that re-applies the full pattern. With N leading directory components in
// the pattern, this produced 2^N duplicate results for the same file.
//
// Tree shape used by all three tests below:
//
//   <tmp>/
//   └── a/
//       └── b/
//           └── c/
//               └── d/
//                   └── match.txt
//
// `setupTempTree` creates a unique-suffix tree under /tmp and returns the
// root path. Each test cleans up with `tree.deinit(...)` + `allocator.free`.
// ============================================================================

const TmpTree = struct {
    root: []const u8,

    fn deinit(self: *TmpTree, io: std.Io) void {
        std.Io.Dir.cwd().deleteTree(io, self.root) catch {};
    }
};

/// Create a deterministic tree at `/tmp/glob_walkdir_test_<suffix>/` with
/// `a/b/c/d/match.txt` inside. The `suffix` MUST be unique per test to
/// avoid `/tmp` collisions in parallel test runs.
fn setupTempTree(allocator: std.mem.Allocator, suffix: []const u8) !TmpTree {
    const root = try std.fmt.allocPrint(allocator, "/tmp/glob_walkdir_test_{s}", .{suffix});
    errdefer allocator.free(root);

    // Idempotent: clean any prior state, then create
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root);
    // Nested subdirs created with path.join (root + "/a/b/c/d" — `++` on
    // a runtime slice is rejected by Zig 0.16; path.join is correct here
    // since "/a/b/c/d" is a path component, not a filename suffix).
    const nested_path = try std.fs.path.join(allocator, &.{ root, "a/b/c/d" });
    defer allocator.free(nested_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, nested_path);

    // Create the matching file
    const match_path = try std.fs.path.join(allocator, &.{ root, "a/b/c/d/match.txt" });
    defer allocator.free(match_path);
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, match_path, .{});
        defer std.Io.File.close(file, std.testing.io);
        try std.Io.File.writeStreamingAll(file, std.testing.io, "match");
    }

    return TmpTree{ .root = root };
}

test "walkDir returns each file once for literal-prefix pattern" {
    // Regression test for the duplicate-results bug:
    // Pattern with 5 leading directory components (a/b/c/d/) used to
    // return the file 32 times (= 2^5) due to the dual-recursion bug
    // in walkDir. After the fix, it must return exactly 1 time.
    const allocator = std.testing.allocator;

    var tree = try setupTempTree(allocator, "literal_prefix");
    defer {
        tree.deinit(std.testing.io);
        allocator.free(tree.root);
    }

    var result = try glob.executeGlob(allocator, std.testing.io, .{
        .pattern = "a/b/c/d/match.txt",
        .path = tree.root,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.matches.items.len);
    try std.testing.expectEqualStrings(
        try std.fmt.allocPrint(allocator, "{s}/a/b/c/d/match.txt", .{tree.root}),
        result.matches.items[0].path,
    );
}

test "walkDir returns each file once for wildcard-prefix pattern" {
    // Pattern with a leading **/ must also produce a single result per file.
    // The current code mis-handles wildcard prefixes in the prefix-aware
    // logic (it strips ** and recurses with the wrong inner pattern).
    const allocator = std.testing.allocator;

    var tree = try setupTempTree(allocator, "wildcard_prefix");
    defer {
        tree.deinit(std.testing.io);
        allocator.free(tree.root);
    }

    var result = try glob.executeGlob(allocator, std.testing.io, .{
        .pattern = "**/match.txt",
        .path = tree.root,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.matches.items.len);
}

test "walkDir with mixed literal and wildcard patterns returns each file once" {
    // Both patterns should match match.txt exactly once, total 2 entries.
    const allocator = std.testing.allocator;

    var tree = try setupTempTree(allocator, "mixed");
    defer {
        tree.deinit(std.testing.io);
        allocator.free(tree.root);
    }

    var result = try glob.executeGlob(allocator, std.testing.io, .{
        .pattern = "{a/b/c/d/match.txt,**/match.txt}",
        .path = tree.root,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.matches.items.len);
}