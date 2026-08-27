const std = @import("std");
const nalar_mod = @import("nalarcore");
const agent = nalar_mod.agent;
const logger_mod = nalar_mod.loggermod;
const sqlite = nalar_mod.sqlite;
const save_message = @import("llm_history.zig");
const custom_http_client = @import("custom_http_client");
const config_mod = nalar_mod.config;
const mcp_stdio = nalar_mod.mcp_stdio;

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
    logger: *logger_mod.Logger,
    tool_call: agent.ToolCall,
    config: *const config_mod.LlmConfig,
) ![]const u8 {
    // Use parent_allocator directly to avoid nested arena memory issues
    const allocator = parent_allocator;

    // Debug: log the tool call ID we received
    logger.infoFmt("[MCP] Tool call START - name: '{s}', id: '{s}'", .{ tool_call.function.name, tool_call.id });

    // Parse tool name: format is "mcp_serverName_toolName"
    // First, verify it starts with "mcp_"
    if (!std.mem.startsWith(u8, tool_call.function.name, "mcp_")) {
        logger.warnFmt("[MCP] Tool name does not start with 'mcp_': {s}", .{tool_call.function.name});
        return error.InvalidMCPToolName;
    }

    // Find the second underscore (after "mcp_")
    const after_mcp = tool_call.function.name["mcp_".len..];
    const underscore_idx = std.mem.indexOf(u8, after_mcp, "_") orelse {
        logger.warnFmt("[MCP] No underscore after server name in tool: {s}", .{tool_call.function.name});
        return error.InvalidMCPToolName;
    };

    const server_name = after_mcp[0..underscore_idx];
    const actual_tool_name = after_mcp[underscore_idx + 1 ..];

    logger.infoFmt("[MCP] Parsed - server: '{s}', tool: '{s}'", .{ server_name, actual_tool_name });

    // Get MCP server config
    if (config.mcpServers() == null) {
        logger.warnFmt("[MCP] No MCP servers configured", .{});
        return error.NoMCPServers;
    }

    const mcp_servers = switch (config.mcpServers().?) {
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

    // Transport dispatch: stdio (command) or HTTP (url). stdio takes
    // precedence when both are present (the parser already rejects that
    // combo, but the runtime is defensive).
    if (server_obj.get("command")) |_| {
        return callViaStdio(allocator, logger, server_name, actual_tool_name, tool_call.function.arguments, server_obj);
    }

    const url_value = server_obj.get("url") orelse {
        return error.MCPServerURLNotFound;
    };
    const url = url_value.string;

    // Build JSON-RPC request for tool call (shared shape with stdio).
    const request_body = try buildToolCallRequestBody(allocator, actual_tool_name, tool_call.function.arguments);
    defer allocator.free(request_body);

    logger.debugFmt("MCP request: {s}", .{request_body});

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
    var client = custom_http_client.Client.init(allocator);
    defer client.deinit();

    // custom_http_client.post() takes a `[]const Header` slice, not a
    // StringHashMap. Flatten the hash map into a stack-allocated slice
    // (MCP headers are a small bounded set; allocate an upper bound and
    // slice down to the actual count).
    var header_buf: [16]custom_http_client.Header = undefined;
    var header_count: usize = 0;
    var header_it = headers.iterator();
    while (header_it.next()) |entry| {
        if (header_count >= header_buf.len) return error.InvalidMCPServerHeadersConfig;
        header_buf[header_count] = .{
            .name = entry.key_ptr.*,
            .value = entry.value_ptr.*,
        };
        header_count += 1;
    }
    const header_slice = header_buf[0..header_count];

    const result = custom_http_client.post(
        &client,
        url,
        request_body,
        header_slice,
        .{ .timeout_ms = 30_000 },
    ) catch |err| {
        logger.errFmt("MCP HTTP error: {s}", .{@errorName(err)});
        allocator.free(request_body);
        return error.FailedToCallMCPServer;
    };
    defer result.deinit(allocator);

    logger.debugFmt("MCP response status: {d}", .{result.status_code});

    if (result.status_code != 200) {
        // Log status without raw body to prevent crashes from non-null-terminated data
        logger.errFmt("MCP server returned status {d}, body length: {d}", .{ result.status_code, result.body.len });
        return error.MCPServerReturnedError;
    }

    // Strip SSE "data:" prefix if present - MCP may return SSE responses
    const clean_body = try stripSsePrefix(allocator, result.body);
    const is_copy = @intFromPtr(clean_body.ptr) != @intFromPtr(result.body.ptr);
    errdefer if (is_copy) allocator.free(clean_body);

    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();
    const parse_alloc = parse_arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, parse_alloc, clean_body, .{}) catch |err| {
        // Log error without raw body to prevent crashes from non-null-terminated data
        logger.errFmt("MCP JSON parse error: {s}, body length: {d}", .{ @errorName(err), clean_body.len });
        if (is_copy) allocator.free(clean_body);
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

    // Free intermediate allocations before returning. Note: `result`'s
    // body is freed by `result.deinit(allocator)` below — do NOT
    // `allocator.free(result.body)` here (that would double-free).
    if (is_copy) allocator.free(clean_body);

    // If we extracted a specific result, it was already duplicated
    // Otherwise, return a copy of clean_body
    if (!needs_copy) {
        return try allocator.dupe(u8, clean_body);
    }
    return tool_result;
}

// ============================================================================
// stdio transport: spawn a child process per server, send framed
// JSON-RPC over its stdin, read the framed response from stdout.
// ============================================================================

/// Call a tool via the stdio transport. Spawns (or reuses) a child
/// process keyed by `server_name`, sends a framed `tools/call` JSON-RPC
/// body, and reads the framed response. Returns the extracted text
/// content (the `result.content[0].text` field, freshly allocated).
fn callViaStdio(
    allocator: std.mem.Allocator,
    logger: *logger_mod.Logger,
    server_name: []const u8,
    tool_name: []const u8,
    arguments_json: []const u8,
    server_obj: std.json.ObjectMap,
) ![]const u8 {
    // Build argv: [command, args...]
    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(allocator);
    if (server_obj.get("command")) |cmd_field| {
        if (cmd_field == .string) {
            try argv_list.append(allocator, try allocator.dupe(u8, cmd_field.string));
        }
    }
    if (server_obj.get("args")) |args_v| {
        if (args_v == .array) {
            for (args_v.array.items) |item| {
                if (item == .string) {
                    try argv_list.append(allocator, try allocator.dupe(u8, item.string));
                }
            }
        }
    }
    if (argv_list.items.len == 0) {
        logger.errFmt("stdio MCP server '{s}' has no command", .{server_name});
        return error.MCPServerCommandNotFound;
    }
    const argv = try argv_list.toOwnedSlice(allocator);
    defer {
        for (argv) |a| allocator.free(a);
        allocator.free(argv);
    }

    // stdio transport: long-lived child per server, lazy spawn + respawn.
    // We need an io handle — for now use the threaded io (same as the
    // stdio client tests). Real wiring in main.zig will pass a real io.
    const reg = mcp_stdio.StdioRegistry.global(allocator);
    const client = reg.getOrSpawn(server_name, argv) catch |err| {
        logger.errFmt("stdio MCP spawn failed for {s}.{s}: {s}", .{ server_name, tool_name, @errorName(err) });
        return error.FailedToCallMCPServer;
    };

    // Build the framed request and send.
    const req = try buildToolCallRequestBody(allocator, tool_name, arguments_json);
    defer allocator.free(req);
    // client.send/recv use the io stored in the StdioClient itself.
    // TODO(wire-up): main.zig's StdioRegistry.global() should accept an
    // io handle and pass it through to all spawned children — the test
    // path uses std.testing.io via the registry's `global()` helper.
    client.send(req) catch |err| {
        logger.errFmt("stdio MCP send failed for {s}.{s}: {s}", .{ server_name, tool_name, @errorName(err) });
        // Respawn on next call.
        return error.FailedToCallMCPServer;
    };
    const resp = client.recv() catch |err| {
        logger.errFmt("stdio MCP recv failed for {s}.{s}: {s}", .{ server_name, tool_name, @errorName(err) });
        return error.MCPServerReturnedError;
    };
    errdefer allocator.free(resp);

    // Same JSON extraction as the HTTP branch: pull `result.content[0].text`.
    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, parse_arena.allocator(), resp, .{}) catch {
        return error.MCPJSONParseError;
    };
    const root = parsed.value;
    var tool_result: []const u8 = resp;
    var needs_copy = false;
    if (root.object.get("result")) |result_val| {
        if (result_val.object.get("content")) |content_val| {
            if (content_val == .array) {
                const arr = content_val.array;
                if (arr.items.len > 0) {
                    if (arr.items[0].object.get("text")) |text_val| {
                        if (text_val == .string) {
                            tool_result = try allocator.dupe(u8, text_val.string);
                            needs_copy = true;
                        }
                    }
                }
            }
        }
    }
    if (!needs_copy) tool_result = try allocator.dupe(u8, resp);
    return tool_result;
}

// ============================================================================
// Shared request-body builder (used by both HTTP and stdio transports)
// ============================================================================

/// Build a JSON-RPC `tools/call` request body for a given tool name + args.
/// Returns a freshly-allocated slice the caller owns (frees with allocator).
///
/// This is the SHAPE the agent sends over the wire — same for HTTP and
/// stdio. The transport just decides how to deliver it.
pub fn buildToolCallRequestBody(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    arguments_json: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        \\{{"jsonrpc":"2.0","id":"1","method":"tools/call","params":{{"name":"{s}","arguments":{s}}}}}
        ,
        .{ tool_name, arguments_json },
    );
}

// ============================================================================
// Tests (inline at the bottom — project convention)
// ============================================================================

const testing = std.testing;

test "buildToolCallRequestBody: emits jsonrpc tools/call envelope" {
    // Note: arguments_json is passed through verbatim — the test uses
    // a compact JSON to make the substring match predictable.
    const body = try buildToolCallRequestBody(testing.allocator, "say_hello",
        \\{"name":"world"}
    );
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"jsonrpc\":\"2.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"tools/call\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"name\":\"say_hello\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"arguments\":{\"name\":\"world\"}") != null);
}

test "buildToolCallRequestBody: empty arguments is a valid empty object" {
    const body = try buildToolCallRequestBody(testing.allocator, "ping", "{}");
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"arguments\":{}") != null);
}
