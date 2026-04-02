const std = @import("std");
const webSearchHelp = @import("web_search_help.zig");

test "web search help executes agent-browser --help" {
    const allocator = std.testing.allocator;
    
    const result = try webSearchHelp.executeWebSearchHelp(allocator);
    defer result.deinit(allocator);
    
    // Should contain expected help content
    try std.testing.expect(result.content.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "Usage:") != null);
    try std.testing.expectEqual(result.exit_code, 0);
}
