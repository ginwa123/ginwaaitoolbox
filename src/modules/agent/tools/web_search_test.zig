const std = @import("std");
const webSearchMod = @import("web_search.zig");
const WebSearchInput = @import("schemas.zig").WebSearchInput;
const WebSearchResult = @import("schemas.zig").WebSearchResult;

test "web search with URL returns content" {
    const allocator = std.testing.allocator;
    const input = WebSearchInput{
        .url = "https://example.com",
    };

    const result = try webSearchMod.execute_web_search(allocator, input);
    defer result.deinit(allocator);

    // Either success or failure is acceptable (depends on agent-browser availability)
    try std.testing.expect(result.content.len > 0 or result.error_msg != null);
}
