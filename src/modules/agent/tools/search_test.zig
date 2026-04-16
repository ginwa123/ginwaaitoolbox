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

test "search_result_to_string returns empty for no matches" {
    const allocator = std.testing.allocator;

    var empty_matches = std.ArrayList(search.SearchMatch).empty;
    defer empty_matches.deinit(allocator);

    const result = search.SearchResult{
        .matches = empty_matches,
        .content = "<warning>pattern not found</warning>",
    };

    // search_result_to_string should return empty for no matches
    // because the warning is in the raw content from execute_search
    const output = try search.search_result_to_string(allocator, result);
    defer allocator.free(output);

    try std.testing.expectEqual(@as(usize, 0), output.len);
}
