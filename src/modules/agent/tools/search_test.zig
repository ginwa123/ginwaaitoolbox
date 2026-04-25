const std = @import("std");
const search = @import("search.zig");

test "search returns warning XML when no matches found" {
    const allocator = std.testing.allocator;

    // Use a unique file path
    const test_path = "/tmp/search_test_tmp_xyz789_unique/test.txt";

    // Ensure parent directory exists
    try std.fs.cwd().makePath("/tmp/search_test_tmp_xyz789_unique");
    defer _ = std.fs.cwd().deleteTree("/tmp/search_test_tmp_xyz789_unique") catch {};

    // Create a file with some content
    const test_file = try std.fs.cwd().createFile(test_path, .{});
    try test_file.writeAll("hello world\nfoo bar\n");
    test_file.close();

    // Search for a pattern that definitely doesn't exist in this file
    const input = search.SearchInput{
        .pattern = "definitely_no_match_xyz123456_UNIQUE_PATTERN_999",
        .path = test_path,
        .max_results = 50,
        .head = null,
        .tail = null,
        .max_output = 10000,
    };

    var result = try search.execute_search(allocator, input);

    // The raw content from execute_search should contain the warning XML
    const has_warning = std.mem.indexOf(u8, result.content, "<warning>") != null;

    // And it should contain "not found" text
    const has_not_found = std.mem.indexOf(u8, result.content, "not found") != null;

    // Clean up
    result.deinit(allocator);

    // Verify warning is present
    try std.testing.expect(has_warning);
    try std.testing.expect(has_not_found);
}

test "search_result_to_string_grouped returns wrapper for no matches" {
    const allocator = std.testing.allocator;

    var empty_matches = std.ArrayList(search.SearchMatch).empty;
    defer empty_matches.deinit(allocator);

    const result = search.SearchResult{
        .matches = empty_matches,
        .content = "<warning>pattern not found</warning>",
    };

    // search_result_to_string_grouped should return wrapper with pattern/path even for no matches
    const output = try search.search_result_to_string_grouped(allocator, result, "test_pattern", "src/");
    defer allocator.free(output);

    // Should contain the wrapper tags with pattern and path
    try std.testing.expect(std.mem.indexOf(u8, output, "<search") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "</search>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "pattern=\"test_pattern\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "path=\"src/\"") != null);
}

test "search_result_to_string_grouped groups matches by file" {
    const allocator = std.testing.allocator;

    var matches = std.ArrayList(search.SearchMatch).empty;
    defer matches.deinit(allocator);

    // Add matches from two different files
    try matches.append(allocator, .{
        .file = "src/main.zig",
        .line_number = 10,
        .file_total_lines = 100,
        .snippet = "match 1 in main",
    });
    try matches.append(allocator, .{
        .file = "src/utils.zig",
        .line_number = 5,
        .file_total_lines = 50,
        .snippet = "match 1 in utils",
    });
    try matches.append(allocator, .{
        .file = "src/main.zig",
        .line_number = 25,
        .file_total_lines = 100,
        .snippet = "match 2 in main",
    });

    const result = search.SearchResult{
        .matches = matches,
        .content = "",
    };

    const output = try search.search_result_to_string_grouped(allocator, result, "test_pattern", "src/");
    defer allocator.free(output);

    // Verify grouped format contains search wrapper
    try std.testing.expect(std.mem.indexOf(u8, output, "<search") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "</search>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "pattern=\"test_pattern\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "path=\"src/\"") != null);

    // Verify grouped format contains file headers
    try std.testing.expect(std.mem.indexOf(u8, output, "<file") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "</file>") != null);

    // Verify file paths are present
    try std.testing.expect(std.mem.indexOf(u8, output, "src/main.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "src/utils.zig") != null);

    // Verify total lines are present
    try std.testing.expect(std.mem.indexOf(u8, output, "total=\"100\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "total=\"50\"") != null);

    // Verify counts are present (main has 2, utils has 1)
    try std.testing.expect(std.mem.indexOf(u8, output, "count=\"2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "count=\"1\"") != null);
}

