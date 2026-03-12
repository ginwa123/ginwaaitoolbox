const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const logger_mod = tree1_mod.logger;
const sqlite = tree1_mod.sqlite;
const save_message = @import("save_message.zig");
const http_client = @import("../../modules/http/http_client.zig");
const config_mod = @import("../../modules/config/config.zig");

/// Handle an MCP tool call by forwarding it to the MCP server
pub fn run(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    session_name: ?[]const u8,
    loop_counter: u32,
    messages_list: *std.ArrayList(agent.AgentMessage),
    tool_call: agent.ToolCall,
    agent_temperature: f32,
    isThinking: bool,
    config: *const config_mod.LlmConfig,
) !void {
    // Debug: log the tool call ID we received
    logger.infoFmt("[MCP] Tool call START - name: '{s}', id: '{s}'", .{ tool_call.function.name, tool_call.id }) catch {};

    // Parse tool name: format is "serverName_toolName"
    const underscore_idx = std.mem.indexOf(u8, tool_call.function.name, "_") orelse {
        // No underscore - not a valid MCP tool name
        logger.warnFmt("[MCP] No underscore in tool name: {s}", .{tool_call.function.name}) catch {};
        try addErrorResponse(allocator, messages_list, tool_call, "Invalid MCP tool name format (expected server_tool)");
        return;
    };

    const server_name = tool_call.function.name[0..underscore_idx];
    const actual_tool_name = tool_call.function.name[underscore_idx + 1 ..];

    logger.infoFmt("[MCP] Parsed - server: '{s}', tool: '{s}'", .{ server_name, actual_tool_name }) catch {};

    // Get MCP server config
    if (config.mcpServers == null) {
        try addErrorResponse(allocator, messages_list, tool_call, "No MCP servers configured");
        return;
    }

    const mcp_servers = switch (config.mcpServers.?) {
        .object => |obj| obj,
        else => {
            try addErrorResponse(allocator, messages_list, tool_call, "Invalid MCP servers config");
            return;
        },
    };

    const server_config = mcp_servers.get(server_name) orelse {
        try addErrorResponse(allocator, messages_list, tool_call, "MCP server not found");
        return;
    };

    const server_obj = switch (server_config) {
        .object => |obj| obj,
        else => {
            try addErrorResponse(allocator, messages_list, tool_call, "Invalid MCP server config");
            return;
        },
    };

    const url_value = server_obj.get("url") orelse {
        try addErrorResponse(allocator, messages_list, tool_call, "MCP server URL not found");
        return;
    };
    const url = url_value.string;

    // Build JSON-RPC request for tool call
    const request_body = try std.fmt.allocPrint(
        allocator,
        \\{{"jsonrpc":"2.0","id":"1","method":"tools/call","params":{{"name":"{s}","arguments":{s}}}}}
    ,
        .{ actual_tool_name, tool_call.function.arguments },
    );
    defer allocator.free(request_body);

    logger.debugFmt("MCP request: {s}", .{request_body}) catch {};

    // Build headers
    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();
    try headers.put("Accept", "application/json, text/event-stream");
    try headers.put("Content-Type", "application/json");

    // Add custom headers from config
    if (server_obj.get("headers")) |headers_value| {
        const headers_obj = switch (headers_value) {
            .object => |obj| obj,
            else => {
                try addErrorResponse(allocator, messages_list, tool_call, "Invalid MCP server headers config");
                return;
            },
        };
        var header_iter = headers_obj.iterator();
        while (header_iter.next()) |h_entry| {
            const key = h_entry.key_ptr.*;
            const value = switch (h_entry.value_ptr.*) {
                .string => |s| s,
                else => continue,
            };
            try headers.put(key, value);
        }
    }

    // Make HTTP request
    var client = http_client.HttpClient.init(allocator);
    defer client.deinit();

    const result = client.post(url, request_body, headers) catch |err| {
        logger.errFmt("MCP HTTP error: {s}", .{@errorName(err)}) catch {};
        try addErrorResponse(allocator, messages_list, tool_call, "Failed to call MCP server");
        return;
    };
    defer allocator.free(result.body);

    logger.debugFmt("MCP response status: {d}", .{result.status_code}) catch {};

    if (result.status_code != 200) {
        logger.errFmt("MCP server returned status {d}: {s}", .{ result.status_code, result.body }) catch {};
        try addErrorResponse(allocator, messages_list, tool_call, result.body);
        return;
    }

    // Parse the response and extract content
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result.body, .{}) catch |err| {
        logger.errFmt("MCP JSON parse error: {s}", .{@errorName(err)}) catch {};
        try addErrorResponse(allocator, messages_list, tool_call, result.body);
        return;
    };
    defer parsed.deinit();

    // Extract result content from MCP response
    const root = parsed.value;
    var tool_result: []const u8 = result.body;

    if (root.object.get("result")) |result_val| {
        if (result_val.object.get("content")) |content_val| {
            switch (content_val) {
                .array => |arr| {
                    // MCP returns content as array of content blocks
                    if (arr.items.len > 0) {
                        const first_content = arr.items[0];
                        if (first_content.object.get("text")) |text_val| {
                            tool_result = switch (text_val) {
                                .string => |s| s,
                                else => result.body,
                            };
                        }
                    }
                },
                .string => |s| tool_result = s,
                else => {},
            }
        }
    }

    // Add tool result message
    const tool_result_msg = agent.AgentMessage{
        .role = .tool,
        .content = try allocator.dupe(u8, tool_result),
        .tool_call_id = try allocator.dupe(u8, tool_call.id),
    };
    logger.infoFmt("[MCP] Adding tool result - tool_call_id: '{s}', content length: {}", .{ tool_result_msg.tool_call_id.?, tool_result.len }) catch {};
    try messages_list.append(allocator, tool_result_msg);
    logger.infoFmt("[MCP] Tool result appended to messages_list, total messages: {}", .{messages_list.items.len}) catch {};

    // Save tool result to database
    _ = save_message.run(
        allocator, db, session_id, model, cwd,
        null,
        tool_result,
        null,
        null,
        agent.Role.tool.toStr(),
        null,  // finish_reason - should be null for tool messages
        null,  // tool_calls
        tool_call.id,  // tool_call_id - the correct ID
        tool_call.function.name,  // agent_name - store tool name for debugging
        session_name,
        loop_counter,
        agent_temperature,
        isThinking
    ) catch |err| {
        logger.errFmt("Failed to save MCP tool result: {s}", .{@errorName(err)}) catch {};
    };
}

fn addErrorResponse(
    allocator: std.mem.Allocator,
    messages_list: *std.ArrayList(agent.AgentMessage),
    tool_call: agent.ToolCall,
    error_msg: []const u8,
) !void {
    const tool_result_msg = agent.AgentMessage{
        .role = .tool,
        .content = try allocator.dupe(u8, error_msg),
        .tool_call_id = try allocator.dupe(u8, tool_call.id),
    };
    try messages_list.append(allocator, tool_result_msg);
}
