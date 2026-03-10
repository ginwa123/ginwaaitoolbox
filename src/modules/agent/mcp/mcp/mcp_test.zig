const std = @import("std");
const json = std.json;
const testing = std.testing;
const mcp_types = @import("mcp_types.zig");
const mcp_transport = @import("mcp_transport.zig");
const mcp_server = @import("mcp_server.zig");

test "MCP types exist" {
    const tool = mcp_types.McpTool{
        .name = "test",
        .description = "A test tool",
        .inputSchema = .{
            .@"type" = "object",
            .properties = .{},
            .required = null,
        },
    };
    try testing.expectEqualStrings("test", tool.name);
}

test "MCP JsonRpcRequest default" {
    const req = mcp_types.JsonRpcRequest{
        .method = "tools/list",
    };
    try testing.expectEqualStrings("2.0", req.jsonrpc);
    try testing.expectEqualStrings("tools/list", req.method);
}

test "MCP Server init" {
    const allocator = testing.allocator;
    var server = mcp_server.McpServer.init(allocator);
    defer server.deinit();

    try testing.expectEqualStrings("2024-11-05", server.protocolVersion);
}

test "MCP Server register tool" {
    const allocator = testing.allocator;
    var server = mcp_server.McpServer.init(allocator);
    defer server.deinit();

    const tool = mcp_types.McpTool{
        .name = "bash",
        .description = "Execute bash command",
        .inputSchema = .{
            .@"type" = "object",
            .properties = .{},
            .required = null,
        },
    };
    try server.registerTool(tool);

    try testing.expect(server.tools.contains("bash"));
}

test "MCP ToolExecutor function" {
    const allocator = testing.allocator;
    var server = mcp_server.McpServer.init(allocator);
    defer server.deinit();

    const executor: mcp_server.ToolExecutor = struct {
        fn exec(alloc: std.mem.Allocator, name: []const u8, args: ?json.Value) anyerror!json.Value {
            _ = alloc;
            _ = name;
            _ = args;
            return .{ .integer = 42 };
        }
    }.exec;
    
    server.setToolExecutor(executor);
    try testing.expect(server.toolExecutor != null);
}
