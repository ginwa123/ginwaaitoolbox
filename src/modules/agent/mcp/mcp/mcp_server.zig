const std = @import("std");
const json = std.json;
const mcp_types = @import("mcp_types.zig");
const mcp_transport = @import("mcp_transport.zig");

/// MCP Server error types
pub const McpError = error{
    ParseError,
    InvalidRequest,
    MethodNotFound,
    InvalidParams,
    InternalError,
};

/// Tool executor function type
pub const ToolExecutor = fn (
    allocator: std.mem.Allocator,
    name: []const u8,
    arguments: ?std.json.Value,
) anyerror!std.json.Value;

// ============ JSON Response Types with jsonStringify ============

/// Initialize result response
const InitializeResult = struct {
    protocolVersion: []const u8,
    capabilities: InitializeCapabilities,
    serverInfo: ServerInfo,

    const InitializeCapabilities = struct {
        tools: ?ToolsCapability = null,
        resources: ?ResourcesCapability = null,
    };

    const ToolsCapability = struct {
        listChanged: bool = false,
    };

    const ResourcesCapability = struct {
        subscribe: bool = false,
        listChanged: bool = false,
    };

    const ServerInfo = struct {
        name: []const u8,
        version: []const u8,
    };

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("protocolVersion");
        try jws.write(self.protocolVersion);
        try jws.objectField("capabilities");
        try jws.write(self.capabilities);
        try jws.objectField("serverInfo");
        try jws.write(self.serverInfo);
        try jws.endObject();
    }
};

/// List tools response
const ListToolsResult = struct {
    tools: []const mcp_types.McpTool,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("tools");
        try jws.write(self.tools);
        try jws.endObject();
    }
};

/// List resources response
const ListResourcesResult = struct {
    resources: []const mcp_types.Resource,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("resources");
        try jws.write(self.resources);
        try jws.endObject();
    }
};

/// Read resource result
const ReadResourceResult = struct {
    contents: []const mcp_types.ResourceContents,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("contents");
        try jws.write(self.contents);
        try jws.endObject();
    }
};

/// Call tool result
const CallToolResult = struct {
    content: []const ContentBlock,
    isError: bool = false,

    const ContentBlock = struct {
        type: []const u8,
        text: ?[]const u8 = null,

        pub fn jsonStringify(self: @This(), jws: anytype) !void {
            try jws.beginObject();
            try jws.objectField("type");
            try jws.write(self.type);
            if (self.text) |t| {
                try jws.objectField("text");
                try jws.write(t);
            }
            try jws.endObject();
        }
    };

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("content");
        try jws.write(self.content);
        try jws.objectField("isError");
        try jws.write(self.isError);
        try jws.endObject();
    }
};

/// JSON-RPC response
const JsonRpcResponse = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?json.Value,
    result: ?json.Value = null,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("jsonrpc");
        try jws.write(self.jsonrpc);
        if (self.id) |i| {
            try jws.objectField("id");
            try jws.write(i);
        }
        if (self.result) |r| {
            try jws.objectField("result");
            try jws.write(r);
        }
        try jws.endObject();
    }
};

/// JSON-RPC error response
const JsonRpcErrorResponse = struct {
    jsonrpc: []const u8 = "2.0",
    @"error": JsonRpcError,
    id: ?json.Value = null,

    const JsonRpcError = struct {
        code: i32,
        message: []const u8,

        pub fn jsonStringify(self: @This(), jws: anytype) !void {
            try jws.beginObject();
            try jws.objectField("code");
            try jws.write(self.code);
            try jws.objectField("message");
            try jws.write(self.message);
            try jws.endObject();
        }
    };

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("jsonrpc");
        try jws.write(self.jsonrpc);
        try jws.objectField("error");
        try jws.write(self.@"error");
        if (self.id) |i| {
            try jws.objectField("id");
            try jws.write(i);
        }
        try jws.endObject();
    }
};

// ============ MCP Server Implementation ============

/// MCP Server
pub const McpServer = struct {
    allocator: std.mem.Allocator,
    transport: mcp_transport.McpTransport,
    protocolVersion: []const u8 = "2024-11-05",
    capabilities: mcp_types.ServerCapabilities,
    toolExecutor: ?ToolExecutor = null,
    tools: std.StringHashMap(mcp_types.McpTool),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .transport = mcp_transport.McpTransport.init(allocator),
            .capabilities = .{
                .tools = .{ .listChanged = false },
                .resources = null,
            },
            .tools = std.StringHashMap(mcp_types.McpTool).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.tools.deinit();
    }

    /// Register a tool with the server
    pub fn register_tool(self: *Self, tool: mcp_types.McpTool) !void {
        try self.tools.put(tool.name, tool);
    }

    /// Set tool executor function
    pub fn set_tool_executor(self: *Self, executor: ToolExecutor) void {
        self.toolExecutor = executor;
    }

    /// Run the server - handles incoming requests
    pub fn run(self: *Self) !void {
        while (true) {
            const message = self.transport.read_message() catch |e| {
                if (e == error.EndOfStream) {
                    break;
                }
                std.debug.print("MCP transport error: {}\n", .{e});
                continue;
            };
            defer self.allocator.free(message);

            // Parse and handle the request
            self.handle_message(message) catch |e| {
                std.debug.print("MCP handle error: {}\n", .{e});
            };
        }
    }

    /// Handle a single JSON-RPC message
    fn handle_message(self: *Self, message: []const u8) !void {
        // Parse JSON-RPC request
        var parser = json.Parser.init(self.allocator, .{
            .allow_trailing_comma = true,
        });
        defer parser.deinit();

        const json_value = parser.parse(message) catch {
            return self.send_error(null, .ParseError, "Invalid JSON");
        };
        defer json_value.deinit();

        const obj = json_value.object orelse {
            return self.send_error(null, .InvalidRequest, "Expected object");
        };

        const method_field = obj.get("method") orelse {
            return self.send_error(null, .InvalidRequest, "Missing method");
        };

        const method_str = method_field.string;
        const id = obj.get("id");

        // Handle methods
        if (std.mem.eql(u8, method_str, "initialize")) {
            try self.handle_initialize(id, obj.get("params"));
        } else if (std.mem.eql(u8, method_str, "initialized")) {
            // Notification: client confirms initialization complete, no response
        } else if (std.mem.eql(u8, method_str, "ping")) {
            try self.handle_ping(id);
        } else if (std.mem.eql(u8, method_str, "tools/list")) {
            try self.handle_tools_list(id);
        } else if (std.mem.eql(u8, method_str, "tools/call")) {
            try self.handle_tools_call(id, obj.get("params"));
        } else if (std.mem.eql(u8, method_str, "resources/list")) {
            try self.handle_resources_list(id);
        } else if (std.mem.eql(u8, method_str, "resources/read")) {
            try self.handle_resources_read(id, obj.get("params"));
        } else if (std.mem.eql(u8, method_str, "resources/subscribe")) {
            try self.handle_resources_subscribe(id, obj.get("params"));
        } else if (std.mem.eql(u8, method_str, "resources/unsubscribe")) {
            try self.handle_resources_unsubscribe(id, obj.get("params"));
        } else if (std.mem.eql(u8, method_str, "prompts/list")) {
            try self.handle_prompts_list(id);
        } else if (std.mem.eql(u8, method_str, "prompts/get")) {
            try self.handle_prompts_get(id, obj.get("params"));
        } else if (std.mem.eql(u8, method_str, "completion/complete")) {
            try self.handle_completion_complete(id, obj.get("params"));
        } else if (std.mem.eql(u8, method_str, "logging/setLevel")) {
            try self.handle_logging_set_level(id, obj.get("params"));
        } else if (std.mem.startsWith(u8, method_str, "notifications/")) {
            // Notifications don't get responses
        } else {
            return self.send_error(id, .MethodNotFound, "Unknown method");
        }
    }

    fn handle_initialize(self: *Self, id: ?json.Value, params: ?json.Value) !void {
        // Parse capabilities if provided
        if (params) |p| {
            if (p.object) |params_obj| {
                if (params_obj.get("capabilities")) |caps| {
                    _ = caps;
                }
                if (params_obj.get("clientInfo")) |ci| {
                    _ = ci;
                }
            }
        }

        // Build response using struct with jsonStringify
        const result = InitializeResult{
            .protocolVersion = self.protocolVersion,
            .capabilities = .{
                .tools = .{ .listChanged = false },
                .resources = null,
                .prompts = .{ .listChanged = false },
                .completions = .{},
                .logging = .{},
            },
            .serverInfo = .{
                .name = "nalarcore-mcp",
                .version = "0.0.1",
            },
        };

        try self.send_response(id, result);
    }

    fn handle_tools_list(self: *Self, id: ?json.Value) !void {
        // Collect tools into a slice
        var tools_list = std.ArrayList(mcp_types.McpTool).init(self.allocator);
        defer tools_list.deinit();

        var iter = self.tools.iterator();
        while (iter.next()) |entry| {
            try tools_list.append(entry.value_ptr.*);
        }

        const result = ListToolsResult{
            .tools = try tools_list.toOwnedSlice(),
        };
        errdefer self.allocator.free(result.tools);

        try self.send_response(id, result);
    }

    fn handle_tools_call(self: *Self, id: ?json.Value, params: ?json.Value) !void {
        if (params == null or self.toolExecutor == null) {
            return self.send_error(id, .InvalidParams, "Missing params or executor");
        }

        const params_obj = params.?.object orelse {
            return self.send_error(id, .InvalidParams, "Expected object params");
        };

        const name_field = params_obj.get("name") orelse {
            return self.send_error(id, .InvalidParams, "Missing tool name");
        };
        const arguments = params_obj.get("arguments");

        // Call the tool
        const tool_result = try self.toolExecutor.?(self.allocator, name_field.string, arguments);

        // Build response - convert JSON value to string for content
        var content_text: []u8 = undefined;
        {
            var aw: std.io.Writer.Allocating = .init(self.allocator);
            try aw.writer.print("{f}", .{std.json.fmt(tool_result, .{})});
            content_text = try aw.toOwnedSlice();
        }
        errdefer self.allocator.free(content_text);

        const content_block = CallToolResult.ContentBlock{
            .type = "text",
            .text = content_text,
        };

        const result = CallToolResult{
            .content = &.{content_block},
            .isError = false,
        };

        try self.send_response(id, result);
    }

    fn handle_resources_list(self: *Self, id: ?json.Value) !void {
        const result = ListResourcesResult{
            .resources = &.{},
        };
        try self.send_response(id, result);
    }

    fn handle_resources_read(self: *Self, id: ?json.Value, params: ?json.Value) !void {
        _ = params;
        const result = ReadResourceResult{
            .contents = &.{},
        };
        try self.send_response(id, result);
    }

    fn handle_ping(self: *Self, id: ?json.Value) !void {
        // Ping returns an empty result object
        const EmptyResult = struct {};
        try self.send_response(id, EmptyResult{});
    }

    fn handle_resources_subscribe(self: *Self, id: ?json.Value, params: ?json.Value) !void {
        _ = params;
        // Acknowledge subscription (actual subscription tracking not implemented)
        const EmptyResult = struct {};
        try self.send_response(id, EmptyResult{});
    }

    fn handle_resources_unsubscribe(self: *Self, id: ?json.Value, params: ?json.Value) !void {
        _ = params;
        // Acknowledge unsubscription (actual subscription tracking not implemented)
        const EmptyResult = struct {};
        try self.send_response(id, EmptyResult{});
    }

    fn handle_prompts_list(self: *Self, id: ?json.Value) !void {
        const ListPromptsResult = struct {
            prompts: []const mcp_types.Prompt,

            pub fn jsonStringify(s: @This(), jws: anytype) !void {
                try jws.beginObject();
                try jws.objectField("prompts");
                try jws.write(s.prompts);
                try jws.endObject();
            }
        };
        const result = ListPromptsResult{
            .prompts = &.{},
        };
        try self.send_response(id, result);
    }

    fn handle_prompts_get(self: *Self, id: ?json.Value, params: ?json.Value) !void {
        _ = params;
        // Prompts not yet implemented - return empty result for now
        const GetPromptResult = struct {
            description: ?[]const u8 = null,
            messages: []const struct {} = &.{},

            pub fn jsonStringify(s: @This(), jws: anytype) !void {
                try jws.beginObject();
                if (s.description) |d| {
                    try jws.objectField("description");
                    try jws.write(d);
                }
                try jws.objectField("messages");
                try jws.write(s.messages);
                try jws.endObject();
            }
        };
        const result = GetPromptResult{};
        try self.send_response(id, result);
    }

    fn handle_completion_complete(self: *Self, id: ?json.Value, params: ?json.Value) !void {
        _ = params;
        const CompleteResult = struct {
            completion: struct {
                values: []const []const u8,
                total: ?i32 = null,
                hasMore: ?bool = null,

                pub fn jsonStringify(s: @This(), jws: anytype) !void {
                    try jws.beginObject();
                    try jws.objectField("values");
                    try jws.write(s.values);
                    if (s.total) |t| {
                        try jws.objectField("total");
                        try jws.write(t);
                    }
                    if (s.hasMore) |h| {
                        try jws.objectField("hasMore");
                        try jws.write(h);
                    }
                    try jws.endObject();
                }
            },

            pub fn jsonStringify(s: @This(), jws: anytype) !void {
                try jws.beginObject();
                try jws.objectField("completion");
                try jws.write(s.completion);
                try jws.endObject();
            }
        };
        const result = CompleteResult{
            .completion = .{
                .values = &.{},
                .total = 0,
                .hasMore = false,
            },
        };
        try self.send_response(id, result);
    }

    fn handle_logging_set_level(self: *Self, id: ?json.Value, params: ?json.Value) !void {
        _ = params;
        // Log level stored but not yet used (logging infrastructure not implemented)
        const EmptyResult = struct {};
        try self.send_response(id, EmptyResult{});
    }

    fn send_response(self: *Self, id: ?json.Value, result: anytype) !void {
        // Use arena for JSON construction
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const response = JsonRpcResponse{
            .id = id,
            .result = result,
        };

        var aw: std.io.Writer.Allocating = .init(arena_alloc);
        try aw.writer.print("{f}", .{std.json.fmt(response, .{})});
        const message = try aw.toOwnedSlice();
        errdefer arena_alloc.free(message);

        try self.transport.write_message(try self.allocator.dupe(u8, message));
    }

    fn send_error(self: *Self, id: ?json.Value, code: mcp_types.ErrorCode, message: []const u8) !void {
        // Use arena for JSON construction
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const error_resp = JsonRpcErrorResponse{
            .@"error" = .{
                .code = @intFromEnum(code),
                .message = message,
            },
            .id = id,
        };

        var aw: std.io.Writer.Allocating = .init(arena_alloc);
        try aw.writer.print("{f}", .{std.json.fmt(error_resp, .{})});
        const json_str = try aw.toOwnedSlice();
        errdefer arena_alloc.free(json_str);

        try self.transport.write_message(try self.allocator.dupe(u8, json_str));
    }
};

test {
    _ = @import("mcp_server_test.zig");
}
