const std = @import("std");
const nalar_mod = @import("nalarcore");
const agent = nalar_mod.agent;
const logger_mod = nalar_mod.loggermod;
const sqlite = nalar_mod.sqlite;
const save_message = @import("llm_history.zig");
const custom_http_client = @import("custom_http_client");
const config_mod = nalar_mod.config;
const mcp_stdio = nalar_mod.mcp_stdio;
const mcp_http = nalar_mod.mcp_http;

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
        // 60s default per-call budget for tools/call (vs 30s for
        // tools/list — mid-loop tool calls can legitimately take
        // longer because the work itself is unbounded). Caller can
        // pass a tighter deadline via a future v2 config field.
        const deadline_ns: u64 = 60 * std.time.ns_per_s;
        return callViaStdio(allocator, logger, server_name, actual_tool_name, tool_call.function.arguments, server_obj, deadline_ns);
    }

    const url_value = server_obj.get("url") orelse {
        return error.MCPServerURLNotFound;
    };
    const url = url_value.string;

    logger.debugFmt("MCP HTTP dispatch to {s}", .{url});

    // Build the custom_headers slice from the JSON object. MCP headers
    // are a small bounded set; we use a stack buffer (max 16) to avoid
    // a heap allocation on the hot path.
    var std_header_buf: [16]custom_http_client.Header = undefined;
    var header_count: usize = 0;
    if (server_obj.get("headers")) |headers_value| {
        const headers_obj = switch (headers_value) {
            .object => |obj| obj,
            else => {
                return error.InvalidMCPServerHeadersConfig;
            },
        };
        var header_iter = headers_obj.iterator();
        while (header_iter.next()) |h_entry| {
            if (header_count >= std_header_buf.len) return error.InvalidMCPServerHeadersConfig;
            const value = switch (h_entry.value_ptr.*) {
                .string => |s| s,
                else => continue,
            };
            std_header_buf[header_count] = .{
                .name = h_entry.key_ptr.*,
                .value = value,
            };
            header_count += 1;
        }
    }
    const custom_headers = std_header_buf[0..header_count];

    // Get or build a cached HTTP client for this server. The process-
    // global registry keeps the client alive for the process lifetime
    // (the arena memory is freed at process exit). A future v2 may
    // wire main.zig's shutdown hook to call HttpRegistry.deinitGlobal() —
    // for now, same pattern as mcp_stdio.StdioRegistry.
    const http_registry = mcp_http.HttpRegistry.global();
    const http_client = http_registry.getOrConnect(
        server_name,
        url,
        custom_headers,
    ) catch |err| {
        logger.errFmt("MCP HTTP client build failed: {s}", .{@errorName(err)});
        return error.FailedToCallMCPServer;
    };

    // Send the request. callTool returns the raw JSON-RPC response body
    // (the SSE parser inside the client has already extracted the final
    // event's data: field if the server returned SSE).
    const response_body = http_client.callTool(actual_tool_name, tool_call.function.arguments) catch |err| {
        logger.errFmt("MCP HTTP call failed: {s}", .{@errorName(err)});
        return error.FailedToCallMCPServer;
    };
    defer allocator.free(response_body);

    // Extract `result.content[0].text` (this function's contract: the
    // agent sees the text content, not the raw JSON-RPC envelope).
    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, parse_arena.allocator(), response_body, .{}) catch {
        logger.errFmt("MCP HTTP response not valid JSON: len={d}", .{response_body.len});
        return error.MCPJSONParseError;
    };

    if (parsed.value.object.get("result")) |result_val| {
        if (result_val.object.get("content")) |content_val| {
            // Most common shape: {content: [{type: "text", text: "..."}]}
            if (content_val == .array) {
                if (content_val.array.items.len > 0) {
                    if (content_val.array.items[0].object.get("text")) |text_val| {
                        if (text_val == .string) {
                            return try allocator.dupe(u8, text_val.string);
                        }
                    }
                }
            }
            // Fallback shape: {content: "string"}
            if (content_val == .string) {
                return try allocator.dupe(u8, content_val.string);
            }
        }
    }

    // No content extractable — return the raw response body (caller
    // may want to inspect the JSON-RPC error envelope if any).
    return try allocator.dupe(u8, response_body);
}

// ============================================================================
// stdio transport: spawn a child process per server, send framed
// JSON-RPC over its stdin, read the framed response from stdout.
// ============================================================================

/// Call a tool via the stdio transport. Spawns (or reuses) a child
/// process keyed by `server_name`, sends a framed `tools/call` JSON-RPC
/// body, and reads the framed response. Returns the extracted text
/// content (the `result.content[0].text` field, freshly allocated).
///
/// `deadline_ns` is forwarded to both send and recv. On
/// `SendTimeout` / `RecvTimeout`, the registry's `markStale` is
/// called so the next `getOrSpawn` for `server_name` spawns a
/// fresh child. Self-healing: a single hung tool call doesn't
/// permanently brick subsequent calls.
fn callViaStdio(
    allocator: std.mem.Allocator,
    logger: *logger_mod.Logger,
    server_name: []const u8,
    tool_name: []const u8,
    arguments_json: []const u8,
    server_obj: std.json.ObjectMap,
    deadline_ns: u64,
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
    const reg = mcp_stdio.StdioRegistry.global();

    // Retry loop for cold-start / stale child. Use NDJSON framing (like
    // the discovery path) — Python and Node SDKs both default to NDJSON.
    var last_err: anyerror = error.FailedToCallMCPServer;
    var attempt: u8 = 0;
    var resp: []u8 = undefined;
    var resp_owned = false;
    while (attempt < 3) : (attempt += 1) {
        const client = reg.getOrSpawn(server_name, argv) catch |err| {
            logger.errFmt("stdio MCP spawn failed for {s}.{s}: {s}", .{ server_name, tool_name, @errorName(err) });
            last_err = err;
            if (attempt + 1 < 3) {
                
                continue;
            }
            return error.FailedToCallMCPServer;
        };

        const req = try buildToolCallRequestBody(allocator, tool_name, arguments_json);
        defer allocator.free(req);

        // Send as NDJSON (JSON + '\n'), not Content-Length
        client.sendNDJSON(req) catch |err| {
            logger.errFmt("stdio MCP send failed for {s}.{s}: {s}", .{ server_name, tool_name, @errorName(err) });
            last_err = err;
            if (err == error.SendTimeout or err == error.BrokenPipe) reg.markStale(server_name);
            const is_retryable = err == error.BrokenPipe or err == error.SendTimeout;
            if (is_retryable and attempt + 1 < 3) {
                
                continue;
            }
            return error.FailedToCallMCPServer;
        };
        const r = client.recv(deadline_ns, null) catch |err| {
            logger.errFmt("stdio MCP recv failed for {s}.{s}: {s}", .{ server_name, tool_name, @errorName(err) });
            last_err = err;
            if (err == error.RecvTimeout) reg.markStale(server_name);
            const is_retryable = err == error.RecvTimeout or err == error.UnexpectedEof or err == error.BrokenPipe;
            if (is_retryable and attempt + 1 < 3) {
                
                continue;
            }
            return error.MCPServerReturnedError;
        };
        resp = r;
        resp_owned = true;
        break;
    }
    if (!resp_owned) return last_err;
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
    // Large payload guard: truncate tool results over 100KB to avoid
    // downstream SEGV / OOM / LLM context overflow. The 120KB graph
    // data that crashed the backend is a real example.
    const MAX_TOOL_RESULT_BYTES: usize = 100 * 1024;
    if (tool_result.len > MAX_TOOL_RESULT_BYTES) {
        logger.warnFmt("MCP tool result too large: {} bytes, truncating to {} bytes", .{ tool_result.len, MAX_TOOL_RESULT_BYTES });
        const truncated = try std.fmt.allocPrint(allocator, "{s}\n\n[truncated: original was {} bytes, showing first {} bytes]", .{ tool_result[0..MAX_TOOL_RESULT_BYTES], tool_result.len, MAX_TOOL_RESULT_BYTES });
        allocator.free(tool_result);
        // resp is arena-allocated (per-iteration arena in workflow.zig),
        // so it will be freed at iteration end — no need to free here.
        // But if this is called outside workflow (e.g. Test), free it.
        // We don't free resp here to avoid double-free with errdefer;
        // the arena handles it. Just return truncated.
        return truncated;
    }
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
