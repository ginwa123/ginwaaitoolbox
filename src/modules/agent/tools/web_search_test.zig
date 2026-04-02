const std = @import("std");
const webSearchMod = @import("web_search.zig");
const WebSearchInput = @import("schemas.zig").WebSearchInput;
const WebSearchResult = @import("schemas.zig").WebSearchResult;

test "web search open url returns success" {
    const allocator = std.testing.allocator;
    const input = WebSearchInput{
        .url = "https://example.com",
        .action = "open",
    };
    
    const result = try webSearchMod.executeWebSearch(allocator, input);
    defer result.deinit(allocator);
    
    try std.testing.expect(result.success);
    try std.testing.expect(result.exit_code == 0);
}

test "web search help action returns content" {
    const allocator = std.testing.allocator;
    const input = WebSearchInput{
        .url = "",
        .action = "help",
    };
    
    const result = try webSearchMod.executeWebSearch(allocator, input);
    defer result.deinit(allocator);
    
    // Help should return content
    try std.testing.expect(result.content.len > 0);
}
