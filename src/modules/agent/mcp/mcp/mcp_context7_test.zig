const std = @import("std");
const json = std.json;
const testing = std.testing;
const mcp_types = @import("mcp_types.zig");

fn runCurlTest(allocator: std.mem.Allocator, json_rpc_body: []const u8) !struct { stdout: []const u8, term: std.process.Child.Term } {
    // Use curl to call the MCP server via bash -lc (login shell)
    // Note: MCP server requires Accept header to include BOTH application/json AND text/event-stream
    const cmd = try std.fmt.allocPrint(allocator, 
        "curl -s -X POST https://mcp.context7.com/mcp -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d '{s}'", 
        .{json_rpc_body}
    );
    defer allocator.free(cmd);
    
    // Use bash -lc to run command in login shell
    var child = std.process.Child.init(&[_][]const u8{ "bash", "-lc", cmd }, allocator);
    
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    
    // Wait for the process to complete FIRST, then read output
    const term = try child.wait();
    
    // Now read stdout after process has finished using buffer
    var buffer: [32768]u8 = undefined;
    const stdout = if (child.stdout) |out| blk: {
        const bytes_read = out.read(&buffer) catch 0;
        break :blk try allocator.dupe(u8, buffer[0..bytes_read]);
    } else "";
    
    return .{
        .stdout = stdout,
        .term = term,
    };
}

// Integration test for calling Context7 MCP server tools/list
// This test makes an actual HTTP request to https://mcp.context7.com/mcp via curl
// Skip this test if curl returns empty (network issues in test environment)
test "context7 mcp tools/list returns tools" {
    const allocator = testing.allocator;
    
    const result = try runCurlTest(allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{}}");
    defer allocator.free(result.stdout);
    
    // Check that the process exited normally with code 0
    try testing.expect(result.term == .Exited);
    try testing.expectEqual(@as(u8, 0), result.term.Exited);
    
    // Skip test if curl returned empty (network not available in test environment)
    if (result.stdout.len == 0) {
        std.debug.print("SKIP: Empty response (network not available in test environment)\n", .{});
        return error.SkipZigTest;
    }
    
    // Parse JSON-RPC response
    const parsed = try json.parseFromSlice(json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();

    // Verify the response structure
    const root = parsed.value.object;
    try testing.expectEqualStrings("2.0", root.get("jsonrpc").?.string);

    // The result should contain tools
    const result_val = root.get("result").?;
    const tools_value = result_val.object.get("tools").?;
    const tools = tools_value.array;
    try testing.expect(tools.items.len > 0);

    // Verify at least one tool has expected fields
    const first_tool = tools.items[0].object;
    try testing.expect(first_tool.contains("name"));
    try testing.expect(first_tool.contains("description"));
    try testing.expect(first_tool.contains("inputSchema"));

    // Log the tool names for visibility
    std.debug.print("Context7 MCP tools: ", .{});
    for (tools.items) |tool| {
        const name = tool.object.get("name").?.string;
        std.debug.print("{s}, ", .{name});
    }
    std.debug.print("\n", .{});
}

// Integration test for calling Context7 MCP server initialize
// Skip this test if curl returns empty (network issues in test environment)
test "context7 mcp initialize works" {
    const allocator = testing.allocator;
    
    const result = try runCurlTest(allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"zig-test-client\",\"version\":\"0.0.1\"}}}");
    defer allocator.free(result.stdout);
    
    try testing.expect(result.term == .Exited);
    try testing.expectEqual(@as(u8, 0), result.term.Exited);

    // Skip test if curl returned empty (network not available in test environment)
    if (result.stdout.len == 0) {
        std.debug.print("SKIP: Empty response (network not available in test environment)\n", .{});
        return error.SkipZigTest;
    }
    
    const parsed = try json.parseFromSlice(json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try testing.expectEqualStrings("2.0", root.get("jsonrpc").?.string);

    // Verify result contains serverInfo and capabilities
    const result_val = root.get("result").?;
    try testing.expect(result_val.object.contains("protocolVersion"));
    try testing.expect(result_val.object.contains("capabilities"));
    try testing.expect(result_val.object.contains("serverInfo"));

    const server_info = result_val.object.get("serverInfo").?;
    std.debug.print("Context7 server info: {s} v{s}\n", .{
        server_info.object.get("name").?.string,
        server_info.object.get("version").?.string,
    });
}

// Test that JSON-RPC error handling works correctly
// Skip this test if curl returns empty (network issues in test environment)
test "context7 mcp invalid method returns error" {
    const allocator = testing.allocator;
    
    const result = try runCurlTest(allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"invalid/nonexistent/method\",\"params\":{}}");
    defer allocator.free(result.stdout);
    
    // Should return 0 (curl success) but with JSON-RPC error in body
    try testing.expect(result.term == .Exited);
    try testing.expectEqual(@as(u8, 0), result.term.Exited);

    // Skip test if curl returned empty (network not available in test environment)
    if (result.stdout.len == 0) {
        std.debug.print("SKIP: Empty response (network not available in test environment)\n", .{});
        return error.SkipZigTest;
    }
    
    const parsed = try json.parseFromSlice(json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try testing.expectEqualStrings("2.0", root.get("jsonrpc").?.string);
    try testing.expect(root.contains("error"));
}
