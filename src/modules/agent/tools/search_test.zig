const std = @import("std");
const searchMod = @import("search.zig");

test "search: basic pattern search in single file" {
    const allocator = std.testing.allocator;

    // Create a test file with known content
    const test_content = "line1: hello world\nline2: test pattern\nline3: another match\nline4: end\n";
    const test_file = try std.fs.cwd().createFile("test_search.txt", .{});
    defer {
        test_file.close();
        std.fs.cwd().deleteFile("test_search.txt") catch {};
    }
    try test_file.writeAll(test_content);

    // Search for "pattern"
    var result = try searchMod.executeSearch(allocator, .{
        .pattern = "pattern",
        .path = "test_search.txt",
        .max_results = null,
    });
    defer result.deinit(allocator);

    // Should find "test pattern" on line 2
    try std.testing.expect(result.matches.items.len >= 1);
    const first_match = result.matches.items[0];
    try std.testing.expectEqual(@as(usize, 2), first_match.line_number);
    try std.testing.expect(std.mem.indexOf(u8, first_match.snippet, "pattern") != null);
}

test "search: pattern not found returns empty matches" {
    const allocator = std.testing.allocator;

    const test_content = "line1: hello world\nline2: test data\nline3: end\n";
    const test_file = try std.fs.cwd().createFile("test_search_notfound.txt", .{});
    defer {
        test_file.close();
        std.fs.cwd().deleteFile("test_search_notfound.txt") catch {};
    }
    try test_file.writeAll(test_content);

    var result = try searchMod.executeSearch(allocator, .{
        .pattern = "nonexistent",
        .path = "test_search_notfound.txt",
        .max_results = null,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), result.matches.items.len);
}

test "search: regex pattern with special characters" {
    const allocator = std.testing.allocator;

    const test_content = "line1: test123\nline2: abc456def\nline3: xyz789\nline4: end\n";
    const test_file = try std.fs.cwd().createFile("test_search_regex.txt", .{});
    defer {
        test_file.close();
        std.fs.cwd().deleteFile("test_search_regex.txt") catch {};
    }
    try test_file.writeAll(test_content);

    // Search for pattern matching digits
    var result = try searchMod.executeSearch(allocator, .{
        .pattern = "[0-9]+",
        .path = "test_search_regex.txt",
        .max_results = null,
    });
    defer result.deinit(allocator);

    // Should find all lines with digits
    try std.testing.expect(result.matches.items.len >= 3);
}

test "search: max_results limits returned matches" {
    const allocator = std.testing.allocator;

    const test_content = "line1: match\nline2: match\nline3: match\nline4: match\nline5: match\n";
    const test_file = try std.fs.cwd().createFile("test_search_limit.txt", .{});
    defer {
        test_file.close();
        std.fs.cwd().deleteFile("test_search_limit.txt") catch {};
    }
    try test_file.writeAll(test_content);

    var result = try searchMod.executeSearch(allocator, .{
        .pattern = "match",
        .path = "test_search_limit.txt",
        .max_results = 2,
    });
    defer result.deinit(allocator);

    // Should return exactly 2 matches
    try std.testing.expectEqual(@as(usize, 2), result.matches.items.len);
}

test "search: returns matched_lines for file" {
    const allocator = std.testing.allocator;

    const test_content = "line1\nline2\nline3\nline4\nline5\n";
    const test_file = try std.fs.cwd().createFile("test_search_total.txt", .{});
    defer {
        test_file.close();
        std.fs.cwd().deleteFile("test_search_total.txt") catch {};
    }
    try test_file.writeAll(test_content);

    var result = try searchMod.executeSearch(allocator, .{
        .pattern = "line",
        .path = "test_search_total.txt",
        .max_results = null,
    });
    defer result.deinit(allocator);

    // All 5 lines match "line", so file_total_lines should be 5
    // (Note: This is matched_lines from ripgrep, not total file lines)
    if (result.matches.items.len > 0) {
        try std.testing.expectEqual(@as(usize, 5), result.matches.items[0].file_total_lines);
    }
}
