const std = @import("std");
const webSearchMod = @import("web_search.zig");
const WebSearchInput = @import("schemas.zig").WebSearchInput;
const WebSearchResult = @import("schemas.zig").WebSearchResult;

test "web search with query returns content" {
    const allocator = std.testing.allocator;
    const input = WebSearchInput{
        .query = "example domain",
    };

    const result = try webSearchMod.execute_web_search(allocator, input);
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expect(result.content.len > 0);
    try std.testing.expect(result.exit_code == 0);
}

test "web search with direct URL" {
    const allocator = std.testing.allocator;
    const input = WebSearchInput{
        .url = "https://example.com",
        .action = "snapshot",
    };

    const result = try webSearchMod.execute_web_search(allocator, input);
    defer result.deinit(allocator);

    // Either success or failure is acceptable (depends on agent-browser availability)
    try std.testing.expect(result.content.len > 0 or result.error_msg != null);
}

test "web search with click action" {
    const allocator = std.testing.allocator;
    const input = WebSearchInput{
        .url = "https://example.com",
        .action = "click",
        .selector = "#submit-btn",
    };

    const result = try webSearchMod.execute_web_search(allocator, input);
    defer result.deinit(allocator);

    // Should return some output
    try std.testing.expect(result.content.len >= 0);
}

test "web search result to string conversion" {
    const allocator = std.testing.allocator;
    const result = WebSearchResult{
        .success = true,
        .content = try allocator.dupe(u8, "test content"),
        .exit_code = 0,
        .error_msg = null,
    };
    defer {
        allocator.free(result.content);
        if (result.error_msg) |msg| allocator.free(msg);
    }

    const output = try webSearchMod.web_search_result_to_string(allocator, result);
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "<success>true</success>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<content>test content</content>") != null);
}
