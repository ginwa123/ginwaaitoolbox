const std = @import("std");
const json = std.json;
const AgentTool = @import("nalarcore").tool_models.AgentTool;
const AgentToolFunction = @import("nalarcore").tool_models.AgentToolFunction;
const ToolParameters = @import("nalarcore").tool_models.ToolParameters;
const ToolProperty = @import("nalarcore").tool_models.ToolProperty;
const config_mod = @import("../../modules/config/config.zig");

/// Error types for MCP tool fetching
pub const McpToolError = error{
    ConfigLoadError,
    HttpRequestError,
    JsonParseError,
    InvalidResponse,
    OutOfMemory,
};

/// Header struct for MCP requests
const McpHeader = struct {
    key: []const u8,
    value: []const u8,
};

/// MCP Tool response from server
const McpToolResponse = struct {
    name: []const u8,
    description: []const u8,
    inputSchema: InputSchema,
};

const InputSchema = struct {
    @"type": []const u8,
    properties: json.Value,
    required: ?[]const []const u8 = null,
};

/// List tools response
const ListToolsResult = struct {
    tools: []const McpToolResponse,
};

/// Fetch MCP tools from all configured servers
pub fn run(allocator: std.mem.Allocator, config: *const config_mod.LlmConfig) ![]AgentTool {
    // Check if mcpServers is configured
    if (config.mcpServers == null) {
        return &[_]AgentTool{};
    }

    const mcp_value = config.mcpServers.?;
    const mcp_servers = switch (mcp_value) {
        .object => |obj| obj,
        else => return &[_]AgentTool{},
    };

    var all_tools: std.ArrayList(AgentTool) = .empty;
    defer all_tools.deinit(allocator);

    // Iterate over each MCP server
    var server_iter = mcp_servers.iterator();
    while (server_iter.next()) |entry| {
        const server_name = entry.key_ptr.*;
        const server_config = entry.value_ptr.*;

        const server_obj = switch (server_config) {
            .object => |obj| obj,
            else => continue,
        };

        // Get URL
        const url_value = server_obj.get("url") orelse continue;
        const url = url_value.string;

        // Build headers
        var headers: std.ArrayList(McpHeader) = .empty;
        defer headers.deinit(allocator);

        if (server_obj.get("headers")) |headers_value| {
            const headers_obj = switch (headers_value) {
                .object => |obj| obj,
                else => continue,
            };
            var header_iter = headers_obj.iterator();
            while (header_iter.next()) |h_entry| {
                const key = h_entry.key_ptr.*;
                const value = switch (h_entry.value_ptr.*) {
                    .string => |s| s,
                    else => continue,
                };
                try headers.append(allocator, .{ .key = key, .value = value });
            }
        }

        // Fetch tools from this server
        const tools = try fetchToolsFromServer(allocator, url, headers.items, server_name);
        defer {
            for (tools) |*tool| {
                allocator.free(tool.function.name);
                allocator.free(tool.function.description);
                for (tool.function.parameters.properties) |*prop| {
                    allocator.free(prop.name);
                    allocator.free(prop.type);
                    allocator.free(prop.description);
                }
                allocator.free(tool.function.parameters.properties);
                allocator.free(tool.function.parameters.required);
            }
            allocator.free(tools);
        }

        try all_tools.appendSlice(allocator, tools);
    }

    return try all_tools.toOwnedSlice(allocator);
}

/// Fetch tools from a single MCP server
fn fetchToolsFromServer(
    allocator: std.mem.Allocator,
    url: []const u8,
    _headers: []const McpHeader,
    server_name: []const u8,
) ![]AgentTool {
    // Use the URL directly - MCP servers use /mcp endpoint, not /tools/list
    const tools_url = url;

    // Create HTTP client
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // Build request body (JSON-RPC)
    const request_body = try allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"tools/list\",\"params\":{}}");
    defer allocator.free(request_body);

    // Parse URI
    const uri = std.Uri.parse(tools_url) catch |err| {
        std.log.warn("Failed to parse MCP server URL {s}: {s}", .{ tools_url, @errorName(err) });
        return &[_]AgentTool{};
    };

    // Prepare extra headers (including custom headers from config)
    var extra_headers: std.ArrayList(std.http.Header) = .empty;
    defer extra_headers.deinit(allocator);

    // Add Accept header required by MCP server
    try extra_headers.append(allocator, .{ .name = "Accept", .value = "application/json, text/event-stream" });

    // Add custom headers from config
    for (_headers) |header| {
        try extra_headers.append(allocator, .{ .name = header.key, .value = header.value });
    }

    // Build request
    var req = client.request(.POST, uri, .{
        .version = .@"HTTP/1.1",
        .headers = .{
            .content_type = .{ .override = "application/json" },
        },
        .extra_headers = extra_headers.items,
    }) catch |err| {
        std.log.warn("Failed to create HTTP request for MCP server {s}: {s}", .{ server_name, @errorName(err) });
        return &[_]AgentTool{};
    };
    defer req.deinit();

    // Send request body
    req.sendBodyComplete(request_body) catch |err| {
        std.log.warn("Failed to send request to MCP server {s}: {s}", .{ server_name, @errorName(err) });
        return &[_]AgentTool{};
    };

    // Receive response
    var redirect_buffer: [8192]u8 = undefined;
    var response = req.receiveHead(&redirect_buffer) catch |err| {
        std.log.warn("Failed to receive response from MCP server {s}: {s}", .{ server_name, @errorName(err) });
        return &[_]AgentTool{};
    };

    // Read response body
    var transfer_buffer: [64 * 1024]u8 = undefined;
    const body = response.reader(&transfer_buffer).allocRemaining(allocator, .unlimited) catch |err| {
        std.log.warn("Failed to read response body from MCP server {s}: {s}", .{ server_name, @errorName(err) });
        return &[_]AgentTool{};
    };
    defer allocator.free(body);

    // Check status
    if (response.head.status != .ok) {
        std.log.warn("MCP server {s} returned status {d}", .{ server_name, @intFromEnum(response.head.status) });
        return &[_]AgentTool{};
    }

    // Parse JSON response
    const parsed = json.parseFromSlice(json.Value, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.log.warn("Failed to parse MCP response from {s}: {s}", .{ server_name, @errorName(err) });
        return &[_]AgentTool{};
    };
    defer parsed.deinit();
    std.debug.print("MCP response: {s}\n", .{body});

    // Extract tools from result
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => {
            std.log.warn("Invalid MCP response from {s}: expected object", .{server_name});
            return &[_]AgentTool{};
        },
    };

    const result_value = root.get("result") orelse {
        std.log.warn("Invalid MCP response from {s}: missing result", .{server_name});
        return &[_]AgentTool{};
    };

    const result_obj = switch (result_value) {
        .object => |obj| obj,
        else => {
            std.log.warn("Invalid MCP response from {s}: result not an object", .{server_name});
            return &[_]AgentTool{};
        },
    };

    const tools_value = result_obj.get("tools") orelse {
        std.log.warn("Invalid MCP response from {s}: missing tools", .{server_name});
        return &[_]AgentTool{};
    };

    const tools_array = switch (tools_value) {
        .array => |arr| arr,
        else => {
            std.log.warn("Invalid MCP response from {s}: tools not an array", .{server_name});
            return &[_]AgentTool{};
        },
    };

    // Convert each MCP tool to AgentTool
    var agent_tools: std.ArrayList(AgentTool) = .empty;
    defer agent_tools.deinit(allocator);

    for (tools_array.items) |tool_value| {
        const tool_obj = switch (tool_value) {
            .object => |obj| obj,
            else => continue,
        };

        const name_value = tool_obj.get("name") orelse continue;
        const name = switch (name_value) {
            .string => |s| s,
            else => continue,
        };

        const desc_value = tool_obj.get("description") orelse continue;
        const description = switch (desc_value) {
            .string => |s| s,
            else => continue,
        };

        const schema_value = tool_obj.get("inputSchema") orelse continue;
        const schema_obj = switch (schema_value) {
            .object => |obj| obj,
            else => continue,
        };

        // Parse properties
        const props_value = schema_obj.get("properties") orelse continue;
        const properties = try parseProperties(allocator, props_value, server_name);

        // Parse required fields
        var required: []const []const u8 = &[_][]const u8{};
        if (schema_obj.get("required")) |req_value| {
            const req_array = switch (req_value) {
                .array => |arr| arr,
                else => continue,
            };
            var req_list: std.ArrayList([]const u8) = .empty;
            defer req_list.deinit(allocator);
            for (req_array.items) |req_item| {
                const req_str = switch (req_item) {
                    .string => |s| s,
                    else => continue,
                };
                try req_list.append(allocator, try allocator.dupe(u8, req_str));
            }
            required = try req_list.toOwnedSlice(allocator);
        }

        const agent_tool = AgentTool{
            .type = "function",
            .function = AgentToolFunction{
                .name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ server_name, name }),
                .description = try allocator.dupe(u8, description),
                .parameters = ToolParameters{
                    .type = "object",
                    .properties = properties,
                    .required = required,
                },
            },
        };

        try agent_tools.append(allocator, agent_tool);
    }

    return try agent_tools.toOwnedSlice(allocator);
}

/// Parse JSON properties into ToolProperty array
pub fn parseProperties(
    allocator: std.mem.Allocator,
    props_value: json.Value,
    server_name: []const u8,
) ![]ToolProperty {
    _ = server_name;
    const props_obj = switch (props_value) {
        .object => |obj| obj,
        else => return &[_]ToolProperty{},
    };

    var properties: std.ArrayList(ToolProperty) = .empty;
    defer properties.deinit(allocator);

    var prop_iter = props_obj.iterator();
    while (prop_iter.next()) |entry| {
        const prop_name = entry.key_ptr.*;
        const prop_value = entry.value_ptr.*;

        const prop_obj = switch (prop_value) {
            .object => |obj| obj,
            else => continue,
        };

        const type_value = prop_obj.get("type") orelse continue;
        const prop_type = switch (type_value) {
            .string => |s| s,
            else => continue,
        };

        var prop_desc: []const u8 = "";
        if (prop_obj.get("description")) |desc_value| {
            prop_desc = switch (desc_value) {
                .string => |s| s,
                else => "",
            };
        }

        try properties.append(allocator, ToolProperty{
            .name = try allocator.dupe(u8, prop_name),
            .type = try allocator.dupe(u8, prop_type),
            .description = try allocator.dupe(u8, prop_desc),
        });
    }

    return try properties.toOwnedSlice(allocator);
}

test {
    _ = @import("build_messages_tools_mcp_for_agent_test.zig");
}
