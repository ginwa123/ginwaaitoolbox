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
    pub fn registerTool(self: *Self, tool: mcp_types.McpTool) !void {
        try self.tools.put(tool.name, tool);
    }

    /// Set tool executor function
    pub fn setToolExecutor(self: *Self, executor: ToolExecutor) void {
        self.toolExecutor = executor;
    }

    /// Run the server - handles incoming requests
    pub fn run(self: *Self) !void {
        while (true) {
            const message = self.transport.readMessage() catch |e| {
                if (e == error.EndOfStream) {
                    break;
                }
                std.debug.print("MCP transport error: {}\n", .{e});
                continue;
            };
            defer self.allocator.free(message);

            // Parse and handle the request
            self.handleMessage(message) catch |e| {
                std.debug.print("MCP handle error: {}\n", .{e});
            };
        }
    }

    /// Handle a single JSON-RPC message
    fn handleMessage(self: *Self, message: []const u8) !void {
        // Parse JSON-RPC request
        var parser = json.Parser.init(self.allocator, .{
            .allow_trailing_comma = true,
        });
        defer parser.deinit();

        const json_value = parser.parse(message) catch {
            return self.sendError(null, .ParseError, "Invalid JSON");
        };
        defer json_value.deinit();

        const obj = json_value.object orelse {
            return self.sendError(null, .InvalidRequest, "Expected object");
        };

        const method_field = obj.get("method") orelse {
            return self.sendError(null, .InvalidRequest, "Missing method");
        };
        
        const method_str = method_field.string;
        const id = obj.get("id");

        // Handle methods
        if (std.mem.eql(u8, method_str, "initialize")) {
            try self.handleInitialize(id, obj.get("params"));
        } else if (std.mem.eql(u8, method_str, "tools/list")) {
            try self.handleToolsList(id);
        } else if (std.mem.eql(u8, method_str, "tools/call")) {
            try self.handleToolsCall(id, obj.get("params"));
        } else if (std.mem.eql(u8, method_str, "resources/list")) {
            try self.handleResourcesList(id);
        } else if (std.mem.eql(u8, method_str, "resources/read")) {
            try self.handleResourcesRead(id, obj.get("params"));
        } else if (std.mem.startsWith(u8, method_str, "notifications/")) {
            // Notifications don't get responses
        } else {
            return self.sendError(id, .MethodNotFound, "Unknown method");
        }
    }

    fn handleInitialize(self: *Self, id: ?json.Value, params: ?json.Value) !void {
        // Parse capabilities if provided
        if (params) |p| {
            if (p.object) |params_obj| {
                if (params_obj.get("capabilities")) |caps| {
                    // Store client capabilities if needed
                    _ = caps;
                }
                if (params_obj.get("clientInfo")) |ci| {
                    _ = ci;
                }
            }
        }

        // Send response
        const result = try self.buildInitializeResult();
        try self.sendResponse(id, result);
    }

    fn buildInitializeResult(self: *Self) ![]u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        try buf.appendSlice(
            \\{"protocolVersion":"2024-11-05","capabilities":{"tools":
        );
        try buf.appendSlice(if (self.capabilities.tools != null) "{\"listChanged\":false}" else "null");
        try buf.appendSlice(
            \\},"serverInfo":{"name":"nalarcore-mcp","version":"0.0.1"}}
        );

        return try buf.toOwnedSlice();
    }

    fn handleToolsList(self: *Self, id: ?json.Value) !void {
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        try buf.appendSlice(
            \\{"tools":[}
        );

        var iter = self.tools.iterator();
        var first = true;
        while (iter.next()) |entry| {
            const tool = entry.value_ptr.*;
            if (!first) try buf.appendSlice(",");
            first = false;

            // Simplified tool serialization
            try buf.appendSlice("{\"name\":\"");
            try buf.appendSlice(tool.name);
            try buf.appendSlice("\",\"description\":\"");
            try buf.appendSlice(tool.description);
            try buf.appendSlice("\",\"inputSchema\":{\"type\":\"object\"}}");
        }

        try buf.appendSlice("]}");

        try self.sendResponse(id, try buf.toOwnedSlice());
    }

    fn handleToolsCall(self: *Self, id: ?json.Value, params: ?json.Value) !void {
        if (params == null or self.toolExecutor == null) {
            return self.sendError(id, .InvalidParams, "Missing params or executor");
        }

        const params_obj = params.?.object orelse {
            return self.sendError(id, .InvalidParams, "Expected object params");
        };

        const name_field = params_obj.get("name") orelse {
            return self.sendError(id, .InvalidParams, "Missing tool name");
        };
        const arguments = params_obj.get("arguments");

        // Call the tool
        const result = try self.toolExecutor.?(self.allocator, name_field.string, arguments);

        // Build response
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        try buf.appendSlice(
            \\{"content":[{"type":"text","text":"
        );

        // Serialize result as JSON string
        json.stringifyFree(
            result,
            buf.writer(),
            .{},
        ) catch |e| {
            return self.sendError(id, .InternalError, @errorName(e));
        };

        try buf.appendSlice("\"}]}");

        try self.sendResponse(id, try buf.toOwnedSlice());
    }

    fn handleResourcesList(self: *Self, id: ?json.Value) !void {
        // Empty resources for now
        try self.sendResponse(id, "{\"resources\":[]}");
    }

    fn handleResourcesRead(self: *Self, id: ?json.Value, params: ?json.Value) !void {
        _ = params;
        try self.sendResponse(id, "{\"contents\":[]}");
    }

    fn sendResponse(self: *Self, id: ?json.Value, result: []const u8) !void {
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        try buf.appendSlice("{\"jsonrpc\":\"2.0\"");
        
        if (id) |i| {
            try buf.appendSlice(",\"id\":");
            try json.stringifyFree(i, buf.writer(), .{});
        }
        
        try buf.appendSlice(",\"result\":");
        try buf.appendSlice(result);
        
        try buf.append('}');

        try self.transport.writeMessage(try buf.toOwnedSlice());
    }

    fn sendError(self: *Self, id: ?json.Value, code: mcp_types.ErrorCode, message: []const u8) !void {
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        try buf.appendSlice("{\"jsonrpc\":\"2.0\",\"error\":{\"code\":");
        try buf.appendInt(@intFromEnum(code));
        try buf.appendSlice(",\"message\":\"");
        try buf.appendSlice(message);
        try buf.appendSlice("\"}");

        if (id) |i| {
            try buf.appendSlice(",\"id\":");
            try json.stringifyFree(i, buf.writer(), .{});
        }

        try buf.append('}');

        try self.transport.writeMessage(try buf.toOwnedSlice());
    }
};

test {
    _ = @import("mcp_server_test.zig");
}
