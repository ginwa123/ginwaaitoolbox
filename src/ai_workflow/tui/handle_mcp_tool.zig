const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const logger_mod = tree1_mod.logger;
const sqlite = tree1_mod.sqlite;
const save_message = @import("save_message.zig");
const http_client = tree1_mod.http_client;
const config_mod = tree1_mod.config;

/// Handle an MCP tool call by forwarding it to the MCP server
pub fn handle_mcp_tool_run(
    parent_allocator: std.mem.Allocator,
    logger: *logger_mod.Logger,
    tool_call: agent.ToolCall,
    config: *const config_mod.LlmConfig,
) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(parent_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

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
    var client = http_client.HttpClient.init(allocator);
    defer client.deinit();

    const result = client.post(url, request_body, headers) catch |err| {
        _ = try logger.errFmt("MCP HTTP error: {s}", .{@errorName(err)});
        return error.FailedToCallMCPServer;
    };

    _ = try logger.debugFmt("MCP response status: {d}", .{result.status_code});

    if (result.status_code != 200) {
        _ = try logger.errFmt("MCP server returned status {d}: {s}", .{ result.status_code, result.body });
        return error.MCPServerReturnedError;
    }

    // Parse the response and extract content
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result.body, .{}) catch |err| {
        _ = try logger.errFmt("MCP JSON parse error: {s}", .{@errorName(err)});
        return error.MCPJSONParseError;
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

    // CRITICAL: Copy result to parent_allocator before arena is deallocated
    // Without this, tool_result points to memory that will be freed on defer
    const owned_result = try parent_allocator.dupe(u8, tool_result);
    return owned_result;
}
