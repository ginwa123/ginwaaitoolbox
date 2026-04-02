const std = @import("std");
const webSearchMod = @import("web_search.zig");
const WebSearchInput = @import("schemas.zig").WebSearchInput;
const WebSearchResult = @import("schemas.zig").WebSearchResult;

test "web search with query returns content" {
    const allocator = std.testing.allocator;
    const input = WebSearchInput{
        .query = "example domain",
    };
    
    const result = try webSearchMod.executeWebSearch(allocator, input);
    defer result.deinit(allocator);
    
    try std.testing.expect(result.success);
    try std.testing.expect(result.content.len > 0);
    try std.testing.expect(result.exit_code == 0);
}

test "web search help action returns content" {
    const allocator = std.testing.allocator;
    const input = WebSearchInput{
        .query = null,
        .action = "help",
    };
    
    const result = try webSearchMod.executeWebSearch(allocator, input);
    defer result.deinit(allocator);
    
    // Help should return content
    try std.testing.expect(result.content.len > 0);
}
