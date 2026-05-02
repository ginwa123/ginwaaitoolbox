const std = @import("std");
const nalar_mod = @import("nalarcore");
const agent = nalar_mod.agent;
const logger_mod = nalar_mod.logger;
const sqlite = nalar_mod.sqlite;
const save_message = @import("llm_history.zig");
const http_client = nalar_mod.http_client;
const config_mod = nalar_mod.config;

/// Strip SSE "data:" prefix from response body if present
/// MCP servers may return responses in SSE format: "data: {...}\n\n"
fn stripSsePrefix(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    // Check if body starts with "data:" (possibly with leading whitespace)
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "data:")) {
        // Extract the JSON part after "data:"
        const json_start = trimmed["data:".len..];
        const json_trimmed = std.mem.trim(u8, json_start, " \t");
        // Return a copy since the original body will be freed
        return try allocator.dupe(u8, json_trimmed);
    }
    // No SSE prefix, return the original
    return body;
}

/// Handle an MCP tool call by forwarding it to the MCP server
///
/// IMPORTANT: This function allocates directly from parent_allocator to avoid
/// nested arena issues that can cause @memcpy aliasing errors.
pub fn handle_mcp_tool_run(
    parent_allocator: std.mem.Allocator,
    io: std.Io,
    logger: *logger_mod.Logger,
    tool_call: agent.ToolCall,
    config: *const config_mod.LlmConfig,
) ![]const u8 {
    // Use parent_allocator directly to avoid nested arena memory issues
    const allocator = parent_allocator;

    // Debug: log the tool call ID we received
    _ = try logger.infoFmt("[MCP] Tool call START - name: '{s}', id: '{s}'", .{ tool_call.function.name, tool_call.id });

    // Parse tool name: format is "mcp_serverName_toolName"
    // First, verify it starts with "mcp_"
    if (!std.mem.startsWith(u8, tool_call.function.name, "mcp_")) {
        _ = try logger.warnFmt("[MCP] Tool name does not start with 'mcp_': {s}", .{tool_call.function.name});
        return error.InvalidMCPToolName;
    }

    // Find the second underscore (after "mcp_")
    const after_mcp = tool_call.function.name["mcp_".len..];
    const underscore_idx = std.mem.indexOf(u8, after_mcp, "_") orelse {
        _ = try logger.warnFmt("[MCP] No underscore after server name in tool: {s}", .{tool_call.function.name});
        return error.InvalidMCPToolName;
    };

    const server_name = after_mcp[0..underscore_idx];
    const actual_tool_name = after_mcp[underscore_idx + 1 ..];

    _ = try logger.infoFmt("[MCP] Parsed - server: '{s}', tool: '{s}'", .{ server_name, actual_tool_name });

    // Get MCP server config
    if (config.mcpServers == null) {
        _ = try logger.warnFmt("[MCP] No MCP servers configured", .{});
        return error.NoMCPServers;
    }

    const mcp_servers = switch (config.mcpServers.?) {
        .object => |obj| obj,
        else => {
            return error.InvalidMCPServersConfig;
        },
    };

    const server_config = mcp_servers.get(server_name) orelse {
        return error.MCPServerNotFound;
    };

    const server_obj = switch (server_config) {
        .object => |obj| obj,
        else => {
            return error.InvalidMCPServerConfig;
        },
    };

    const url_value = server_obj.get("url") orelse {
        return error.MCPServerURLNotFound;
    };
    const url = url_value.string;

    // Build JSON-RPC request for tool call
    const request_body = try std.fmt.allocPrint(
        allocator,
        \\{{"jsonrpc":"2.0","id":"1","method":"tools/call","params":{{"name":"{s}","arguments":{s}}}}}
    ,
        .{ actual_tool_name, tool_call.function.arguments },
    );

    _ = try logger.debugFmt("MCP request: {s}", .{request_body});

    // Build headers
    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();
    _ = try headers.put("Accept", "application/json, text/event-stream");
    _ = try headers.put("Content-Type", "application/json");

    // Add custom headers from config
    if (server_obj.get("headers")) |headers_value| {
        const headers_obj = switch (headers_value) {
            .object => |obj| obj,
            else => {
                return error.InvalidMCPServerHeadersConfig;
            },
        };
        var header_iter = headers_obj.iterator();
        while (header_iter.next()) |h_entry| {
            const key = h_entry.key_ptr.*;
            const value = switch (h_entry.value_ptr.*) {
                .string => |s| s,
                else => continue,
            };
            _ = try headers.put(key, value);
        }
    }

    // Make HTTP request
    var client = http_client.HttpClient.init(allocator, io);
    defer client.deinit();

    const result = client.post(url, request_body, headers) catch |err| {
        _ = try logger.errFmt("MCP HTTP error: {s}", .{@errorName(err)});
        allocator.free(request_body);
        return error.FailedToCallMCPServer;
    };

    _ = try logger.debugFmt("MCP response status: {d}", .{result.status_code});

    if (result.status_code != 200) {
        // Log status without raw body to prevent crashes from non-null-terminated data
        _ = try logger.errFmt("MCP server returned status {d}, body length: {d}", .{ result.status_code, result.body.len });
        return error.MCPServerReturnedError;
    }

    // Strip SSE "data:" prefix if present - MCP may return SSE responses
    const clean_body = try stripSsePrefix(allocator, result.body);
    const is_copy = @intFromPtr(clean_body.ptr) != @intFromPtr(result.body.ptr);
    errdefer if (is_copy) allocator.free(clean_body);

    // Parse the response and extract content
    // IMPORTANT: Use a separate ArenaAllocator with c_allocator to avoid nested arena
    // alignment issues. We create it here and deinit immediately after extracting strings.
    var parse_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer parse_arena.deinit();
    const parse_alloc = parse_arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, parse_alloc, clean_body, .{}) catch |err| {
        // Log error without raw body to prevent crashes from non-null-terminated data
        _ = try logger.errFmt("MCP JSON parse error: {s}, body length: {d}", .{ @errorName(err), clean_body.len });
        if (is_copy) allocator.free(clean_body);
        allocator.free(result.body);
        allocator.free(request_body);
        return error.MCPJSONParseError;
    };

    // Extract result content from MCP response BEFORE deinit
    const root = parsed.value;
    var tool_result: []const u8 = clean_body;
    var needs_copy = false;

    if (root.object.get("result")) |result_val| {
        if (result_val.object.get("content")) |content_val| {
            switch (content_val) {
                .array => |arr| {
                    // MCP returns content as array of content blocks
                    if (arr.items.len > 0) {
                        const first_content = arr.items[0];
                        if (first_content.object.get("text")) |text_val| {
                            switch (text_val) {
                                .string => |s| {
                                    tool_result = try allocator.dupe(u8, s);
                                    needs_copy = true;
                                },
                                else => {},
                            }
                        }
                    }
                },
                .string => |s| {
                    tool_result = try allocator.dupe(u8, s);
                    needs_copy = true;
                },
                else => {},
            }
        }
    }

    // Now safe to deinit the parse arena
    parsed.deinit();

    // Free intermediate allocations before returning
    if (is_copy) allocator.free(clean_body);
    allocator.free(result.body);

    // If we extracted a specific result, it was already duplicated
    // Otherwise, return a copy of clean_body
    if (!needs_copy) {
        return try allocator.dupe(u8, clean_body);
    }
    return tool_result;
}
