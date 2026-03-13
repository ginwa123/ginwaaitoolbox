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

test "search: head returns first N matches" {
    const allocator = std.testing.allocator;

    // Create a test file with 10 matching lines
    const test_content = "line1: match\nline2: match\nline3: match\nline4: match\nline5: match\nline6: match\nline7: match\nline8: match\nline9: match\nline10: match\n";
    const test_file = try std.fs.cwd().createFile("test_search_head.txt", .{});
    defer {
        test_file.close();
        std.fs.cwd().deleteFile("test_search_head.txt") catch {};
    }
    try test_file.writeAll(test_content);

    var result = try searchMod.executeSearch(allocator, .{
        .pattern = "match",
        .path = "test_search_head.txt",
        .max_results = null,
        .head = 3,
        .tail = null,
    });
    defer result.deinit(allocator);

    // Should return exactly 3 matches (first 3)
    try std.testing.expectEqual(@as(usize, 3), result.matches.items.len);
    // First match should be line 1
    try std.testing.expectEqual(@as(usize, 1), result.matches.items[0].line_number);
}

test "search: tail returns last N matches" {
    const allocator = std.testing.allocator;

    // Create a test file with 10 matching lines
    const test_content = "line1: match\nline2: match\nline3: match\nline4: match\nline5: match\nline6: match\nline7: match\nline8: match\nline9: match\nline10: match\n";
    const test_file = try std.fs.cwd().createFile("test_search_tail.txt", .{});
    defer {
        test_file.close();
        std.fs.cwd().deleteFile("test_search_tail.txt") catch {};
    }
    try test_file.writeAll(test_content);

    var result = try searchMod.executeSearch(allocator, .{
        .pattern = "match",
        .path = "test_search_tail.txt",
        .max_results = null,
        .head = null,
        .tail = 3,
    });
    defer result.deinit(allocator);

    // Should return exactly 3 matches (last 3)
    try std.testing.expectEqual(@as(usize, 3), result.matches.items.len);
    // Last match should be line 10
    try std.testing.expectEqual(@as(usize, 10), result.matches.items[2].line_number);
}

test "search: head and tail mutually exclusive returns error" {
    const allocator = std.testing.allocator;

    const test_content = "line1: match\nline2: match\n";
    const test_file = try std.fs.cwd().createFile("test_search_both.txt", .{});
    defer {
        test_file.close();
        std.fs.cwd().deleteFile("test_search_both.txt") catch {};
    }
    try test_file.writeAll(test_content);

    const result = searchMod.executeSearch(allocator, .{
        .pattern = "match",
        .path = "test_search_both.txt",
        .max_results = null,
        .head = 1,
        .tail = 1,
    });

    // Should return error
    try std.testing.expectError(error.HeadAndTailMutuallyExclusive, result);
}

test "search: head works with max_results" {
    const allocator = std.testing.allocator;

    const test_content = "line1: match\nline2: match\nline3: match\nline4: match\nline5: match\n";
    const test_file = try std.fs.cwd().createFile("test_search_head_max.txt", .{});
    defer {
        test_file.close();
        std.fs.cwd().deleteFile("test_search_head_max.txt") catch {};
    }
    try test_file.writeAll(test_content);

    var result = try searchMod.executeSearch(allocator, .{
        .pattern = "match",
        .path = "test_search_head_max.txt",
        .max_results = 5,
        .head = 2,
        .tail = null,
    });
    defer result.deinit(allocator);

    // max_results=5 limits to first 5, then head=2 takes first 2 of those
    try std.testing.expectEqual(@as(usize, 2), result.matches.items.len);
}

test "search: tail works with max_results" {
    const allocator = std.testing.allocator;

    const test_content = "line1: match\nline2: match\nline3: match\nline4: match\nline5: match\n";
    const test_file = try std.fs.cwd().createFile("test_search_tail_max.txt", .{});
    defer {
        test_file.close();
        std.fs.cwd().deleteFile("test_search_tail_max.txt") catch {};
    }
    try test_file.writeAll(test_content);

    var result = try searchMod.executeSearch(allocator, .{
        .pattern = "match",
        .path = "test_search_tail_max.txt",
        .max_results = 5,
        .head = null,
        .tail = 2,
    });
    defer result.deinit(allocator);

    // max_results=5 limits to first 5, then tail=2 takes last 2 of those
    try std.testing.expectEqual(@as(usize, 2), result.matches.items.len);
    // Should be lines 4 and 5 (the last 2 of the first 5)
    try std.testing.expectEqual(@as(usize, 4), result.matches.items[0].line_number);
    try std.testing.expectEqual(@as(usize, 5), result.matches.items[1].line_number);
}

test "searchResultToString: returns compressed XML format" {
    const allocator = std.testing.allocator;

    // Create a SearchResult with test matches
    var matches = std.ArrayList(searchMod.SearchMatch).empty;
    defer matches.deinit(allocator);

    const file1 = try allocator.dupe(u8, "test1.zig");
    errdefer allocator.free(file1);
    const snippet1 = try allocator.dupe(u8, "const x = 5;");
    errdefer allocator.free(snippet1);
    try matches.append(allocator, .{
        .file = file1,
        .line_number = 10,
        .file_total_lines = 100,
        .snippet = snippet1,
    });

    const file2 = try allocator.dupe(u8, "test2.zig");
    errdefer allocator.free(file2);
    const snippet2 = try allocator.dupe(u8, "fn main() void {}");
    errdefer allocator.free(snippet2);
    try matches.append(allocator, .{
        .file = file2,
        .line_number = 25,
        .file_total_lines = 50,
        .snippet = snippet2,
    });

    const result = searchMod.SearchResult{
        .matches = matches,
        .content = try allocator.dupe(u8, "test content"),
    };
    defer {
        // Free the match strings since SearchResult.deinit doesn't free them
        for (result.matches.items) |m| {
            allocator.free(m.file);
            allocator.free(m.snippet);
        }
        allocator.free(result.content);
    }

    const xml_output = try searchMod.searchResultToString(allocator, result);
    defer allocator.free(xml_output);

    // Verify compressed format is used
    try std.testing.expect(std.mem.indexOf(u8, xml_output, "<m>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml_output, "</m>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml_output, "<f>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml_output, "<l>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml_output, "<t>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml_output, "<s>") != null);

    // Verify old verbose format is NOT used
    try std.testing.expect(std.mem.indexOf(u8, xml_output, "<match>") == null);
    try std.testing.expect(std.mem.indexOf(u8, xml_output, "<file>") == null);
    try std.testing.expect(std.mem.indexOf(u8, xml_output, "<line_number>") == null);
    try std.testing.expect(std.mem.indexOf(u8, xml_output, "<file_total_lines>") == null);
    try std.testing.expect(std.mem.indexOf(u8, xml_output, "<snippet>") == null);

    // Verify content is present
    try std.testing.expect(std.mem.indexOf(u8, xml_output, "test1.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml_output, "test2.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml_output, "const x = 5;") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml_output, "fn main() void {}") != null);
}
