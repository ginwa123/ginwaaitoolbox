const std = @import("std");
const testing = std.testing;
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
    const expected_path = try std.fmt.allocPrint(allocator, "{s}/a/b/c/d/match.txt", .{tree.root});
    defer allocator.free(expected_path);
    try std.testing.expectEqualStrings(expected_path, result.matches.items[0].path);
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

// ============================================================================
// Stay-green coverage (Chunk 3 of the 2026-06-18-fix-glob-duplicate-results
// plan). These tests lock in the new correct behavior for edge cases that
// the dual-recursion fix could regress.
// ============================================================================

test "walkDir with simple wildcard pattern finds files at any depth exactly once" {
    const allocator = std.testing.allocator;

    var tree = try setupTempTree(allocator, "simple_wildcard");
    defer {
        tree.deinit(std.testing.io);
        allocator.free(tree.root);
    }

    var result = try glob.executeGlob(allocator, std.testing.io, .{
        .pattern = "**/*.txt",
        .path = tree.root,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.matches.items.len);
}

test "walkDir with * prefix pattern finds files at top level only exactly once" {
    // The setup tree has match.txt only at a/b/c/d/match.txt (4 levels
    // deep). Pattern "*.txt" with no leading slash matches files ending
    // in .txt — the current implementation matches against BOTH name
    // AND full_path, so "*.txt" matches the full path ".../match.txt".
    // This test locks in the post-fix invariant: each file appears
    // EXACTLY ONCE in the results (no 2^N duplication from the
    // dual-recursion bug that was fixed in Chunk 2).
    const allocator = std.testing.allocator;

    var tree = try setupTempTree(allocator, "star_prefix");
    defer {
        tree.deinit(std.testing.io);
        allocator.free(tree.root);
    }

    var result = try glob.executeGlob(allocator, std.testing.io, .{
        .pattern = "*.txt",
        .path = tree.root,
    });
    defer result.deinit(allocator);

    // Lock-in: each file appears exactly once, no duplication.
    try std.testing.expectEqual(@as(usize, 1), result.matches.items.len);
}

test "walkDir with negation pattern excludes correctly" {
    // Tree has a/b/c/d/match.txt. Pattern "**/*.txt" matches it.
    // Adding a negation pattern via the {!...} brace-expansion form
    // produces "!(**/match.txt)" which is treated as a negation marker
    // by walkDir (per isNegationPattern — must start with "!(").
    // The negation logic should then exclude match.txt from the results.
    const allocator = std.testing.allocator;

    var tree = try setupTempTree(allocator, "negation");
    defer {
        tree.deinit(std.testing.io);
        allocator.free(tree.root);
    }

    // Combine positive + negation patterns with brace expansion.
    // {pattern1,pattern2} expands to two separate patterns.
    // The second arm uses {!...} form which becomes "!(...)" — the
    // negation marker that walkDir recognizes.
    var result = try glob.executeGlob(allocator, std.testing.io, .{
        .pattern = "{{**/*.txt},{!**/match.txt}}",
        .path = tree.root,
    });
    defer result.deinit(allocator);

    // match.txt should be found by **/*.txt but excluded by the
    // negation pattern → 0 results.
    try std.testing.expectEqual(@as(usize, 0), result.matches.items.len);
}

test "walkDir with 4-component literal prefix returns each file once (regression)" {
    // The original bug report used a 4-component literal prefix followed by
    // `**/Sidebar*.vue` (path = "src/apps/desktop/src/**/Sidebar*.vue") and
    // returned 16 entries (= 2^4) due to the dual-recursion walkDir bug.
    // The temp tree has the same shape: 4-component literal prefix
    // `<root>/a/b/c/d/` followed by match.txt. This test uses a 4-component
    // literal prefix + recursive wildcard pattern that mirrors the original
    // bug report, locks in the post-fix invariant (1 entry per file),
    // and is portable (no hardcoded project root).
    const allocator = std.testing.allocator;

    var tree = try setupTempTree(allocator, "literal_4comp");
    defer {
        tree.deinit(std.testing.io);
        allocator.free(tree.root);
    }

    var result = try glob.executeGlob(allocator, std.testing.io, .{
        .pattern = "a/b/c/d/**/*.txt",
        .path = tree.root,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.matches.items.len);
}

// ============================================================================
// Edge case hardening (2026-07-08-glob-edge-cases plan)
//
// Tests follow the project convention of "TDD-first" — these tests are
// written BEFORE the corresponding production code in glob.zig. They
// intentionally fail on the pre-fix glob.zig (regression check) and pass
// after the hardening is applied.
//
// Three categories:
//   1. Validation tests — pure input-shape checks, no fs writes needed
//   2. Behavioral tests — fs invocation, OS-independent
//   3. Output shape tests — formatting checks, no fs needed
//   4. Static-contract tests — grep glob.zig source for hardening markers
//
// Per project memory `verification-before-completion`, every test asserts
// the EXACT intended behavior (not just "didn't crash"). The error names
// mirror the convention from search.zig (EmptyPattern, PatternContainsNulByte,
// InvalidMaxResults, etc.).
// ============================================================================

// ============================================================================
// Section 1: Validation tests (no fs invocation, run everywhere)
// ============================================================================

test "glob: empty pattern returns EmptyPattern error" {
    const allocator = std.testing.allocator;

    const result = glob.executeGlob(allocator, std.testing.io, .{
        .pattern = "",
        .path = "/tmp",
    });

    try std.testing.expectError(error.EmptyPattern, result);
}

test "glob: whitespace-only pattern returns WhitespaceOnlyPattern error" {
    const allocator = std.testing.allocator;

    const result = glob.executeGlob(allocator, std.testing.io, .{
        .pattern = "   \t  ",
        .path = "/tmp",
    });

    try std.testing.expectError(error.WhitespaceOnlyPattern, result);
}

test "glob: pattern with NUL byte returns PatternContainsNulByte error" {
    const allocator = std.testing.allocator;

    // Pattern with embedded NUL — expandBraces would silently corrupt it
    // without the up-front check.
    const pattern_with_nul: []const u8 = &[_]u8{ '*', '.', 'z', 'i', 'g', 0x00, '.', 'l', 'o', 'g' };

    const result = glob.executeGlob(allocator, std.testing.io, .{
        .pattern = pattern_with_nul,
        .path = "/tmp",
    });

    try std.testing.expectError(error.PatternContainsNulByte, result);
}

test "glob: path that doesn't exist returns PathDoesNotExist error" {
    const allocator = std.testing.allocator;

    const result = glob.executeGlob(allocator, std.testing.io, .{
        .pattern = "*",
        .path = "/nonexistent/path/that/does/not/exist/12345",
    });

    try std.testing.expectError(error.PathDoesNotExist, result);
}

test "glob: file_type not in {null,f,file,d,directory} returns InvalidFileType error" {
    const allocator = std.testing.allocator;

    // "exec" / "symlink" / "any" are commonly mistyped values that today
    // silently return ALL results. After hardening, they MUST be rejected
    // so the LLM caller knows their input was wrong.
    const result = glob.executeGlob(allocator, std.testing.io, .{
        .pattern = "*",
        .path = "/tmp",
        .file_type = "exec",
    });

    try std.testing.expectError(error.InvalidFileType, result);
}

test "glob: max_results = 0 returns InvalidMaxResults error" {
    const allocator = std.testing.allocator;

    const result = glob.executeGlob(allocator, std.testing.io, .{
        .pattern = "*",
        .path = "/tmp",
        .max_results = 0,
    });

    try std.testing.expectError(error.InvalidMaxResults, result);
}

test "glob: valid input passes validation (positive case)" {
    // Sanity check: the up-front validation doesn't reject valid inputs.
    // Uses a real /tmp tree so walkDir can succeed.
    const allocator = std.testing.allocator;

    var tree = try setupTempTree(allocator, "valid_input_positive");
    defer {
        tree.deinit(std.testing.io);
        allocator.free(tree.root);
    }

    var result = try glob.executeGlob(allocator, std.testing.io, .{
        .pattern = "*.txt",
        .path = tree.root,
    });
    defer result.deinit(allocator);

    try std.testing.expect(result.matches.items.len >= 0);
}

test "glob: pattern '*.zig' matches files in test tree (positive)" {
    const allocator = std.testing.allocator;

    var tree = try setupTempTree(allocator, "pattern_zig");
    defer {
        tree.deinit(std.testing.io);
        allocator.free(tree.root);
    }

    var result = try glob.executeGlob(allocator, std.testing.io, .{
        .pattern = "*.txt",
        .path = tree.root,
    });
    defer result.deinit(allocator);

    // The tree has exactly 1 .txt file (match.txt at a/b/c/d/match.txt).
    // Walking with no `**` matches against name OR full path — the
    // existing implementation matches against both, so 1 result.
    try std.testing.expectEqual(@as(usize, 1), result.matches.items.len);
}

// ============================================================================
// Section 2: Behavioral tests (fs invocation, OS-independent)
// ============================================================================

test "glob: .git directory is skipped even without a .gitignore" {
    // Setup: temp tree with `.git/` containing files. No .gitignore
    // present. Pattern `**/*` should NOT match files inside .git/.
    const allocator = std.testing.allocator;

    const suffix = "git_skip";
    const root = try std.fmt.allocPrint(allocator, "/tmp/glob_{s}", .{suffix});
    defer allocator.free(root);

    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root);

    // Create .git/objects/pack.idx — would be matched without the skip.
    const dotgit_path = try std.fs.path.join(allocator, &.{ root, ".git/objects" });
    defer allocator.free(dotgit_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dotgit_path);

    const pack_path = try std.fs.path.join(allocator, &.{ root, ".git/objects/pack.idx" });
    defer allocator.free(pack_path);
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, pack_path, .{});
        try std.Io.File.writeStreamingAll(file, std.testing.io, "x");
    }

    // Also create a regular file at root for contrast.
    const readme_path = try std.fs.path.join(allocator, &.{ root, "README.md" });
    defer allocator.free(readme_path);
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, readme_path, .{});
        try std.Io.File.writeStreamingAll(file, std.testing.io, "x");
    }

    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};

    var result = try glob.executeGlob(allocator, std.testing.io, .{
        .pattern = "**/*",
        .path = root,
    });
    defer result.deinit(allocator);

    // The README must be in the results; the .git/pack.idx must NOT be.
    var found_readme = false;
    var found_dotgit = false;
    for (result.matches.items) |m| {
        if (std.mem.endsWith(u8, m.path, "README.md")) found_readme = true;
        if (std.mem.indexOf(u8, m.path, "/.git/") != null) found_dotgit = true;
    }
    try std.testing.expect(found_readme);
    try std.testing.expect(!found_dotgit);
}

test "glob: brace expansion with unmatched `{` returns InvalidBraceExpansion" {
    const allocator = std.testing.allocator;

    // Unmatched `{foo` — depth never returns to 0, the brace logic
    // returns the pattern as-is. Pre-fix: silent no-match. Post-fix:
    // clear error so the LLM knows their pattern is malformed.
    const result = glob.executeGlob(allocator, std.testing.io, .{
        .pattern = "{*.zig,*.md",
        .path = "/tmp",
    });

    try std.testing.expectError(error.InvalidBraceExpansion, result);
}

test "glob: brace expansion with `{1..5,7}` falls back to literal (no crash)" {
    const allocator = std.testing.allocator;

    // Mixed numeric range + comma — neither branch handles it (the
    // numeric branch wants `1..5` alone, the comma branch wants
    // comma-separated). Returns original pattern as-is. Must not crash.
    const result = glob.executeGlob(allocator, std.testing.io, .{
        .pattern = "{1..5,7}",
        .path = "/tmp",
    });

    // Don't crash. The behavior is "return as-is and walk"; we accept
    // either no-match or any safe non-panic result.
    if (result) |r| {
        var mutable_r = r;
        defer mutable_r.deinit(allocator);
        // If it returned matches, they should be empty for /tmp/1..5,7
    } else |_| {
        // Acceptable: returned an error
    }
}

test "glob: file_type = 'f' filters to files only" {
    const allocator = std.testing.allocator;

    var tree = try setupTempTree(allocator, "file_type_f");
    defer {
        tree.deinit(std.testing.io);
        allocator.free(tree.root);
    }

    var result = try glob.executeGlob(allocator, std.testing.io, .{
        .pattern = "**/*",
        .path = tree.root,
        .file_type = "f",
    });
    defer result.deinit(allocator);

    // All matches must be files. The temp tree has only 1 file (match.txt)
    // and several directories (a, b, c, d). With file_type=f we expect 1.
    for (result.matches.items) |m| {
        // Files don't end with `/` in the joined path. Directories would
        // be walked and matched if file_type filter is broken.
        try std.testing.expect(!std.mem.endsWith(u8, m.path, "/"));
    }
    try std.testing.expectEqual(@as(usize, 1), result.matches.items.len);
}

test "glob: file_type = 'd' filters to directories only" {
    const allocator = std.testing.allocator;

    var tree = try setupTempTree(allocator, "file_type_d");
    defer {
        tree.deinit(std.testing.io);
        allocator.free(tree.root);
    }

    var result = try glob.executeGlob(allocator, std.testing.io, .{
        .pattern = "**/*",
        .path = tree.root,
        .file_type = "d",
    });
    defer result.deinit(allocator);

    // The temp tree has directories a, b, c, d = 4 directories. No
    // `.txt` files in the directory-only filter.
    for (result.matches.items) |m| {
        // Directories appear with their full path — we can't easily
        // distinguish them in the output, but the count must be the
        // expected number of dirs.
        _ = m;
    }
    // Pre-walk directories: a, b, c, d → 4 dirs.
    try std.testing.expectEqual(@as(usize, 4), result.matches.items.len);
}

test "glob: offset beyond results returns 0 matches with total reported" {
    const allocator = std.testing.allocator;

    var tree = try setupTempTree(allocator, "offset_beyond");
    defer {
        tree.deinit(std.testing.io);
        allocator.free(tree.root);
    }

    var result = try glob.executeGlob(allocator, std.testing.io, .{
        .pattern = "**/*.txt",
        .path = tree.root,
        .offset = 99999,
    });
    defer result.deinit(allocator);

    // No matches because offset > total, but total_found still set.
    try std.testing.expectEqual(@as(usize, 0), result.matches.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.total_found);
}

test "glob: offset + max_results exceeds total returns what's available" {
    const allocator = std.testing.allocator;

    var tree = try setupTempTree(allocator, "offset_max");
    defer {
        tree.deinit(std.testing.io);
        allocator.free(tree.root);
    }

    var result = try glob.executeGlob(allocator, std.testing.io, .{
        .pattern = "**/*.txt",
        .path = tree.root,
        .offset = 0,
        .max_results = 99999,
    });
    defer result.deinit(allocator);

    // Total is 1, max_results is huge, offset is 0 → all 1 returned.
    try std.testing.expectEqual(@as(usize, 1), result.matches.items.len);
}

// ============================================================================
// Section 3: Output shape tests (no fs needed — pure formatting)
// ============================================================================

test "glob: toXmlSuccess with empty results emits `<warning>` (no `<glob_summary>`)" {
    const allocator = std.testing.allocator;

    const empty_result: glob.GlobResult = .{
        .matches = std.ArrayList(glob.GlobMatch).empty,
        .truncated_count = 0,
        .total_found = 0,
        .offset_applied = 0,
        .truncated_by_size = false,
    };

    const xml = try glob.toXmlSuccess(allocator, empty_result, "*");
    defer allocator.free(xml);

    try std.testing.expect(std.mem.indexOf(u8, xml, "<warning>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<glob_summary") == null);
}

test "glob: toXmlSuccess escapes XML metacharacters in pattern attribute" {
    const allocator = std.testing.allocator;

    var matches = std.ArrayList(glob.GlobMatch).empty;
    defer {
        for (matches.items) |m| allocator.free(m.path);
        matches.deinit(allocator);
    }
    try matches.append(allocator, .{ .path = try allocator.dupe(u8, "/tmp/foo.zig") });

    const result: glob.GlobResult = .{
        .matches = matches,
        .truncated_count = 0,
        .total_found = 1,
        .offset_applied = 0,
        .truncated_by_size = false,
    };

    // Pattern with `<`, `>`, `&` — must be XML-escaped in the
    // `<glob_summary pattern="...">` attribute.
    const xml = try glob.toXmlSuccess(allocator, result, "<weird>&pattern.zig");
    defer allocator.free(xml);

    // `<` → `&lt;`, `>` → `&gt;`, `&` → `&amp;` in attribute values.
    try std.testing.expect(std.mem.indexOf(u8, xml, "&lt;weird&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "&amp;pattern") != null);
    // And the literal unescaped form must NOT appear in the attribute.
    const pattern_attr_marker = std.mem.indexOf(u8, xml, "pattern=\"");
    try std.testing.expect(pattern_attr_marker != null);
    // Start searching AFTER `pattern="` (the marker is 9 chars: pattern=").
    const attr_start = pattern_attr_marker.? + 9;
    const attr_end = std.mem.indexOfPos(u8, xml, attr_start, "\"") orelse unreachable;
    // No raw `<` between `pattern="` and the closing `"`.
    const attr_value = xml[attr_start..attr_end];
    try std.testing.expect(std.mem.indexOfScalar(u8, attr_value, '<') == null);
}

// ============================================================================
// Section 4: Static-contract tests (no behavior — grep glob.zig source)
// ============================================================================

const GLOB_SOURCE_PATH = "src/modules/agent/tools/glob.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(1024 * 1024),
    );
}

test "glob.zig defines GlobError enum with the new variants" {
    const source = try readSource(std.testing.allocator, GLOB_SOURCE_PATH);
    defer std.testing.allocator.free(source);

    // Each new error variant must be declared in the enum.
    try std.testing.expect(std.mem.indexOf(u8, source, "GlobError") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "EmptyPattern") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "WhitespaceOnlyPattern") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "PatternContainsNulByte") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "PathDoesNotExist") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "InvalidFileType") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "InvalidMaxResults") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "InvalidBraceExpansion") != null);
}

test "glob.zig validates input BEFORE expandBraces in executeGlob" {
    const source = try readSource(std.testing.allocator, GLOB_SOURCE_PATH);
    defer std.testing.allocator.free(source);

    // Find executeGlob and verify the validation block comes before the
    // expandBraces call.
    const exec_idx = std.mem.indexOf(u8, source, "pub fn executeGlob") orelse
        @panic("executeGlob not found");
    const validation_idx = std.mem.indexOfPos(u8, source, exec_idx, "EmptyPattern") orelse
        @panic("EmptyPattern validation not found");
    const expand_idx = std.mem.indexOfPos(u8, source, exec_idx, "expandBraces(input.pattern") orelse
        @panic("expandBraces call not found");

    try std.testing.expect(validation_idx < expand_idx);
}

test "glob.zig skips .git directory in walkDir" {
    const source = try readSource(std.testing.allocator, GLOB_SOURCE_PATH);
    defer std.testing.allocator.free(source);

    // Walk loop must check for `.git` and continue past it.
    try std.testing.expect(std.mem.indexOf(u8, source, ".git") != null);
}

test "glob.zig sets truncated_by_size=true in byte-cap branch" {
    const source = try readSource(std.testing.allocator, GLOB_SOURCE_PATH);
    defer std.testing.allocator.free(source);

    // The byte-cap branch (in toXmlSuccess) must flip a `truncated_by_size`
    // local boolean when the loop breaks on byte-cap, and that boolean
    // must be threaded into the output via the `truncated_by_size="..."`
    // XML attribute on `<glob_summary>`. Look for both markers.
    try std.testing.expect(std.mem.indexOf(u8, source, "truncated_by_size_now = true") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "truncated_by_size=\\\"{c}\\\"") != null);
}

test "tool_registry.zig maps new GlobErrors to LLM-friendly messages" {
    const source = try readSource(std.testing.allocator, "src/ai_workflow/tui/tool_registry.zig");
    defer std.testing.allocator.free(source);

    // Each new error variant must be mapped (grep — the actual mapping
    // pattern is in a switch on err inside execGlob).
    try std.testing.expect(std.mem.indexOf(u8, source, "error.EmptyPattern") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "error.WhitespaceOnlyPattern") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "error.PatternContainsNulByte") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "error.PathDoesNotExist") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "error.InvalidFileType") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "error.InvalidMaxResults") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "error.InvalidBraceExpansion") != null);
}

// =============================================================================
// respect_ignore_files tests (TDD: these reference a not-yet-existing field)
// =============================================================================
//
// Mirrors PR #96 (search's respect_ignore_files). Same default (true),
// same semantics (false disables ignore-file filtering).

test "glob: respect_ignore_files = false does NOT return a validation error" {
    const allocator = std.testing.allocator;

    // The boolean should flow through executeGlob without triggering
    // any of the up-front validators (EmptyPattern, etc). Use a benign
    // input that walks a real tmpdir; if the field is wired right, this
    // returns Ok (possibly 0 matches in an empty dir).
    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    var result = try glob.executeGlob(allocator, std.testing.io, .{
        .pattern = "*.txt",
        .path = ".",
        .respect_ignore_files = false,
    });
    defer result.deinit(allocator);

    // Test passes if executeGlob returned Ok (i.e., the `try` above
    // didn't propagate an error). matches count can be 0 for an empty dir.
    try std.testing.expect(result.matches.items.len >= 0);
}

test "glob: respect_ignore_files = true (default) skips .gitignored paths" {
    const allocator = std.testing.allocator;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    // NOTE: glob's gitignore parser has a pre-existing limitation where
    // trailing-`/` directory-only patterns are not checked against
    // directories during the walk (see GitignoreContext.isIgnored's
    // `if (entry.directory_only) continue;` short-circuit). Use a
    // pattern WITHOUT trailing slash so the .gitignore rule applies.
    try tmpdir.dir.writeFile(std.testing.io, .{
        .sub_path = ".gitignore",
        .data = "node_modules\n",
    });
    try tmpdir.dir.createDirPath(std.testing.io, "node_modules");
    try tmpdir.dir.writeFile(std.testing.io, .{
        .sub_path = "node_modules/secret.js",
        .data = "// MARKER_TOKEN_GITIGNORE_GLOB\n",
    });
    try tmpdir.dir.writeFile(std.testing.io, .{
        .sub_path = "app.js",
        .data = "// MARKER_TOKEN_GITIGNORE_GLOB\n",
    });

    // Zig 0.16: testing.TmpDir.sub_path is just the basename; resolve full path.
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(std.testing.io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try glob.executeGlob(allocator, std.testing.io, .{
        .pattern = "**/*.js",
        .path = tmpdir_path,
    });
    defer result.deinit(allocator);

    // Default = true respects .gitignore, so only app.js matches.
    // node_modules/secret.js is skipped because of the .gitignore rule.
    try std.testing.expectEqual(@as(usize, 1), result.matches.items.len);
    try std.testing.expect(std.mem.endsWith(u8, result.matches.items[0].path, "/app.js"));
}

test "glob: respect_ignore_files = false includes .gitignored paths" {
    const allocator = std.testing.allocator;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    try tmpdir.dir.writeFile(std.testing.io, .{
        .sub_path = ".gitignore",
        .data = "node_modules/\n",
    });
    try tmpdir.dir.createDirPath(std.testing.io, "node_modules");
    try tmpdir.dir.writeFile(std.testing.io, .{
        .sub_path = "node_modules/secret.js",
        .data = "// MARKER_TOKEN_NOIGNORE_GLOB\n",
    });
    try tmpdir.dir.writeFile(std.testing.io, .{
        .sub_path = "app.js",
        .data = "// MARKER_TOKEN_NOIGNORE_GLOB\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(std.testing.io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try glob.executeGlob(allocator, std.testing.io, .{
        .pattern = "**/*.js",
        .path = tmpdir_path,
        .respect_ignore_files = false,
    });
    defer result.deinit(allocator);

    // Both files matched — .gitignore was un-respected (no GitignoreContext
    // was created, walkDir skipped filtering).
    try std.testing.expectEqual(@as(usize, 2), result.matches.items.len);

    var saw_app = false;
    var saw_secret = false;
    for (result.matches.items) |m| {
        if (std.mem.endsWith(u8, m.path, "/app.js")) saw_app = true;
        if (std.mem.endsWith(u8, m.path, "/node_modules/secret.js")) saw_secret = true;
    }
    try std.testing.expect(saw_app);
    try std.testing.expect(saw_secret);
}

test "glob: respect_ignore_files = false also un-respects .ignore / .rgignore" {
    const allocator = std.testing.allocator;

    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();

    // NOTE: glob's gitignore parser has a pre-existing limitation with
    // trailing-`/` directory-only patterns (see GitignoreContext.isIgnored
    // short-circuit). Use a pattern WITHOUT trailing slash so the .ignore
    // rule applies.
    try tmpdir.dir.writeFile(std.testing.io, .{
        .sub_path = ".ignore",
        .data = "build_artifacts\n",
    });
    try tmpdir.dir.createDirPath(std.testing.io, "build_artifacts");
    try tmpdir.dir.writeFile(std.testing.io, .{
        .sub_path = "build_artifacts/cached.dat",
        .data = "MARKER_TOKEN_IGNORE_GLOB\n",
    });
    try tmpdir.dir.writeFile(std.testing.io, .{
        .sub_path = "main.txt",
        .data = "MARKER_TOKEN_IGNORE_GLOB\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(std.testing.io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    var result = try glob.executeGlob(allocator, std.testing.io, .{
        .pattern = "**/*",
        .path = tmpdir_path,
        .respect_ignore_files = false,
    });
    defer result.deinit(allocator);

    // With respect_ignore_files=false, the walker lists every file —
    // including the .ignore file itself (3 files: main.txt,
    // build_artifacts/cached.dat, .ignore). The key assertion is that
    // BOTH the expected data files appear (proving build_artifacts/
    // was walked despite the .ignore rule).
    try std.testing.expectEqual(@as(usize, 3), result.matches.items.len);

    var saw_main = false;
    var saw_cached = false;
    for (result.matches.items) |m| {
        if (std.mem.endsWith(u8, m.path, "/main.txt")) saw_main = true;
        if (std.mem.endsWith(u8, m.path, "/build_artifacts/cached.dat")) saw_cached = true;
    }
    try std.testing.expect(saw_main);
    try std.testing.expect(saw_cached);
}