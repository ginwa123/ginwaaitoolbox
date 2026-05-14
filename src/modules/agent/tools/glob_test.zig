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