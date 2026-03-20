const std = @import("std");

test "mcp module imports" {
    // Test that the MCP modules can be imported
    const mcp_types = @import("mcp_types.zig");
    const mcp_server = @import("mcp_server.zig");
    const mcp_transport = @import("mcp_transport.zig");
    _ = mcp_types;
    _ = mcp_server;
    _ = mcp_transport;
    try std.testing.expect(true);
}
