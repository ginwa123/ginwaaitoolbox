const std = @import("std");
const json = std.json;
const bashTool = @import("tools/bash.zig").bashTool;
const bashMod = @import("tools/bash.zig");
const BashInput = @import("tools/models.zig").BashInput;
const ToolProperty = @import("tools/models.zig").ToolProperty;
const ToolParameters = @import("tools/models.zig").ToolParameters;
const AgentToolFunction = @import("tools/models.zig").AgentToolFunction;
const AgentTool = @import("tools/models.zig").AgentTool;
const log = @import("tree1").logger;

// https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create

/// Get current timestamp in milliseconds since epoch
fn timestampMs() i64 {
    return @divTrunc(std.time.milliTimestamp(), 1);
}

/// Calculate elapsed time in milliseconds
fn elapsedMs(start: i64) i64 {
    return timestampMs() - start;
}

/// Format duration for human-readable output
fn formatDuration(ms: i64) struct { value: i64, unit: []const u8 } {
    if (ms < 1000) return .{ .value = ms, .unit = "ms" };
    if (ms < 60000) return .{ .value = @divTrunc(ms, 1000), .unit = "s" };
    return .{ .value = @divTrunc(ms, 60000), .unit = "min" };
}

pub const UnresolvedIntentResult = struct {
    has_unresolved: bool,
    reason: ?[]const u8, // Owned by caller, must be freed
};

pub const ToolCall = struct {
    id: []const u8,
    type: []const u8 = "function",
    function: FunctionCall,
};

pub const FunctionCall = struct {
    name: []const u8,
    arguments: []const u8,
};

// JSON serialization types for API requests
// These types handle snake_case field names and null field omission

/// JSON-serializable function call - arguments is a string containing JSON
const JsonFunctionCall = struct {
    name: []const u8,
    arguments: []const u8, // JSON string that will be properly escaped
};

/// JSON-serializable tool call with snake_case field names
const JsonToolCall = struct {
    id: []const u8,
    type: []const u8 = "function",
    function: JsonFunctionCall,
};

/// JSON-serializable message with custom serialization to omit null fields
const JsonMessage = struct {
    role: []const u8,
    content: ?[]const u8 = null,
    tool_calls: ?[]const JsonToolCall = null,
    tool_call_id: ?[]const u8 = null,
    reasoning_content: ?[]const u8 = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("role");
        try stringify.write(self.role);
        if (self.content) |c| {
            try stringify.objectField("content");
            try stringify.write(c);
        }
        if (self.tool_calls) |tc| {
            try stringify.objectField("tool_calls");
            try stringify.write(tc);
        }
        if (self.tool_call_id) |id| {
            try stringify.objectField("tool_call_id");
            try stringify.write(id);
        }
        if (self.reasoning_content) |rc| {
            try stringify.objectField("reasoning_content");
            try stringify.write(rc);
        }
        try stringify.endObject();
    }
};

/// JSON-serializable tool parameters with custom serialization for properties map
const JsonToolParameters = struct {
    properties: []const ToolProperty,
    required: []const []const u8,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write("object");
        try stringify.objectField("properties");
        try stringify.beginObject();
        for (self.properties) |prop| {
            try stringify.objectField(prop.name);
            try stringify.beginObject();
            try stringify.objectField("type");
            try stringify.write(prop.type);
            try stringify.objectField("description");
            try stringify.write(prop.description);
            try stringify.endObject();
        }
        try stringify.endObject();
        try stringify.objectField("required");
        try stringify.write(self.required);
        try stringify.endObject();
    }
};

/// JSON-serializable tool function
const JsonToolFunction = struct {
    name: []const u8,
    description: []const u8,
    parameters: JsonToolParameters,
};

/// JSON-serializable tool
const JsonTool = struct {
    type: []const u8,
    function: JsonToolFunction,
};

/// Thinking configuration for requests
const JsonThinkingConfig = struct {
    type: []const u8 = "disabled",
};

/// JSON-serializable request with custom serialization for conditional fields
const JsonRequest = struct {
    model: []const u8,
    enable_thinking: bool,
    thinking: ?JsonThinkingConfig = null,
    messages: []const JsonMessage,
    temperature: f32,
    max_tokens: usize,
    stream: bool,
    tools: ?[]const JsonTool = null,
    tool_choice: ?[]const u8 = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();

        // model
        try stringify.objectField("model");
        try stringify.write(self.model);

        // thinking config (only when disabled)
        if (self.thinking) |th| {
            try stringify.objectField("thinking");
            try stringify.write(th);
        }

        // enable_thinking
        try stringify.objectField("enable_thinking");
        try stringify.write(self.enable_thinking);

        // messages
        try stringify.objectField("messages");
        try stringify.write(self.messages);

        // temperature
        try stringify.objectField("temperature");
        try stringify.write(self.temperature);

        // max_tokens
        try stringify.objectField("max_tokens");
        try stringify.write(self.max_tokens);

        // stream (only when true)
        if (self.stream) {
            try stringify.objectField("stream");
            try stringify.write(true);
        }

        // tools (only when present)
        if (self.tools) |t| {
            try stringify.objectField("tools");
            try stringify.write(t);
            try stringify.objectField("tool_choice");
            try stringify.write(self.tool_choice.?);
        }

        try stringify.endObject();
    }
};

pub const AgentResponse = struct {
    choices: []Choice,
};

pub const Choice = struct {
    index: usize = 0,
    message: Message,
    finish_reason: ?FinishReason = null,
};

pub const Message = struct {
    role: []const u8 = "assistant",
    content: ?[]const u8 = null,
    tool_calls: ?[]ToolCall = null,
    reasoning_content: ?[]const u8 = null,
};

pub const Role = enum {
    /// System message
    system,
    /// User message
    user,
    /// Assistant message
    assistant,
    /// Tool result message
    tool,

    pub fn fromStr(s: []const u8) ?Role {
        if (std.mem.eql(u8, s, "system")) return .system;
        if (std.mem.eql(u8, s, "user")) return .user;
        if (std.mem.eql(u8, s, "assistant")) return .assistant;
        if (std.mem.eql(u8, s, "tool")) return .tool;
        return null;
    }

    pub fn toStr(self: Role) []const u8 {
        return switch (self) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
            .tool => "tool",
        };
    }
};

pub const AgentMessage = struct {
    role: Role,
    content: ?[]const u8,
    tool_calls: ?[]ToolCall = null,
    tool_call_id: ?[]const u8 = null,
    reasoning_content: ?[]const u8 = null,

    pub fn deinit(self: *const AgentMessage, allocator: std.mem.Allocator) void {
        if (self.content) |c| allocator.free(c);
        if (self.tool_call_id) |id| allocator.free(id);
        if (self.reasoning_content) |rc| allocator.free(rc);
        if (self.tool_calls) |tc| {
            for (tc) |*tool_call| {
                allocator.free(tool_call.id);
                allocator.free(tool_call.function.name);
                allocator.free(tool_call.function.arguments);
            }
            allocator.free(tc);
        }
    }
};

pub const FinishReason = enum {
    /// Model generated a complete message
    stop,
    /// Model hit max tokens limit
    length,
    /// Model triggered a tool call
    tool_calls,
    /// Content was filtered due to safety policies
    content_filter,
    /// No finish reason provided
    null,

    pub fn fromStr(s: ?[]const u8) ?FinishReason {
        if (s == null) return .null;
        const str = s.?;
        if (std.mem.eql(u8, str, "stop")) return .stop;
        if (std.mem.eql(u8, str, "length")) return .length;
        if (std.mem.eql(u8, str, "tool_calls")) return .tool_calls;
        if (std.mem.eql(u8, str, "content_filter")) return .content_filter;
        return null;
    }

    pub fn toStr(self: FinishReason) []const u8 {
        return switch (self) {
            .stop => "stop",
            .length => "length",
            .tool_calls => "tool_calls",
            .content_filter => "content_filter",
            .null => "null",
        };
    }
};

/// Token usage information from the API
pub const Usage = struct {
    prompt_tokens: usize = 0,
    completion_tokens: usize = 0,
    total_tokens: usize = 0,
};

/// Delta for tool calls in streaming responses
pub const ToolCallDelta = struct {
    index: usize,
    id: ?[]const u8 = null,
    function_name: ?[]const u8 = null,
    function_arguments: ?[]const u8 = null,
};

/// Parsed chunk from streaming response
pub const StreamChunk = struct {
    content: ?[]const u8 = null,
    reasoning_content: ?[]const u8 = null,
    tool_calls_delta: ?[]const ToolCallDelta = null,
    finish_reason: ?FinishReason = null,
    usage: ?Usage = null,
    done: bool = false,
};

/// Callback function type for streaming
pub const StreamCallback = *const fn (ctx: ?*anyopaque, chunk: StreamChunk) void;

/// Aggregator for combining streaming chunks into a complete response
pub const StreamingAggregator = struct {
    allocator: std.mem.Allocator,
    content: std.ArrayList(u8),
    reasoning_content: std.ArrayList(u8),
    tool_calls: std.ArrayList(ToolCall),
    finish_reason: ?FinishReason = null,
    usage: Usage = .{},

    /// Tool call accumulation state
    tool_call_buffers: std.AutoHashMap(usize, struct {
        id: ?[]const u8 = null,
        name: ?[]const u8 = null,
        arguments: std.ArrayList(u8),
    }),

    pub fn init(allocator: std.mem.Allocator) StreamingAggregator {
        return .{
            .allocator = allocator,
            .content = .empty,
            .reasoning_content = .empty,
            .tool_calls = .empty,
            .tool_call_buffers = .init(allocator),
        };
    }

    pub fn deinit(self: *StreamingAggregator) void {
        self.content.deinit(self.allocator);
        self.reasoning_content.deinit(self.allocator);
        for (self.tool_calls.items) |*tc| {
            self.allocator.free(tc.id);
            self.allocator.free(tc.function.name);
            self.allocator.free(tc.function.arguments);
        }
        self.tool_calls.deinit(self.allocator);

        var iter = self.tool_call_buffers.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.id) |id| self.allocator.free(id);
            if (entry.value_ptr.name) |name| self.allocator.free(name);
            entry.value_ptr.arguments.deinit(self.allocator);
        }
        self.tool_call_buffers.deinit();
    }

    pub fn processChunk(self: *StreamingAggregator, chunk: StreamChunk) !void {
        if (chunk.done) return;

        // Accumulate content
        if (chunk.content) |c| {
            try self.content.appendSlice(self.allocator, c);
        }

        // Accumulate reasoning content
        if (chunk.reasoning_content) |rc| {
            try self.reasoning_content.appendSlice(self.allocator, rc);
        }

        // Process tool call deltas
        if (chunk.tool_calls_delta) |deltas| {
            for (deltas) |delta| {
                const gop = try self.tool_call_buffers.getOrPut(delta.index);
                if (!gop.found_existing) {
                    gop.value_ptr.* = .{
                        .id = null,
                        .name = null,
                        .arguments = .empty,
                    };
                }

                if (delta.id) |id| {
                    if (gop.value_ptr.id) |old| self.allocator.free(old);
                    gop.value_ptr.id = try self.allocator.dupe(u8, id);
                }
                if (delta.function_name) |name| {
                    if (gop.value_ptr.name) |old| self.allocator.free(old);
                    gop.value_ptr.name = try self.allocator.dupe(u8, name);
                }
                if (delta.function_arguments) |args| {
                    try gop.value_ptr.arguments.appendSlice(self.allocator, args);
                }
            }
        }

        // Store finish reason
        if (chunk.finish_reason) |fr| {
            self.finish_reason = fr;
        }

        // Store usage
        if (chunk.usage) |usage| {
            self.usage = usage;
        }
    }

    /// Finalize the aggregated response - must be called after all chunks processed
    pub fn finalize(self: *StreamingAggregator) !CallResponse {
        // Finalize tool calls from buffers
        var sorted_indices: std.ArrayList(usize) = .empty;
        defer sorted_indices.deinit(self.allocator);

        var iter = self.tool_call_buffers.iterator();
        while (iter.next()) |entry| {
            try sorted_indices.append(self.allocator, entry.key_ptr.*);
        }
        std.sort.pdq(usize, sorted_indices.items, {}, std.sort.asc(usize));

        for (sorted_indices.items) |idx| {
            const buffer = self.tool_call_buffers.get(idx).?;
            if (buffer.id) |id| {
                const tool_call = ToolCall{
                    .id = try self.allocator.dupe(u8, id),
                    .function = .{
                        .name = if (buffer.name) |n| try self.allocator.dupe(u8, n) else try self.allocator.dupe(u8, ""),
                        .arguments = try self.allocator.dupe(u8, buffer.arguments.items),
                    },
                };
                try self.tool_calls.append(self.allocator, tool_call);
            }
        }

        var content_copy: ?[]const u8 = null;
        if (self.content.items.len > 0) {
            content_copy = try self.allocator.dupe(u8, self.content.items);
        }

        var reasoning_copy: ?[]const u8 = null;
        if (self.reasoning_content.items.len > 0) {
            reasoning_copy = try self.allocator.dupe(u8, self.reasoning_content.items);
        }

        var tool_calls_copy: ?[]ToolCall = null;
        if (self.tool_calls.items.len > 0) {
            // Deep copy: allocate new strings for each tool call
            tool_calls_copy = try self.allocator.alloc(ToolCall, self.tool_calls.items.len);
            for (self.tool_calls.items, 0..) |tc, i| {
                tool_calls_copy.?[i] = .{
                    .id = try self.allocator.dupe(u8, tc.id),
                    .function = .{
                        .name = try self.allocator.dupe(u8, tc.function.name),
                        .arguments = try self.allocator.dupe(u8, tc.function.arguments),
                    },
                };
            }
        }

        return .{
            .allocator = self.allocator,
            .content = content_copy,
            .tool_calls = tool_calls_copy,
            .finish_reason = self.finish_reason,
            .reasoning_content = reasoning_copy,
            .usage = self.usage,
        };
    }
};

pub const AgentCall = struct {
    tools: []const AgentTool,
    messages: []const AgentMessage,
    temperature: ?f32 = null,
    max_tokens: ?usize = null,
};

pub const HttpOptions = struct {
    read_timeout_ms: u32 = 300_000, // 5 minutes for LLM APIs
    /// Buffer size for reading HTTP response body (default 64KB for large API responses)
    response_buffer_size: usize = 64 * 1024,
    /// Buffer size for HTTP headers (default 16KB for large cookie headers)
    header_buffer_size: usize = 16 * 1024,
};

pub const CallResponse = struct {
    allocator: std.mem.Allocator,
    content: ?[]const u8,
    tool_calls: ?[]ToolCall,
    finish_reason: ?FinishReason,
    reasoning_content: ?[]const u8 = null,
    usage: Usage = .{},

    pub fn deinit(self: *const CallResponse) void {
        if (self.content) |c| self.allocator.free(c);
        if (self.reasoning_content) |rc| self.allocator.free(rc);
        if (self.tool_calls) |tc| {
            for (tc) |*tool_call| {
                self.allocator.free(tool_call.id);
                self.allocator.free(tool_call.function.name);
                self.allocator.free(tool_call.function.arguments);
            }
            self.allocator.free(tc);
        }
    }
};

pub const Agent = struct {
    name: []const u8 = "",
    apiKey: []const u8 = "",
    baseUrl: []const u8 = "",
    model: []const u8 = "",
    temperature: f32 = 0.4,
    maxTokens: usize = 4096,
    httpClient: std.http.Client,
    thinkingEnabled: bool = true,
    allocator: std.mem.Allocator,
    logger: *log.Logger,
    httpOptions: HttpOptions = .{},

    pub fn init(allocator: std.mem.Allocator, logger_ptr: *log.Logger) !Agent {
        return Agent{ .allocator = allocator, .httpClient = std.http.Client{ .allocator = allocator }, .logger = logger_ptr };
    }

    /// Initialize agent with custom HTTP options
    pub fn initWithOptions(allocator: std.mem.Allocator, options: HttpOptions, logger_ptr: *log.Logger) !Agent {
        return Agent{
            .allocator = allocator,
            .httpClient = std.http.Client{
                .allocator = allocator,
                .read_buffer_size = options.header_buffer_size,
            },
            .httpOptions = options,
            .logger = logger_ptr,
        };
    }

    pub fn logMsg(self: Agent, level: log.LogLevel, message: []const u8) void {
        self.logger.log(level, message) catch {};
    }

    /// Log with formatted message and context
    pub fn logFmt(self: Agent, comptime level: log.LogLevel, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch { std.debug.print("fmt alloc failed\n", .{}); return; };
        defer self.allocator.free(msg);
        self.logMsg(level, msg);
    }

    /// Log error with context (operation, error name, and optional detail)
    pub fn logError(self: Agent, operation: []const u8, err: anyerror, detail: ?[]const u8) void {
        if (detail) |d| {
            self.logFmt(.err, "{s} failed: {s} - {s}", .{ operation, @errorName(err), d });
        } else {
            self.logFmt(.err, "{s} failed: {s}", .{ operation, @errorName(err) });
        }
    }

    /// Log error with JSON body for debugging API issues
    pub fn logApiError(self: Agent, operation: []const u8, err: anyerror, body: []const u8) void {
        // Truncate body if too long for logging
        const max_body_len = 500;
        const truncated = body.len > max_body_len;
        const body_to_log = if (truncated) body[0..max_body_len] else body;
        if (truncated) {
            self.logFmt(.err, "{s} failed: {s}\nResponse (truncated): {s}...", .{ operation, @errorName(err), body_to_log });
        } else {
            self.logFmt(.err, "{s} failed: {s}\nResponse: {s}", .{ operation, @errorName(err), body_to_log });
        }
    }

    /// Log HTTP request details for debugging
    pub fn logRequest(self: Agent, method: []const u8, url: []const u8, body_len: usize) void {
        self.logFmt(.debug, "HTTP {s} {s} (body: {} bytes)", .{ method, url, body_len });
    }

    pub fn buildJsonRequest(self: Agent, params: AgentCall, stream: bool) ![]u8 {
        const allocator = self.allocator;

        // Use arena allocator for temporary conversions
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        // Convert messages
        const json_messages = try arena_alloc.alloc(JsonMessage, params.messages.len);
        for (params.messages, 0..) |msg, i| {
            var json_tool_calls: ?[]JsonToolCall = null;
            if (msg.tool_calls) |tcs| {
                const tc_slice = try arena_alloc.alloc(JsonToolCall, tcs.len);
                for (tcs, 0..) |tc, j| {
                    tc_slice[j] = .{
                        .id = tc.id,
                        .type = tc.type,
                        .function = .{
                            .name = tc.function.name,
                            .arguments = tc.function.arguments, // Already a JSON string
                        },
                    };
                }
                json_tool_calls = tc_slice;
            }
            json_messages[i] = .{
                .role = msg.role.toStr(),
                .content = msg.content,
                .tool_calls = json_tool_calls,
                .tool_call_id = msg.tool_call_id,
                .reasoning_content = msg.reasoning_content,
            };
        }

        // Convert tools
        var json_tools: ?[]JsonTool = null;
        if (params.tools.len > 0) {
            const tool_slice = try arena_alloc.alloc(JsonTool, params.tools.len);
            for (params.tools, 0..) |tool, i| {
                const props = tool.function.parameters.properties;
                const json_props = try arena_alloc.alloc(ToolProperty, props.len);
                for (props, 0..) |prop, j| {
                    json_props[j] = prop;
                }
                tool_slice[i] = .{
                    .type = tool.type,
                    .function = .{
                        .name = tool.function.name,
                        .description = tool.function.description,
                        .parameters = .{
                            .properties = json_props,
                            .required = tool.function.parameters.required,
                        },
                    },
                };
            }
            json_tools = tool_slice;
        }

        // Build request
        const json_request = JsonRequest{
            .model = self.model,
            .enable_thinking = self.thinkingEnabled,
            .thinking = if (!self.thinkingEnabled) .{} else null,
            .messages = json_messages,
            .temperature = params.temperature orelse self.temperature,
            .max_tokens = params.max_tokens orelse self.maxTokens,
            .stream = stream,
            .tools = json_tools,
            .tool_choice = if (json_tools != null) "auto" else null,
        };

        // Serialize to JSON
        var aw: std.io.Writer.Allocating = .init(allocator);
        try aw.writer.print("{f}", .{std.json.fmt(json_request, .{})});
        return try aw.toOwnedSlice();
    }

    pub const CallError = error{
        BuildRequestFailed,
        InvalidUri,
        AuthFailed,
        HttpRequestFailed,
        SendBodyFailed,
        ReceiveFailed,
        ParseJsonFailed,
        ApiError,
        NoChoices,
        AllocFailed,
        WriteFailed,
        OutOfMemory,
    };

    pub fn call(self: *Agent, params: AgentCall) CallError!CallResponse {
        self.logFmt(.info, "[CALL START] Building JSON request (model: {s}, messages: {})...", .{ self.model, params.messages.len });

        const json_start = timestampMs();
        const json_body: []u8 = self.buildJsonRequest(params, false) catch |err| {
            self.logError("buildJsonRequest", err, null);
            return error.BuildRequestFailed;
        };
        self.logFmt(.debug, "[TIMING] JSON build took {}ms ({} bytes)", .{ elapsedMs(json_start), json_body.len });
        defer self.allocator.free(json_body);

        const connect_start = timestampMs();
        const uri_str = std.mem.concat(self.allocator, u8, &.{ self.baseUrl, "/chat/completions" }) catch |err| {
            self.logError("concat URI", err, self.baseUrl);
            return error.OutOfMemory;
        };
        defer self.allocator.free(uri_str);

        const uri = std.Uri.parse(uri_str) catch |err| {
            self.logFmt(.err, "Failed to parse URI '{s}': {s}", .{ uri_str, @errorName(err) });
            return error.InvalidUri;
        };

        self.logFmt(.debug, "[REQUEST] POST {s} (body: {} bytes)", .{ uri_str, json_body.len });

        const auth_value = std.mem.concat(self.allocator, u8, &.{ "Bearer ", self.apiKey }) catch |err| {
            self.logError("concat auth", err, null);
            return error.OutOfMemory;
        };
        defer self.allocator.free(auth_value);

        var req = self.httpClient.request(.POST, uri, .{
            .version = .@"HTTP/1.1",
            .headers = .{
                .authorization = .{ .override = auth_value },
                .content_type = .{ .override = "application/json" },
                .accept_encoding = .{ .override = "identity" },
            },
        }) catch |err| {
            self.logFmt(.err, "HTTP request failed to '{s}': {s}", .{ uri_str, @errorName(err) });
            return error.HttpRequestFailed;
        };
        defer req.deinit();

        if (req.connection) |conn| {
            const stream = conn.stream_reader.getStream();
            const handle = stream.handle;
            const timeout = std.posix.timeval{
                .sec = @intCast(self.httpOptions.read_timeout_ms / 1000),
                .usec = @intCast((self.httpOptions.read_timeout_ms % 1000) * 1000),
            };
            std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch |err| {
                self.logFmt(.warn, "Failed to set socket RCVTIMEO: {s}", .{@errorName(err)});
            };
            std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch |err| {
                self.logFmt(.warn, "Failed to set socket SNDTIMEO: {s}", .{@errorName(err)});
            };
            std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.KEEPALIVE, std.mem.asBytes(&@as(u32, 1))) catch |err| {
                self.logFmt(.warn, "Failed to set socket KEEPALIVE: {s}", .{@errorName(err)});
            };
        }
        self.logFmt(.debug, "[TIMING] Connection setup took {}ms", .{elapsedMs(connect_start)});

        const send_start = timestampMs();
        req.sendBodyComplete(json_body) catch |err| {
            self.logError("sendBodyComplete", err, null);
            return error.SendBodyFailed;
        };
        self.logFmt(.debug, "[TIMING] Request sent in {}ms", .{elapsedMs(send_start)});

        const receive_start = timestampMs();
        var redirect_buffer: [8192]u8 = undefined;
        // Use heap-allocated buffer for response body to handle large API responses
        const transfer_buffer = self.allocator.alloc(u8, self.httpOptions.response_buffer_size) catch |err| {
            self.logError("alloc transfer_buffer", err, null);
            return error.OutOfMemory;
        };
        defer self.allocator.free(transfer_buffer);

        self.logFmt(.debug, "[WAITING] Waiting for response (timeout: {}ms)...", .{self.httpOptions.read_timeout_ms});

        var response = req.receiveHead(&redirect_buffer) catch |err| {
            self.logFmt(.err, "[TIMEOUT] No response after {}ms: {s}", .{ elapsedMs(receive_start), @errorName(err) });
            if (req.connection) |conn| {
                if (conn.getReadError()) |read_err| {
                    self.logFmt(.err, "HTTP receive failed: {s} (underlying: {s})", .{ @errorName(err), @errorName(read_err) });
                } else {
                    self.logError("receiveHead", err, null);
                }
            } else {
                self.logFmt(.err, "HTTP receive failed (no connection): {s}", .{@errorName(err)});
            }
            return error.ReceiveFailed;
        };

        const body = response.reader(transfer_buffer[0..]).allocRemaining(self.allocator, .unlimited) catch |err| {
            self.logFmt(.err, "[ERROR] Failed to read body after {}ms: {s}", .{ elapsedMs(receive_start), @errorName(err) });
            return error.ReceiveFailed;
        };
        defer self.allocator.free(body);

        self.logFmt(.info, "[RESPONSE] Received {} bytes in {}ms (total wait: {}ms)", .{ body.len, elapsedMs(receive_start), elapsedMs(send_start) });

        const parsed = json.parseFromSlice(json.Value, self.allocator, body, .{}) catch |err| {
            self.logApiError("JSON parse", err, body);
            return error.ParseJsonFailed;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root.object.get("error")) |api_error| {
            const error_detail = switch (api_error) {
                .string => |s| s,
                .object => |obj| blk: {
                    if (obj.get("message")) |msg| {
                        break :blk switch (msg) {
                            .string => |s| s,
                            else => "unknown error object",
                        };
                    }
                    break :blk "error object without message";
                },
                else => "unknown error format",
            };
            self.logFmt(.err, "API returned error: {s}", .{error_detail});
            return error.ApiError;
        }

        const choices = root.object.get("choices") orelse {
            self.logApiError("No choices in response", error.NoChoices, body);
            return error.NoChoices;
        };

        if (choices.array.items.len == 0) {
            self.logApiError("Empty choices array", error.NoChoices, body);
            return error.NoChoices;
        }

        const first_choice = choices.array.items[0];
        const message = first_choice.object.get("message") orelse {
            self.logApiError("No message in choice", error.NoChoices, body);
            return error.NoChoices;
        };

        const content = message.object.get("content");
        const tool_calls_val = message.object.get("tool_calls");
        const finish_reason_val = first_choice.object.get("finish_reason");
        const reasoning_content_val = message.object.get("reasoning_content");

        if (content) |c| {
            self.logFmt(.info, "Response content received ({} chars)", .{c.string.len});
        } else if (tool_calls_val != null) {
            self.logMsg(.info, "Response contains tool_calls");
        } else {
            self.logMsg(.warn, "Response has no content or tool_calls");
        }

        if (reasoning_content_val) |rc| {
            self.logFmt(.debug, "Reasoning content ({} chars): {s}", .{ rc.string.len, rc.string });
        }

        var tool_calls: ?[]ToolCall = null;
        if (tool_calls_val) |tc| {
            self.logFmt(.debug, "Parsing {} tool calls", .{tc.array.items.len});
            var calls = self.allocator.alloc(ToolCall, tc.array.items.len) catch |err| {
                self.logError("alloc tool_calls", err, null);
                return error.OutOfMemory;
            };
            for (tc.array.items, 0..) |tc_item, i| {
                const tc_obj = tc_item.object;
                const id = tc_obj.get("id") orelse {
                    self.logFmt(.err, "Tool call {} missing 'id' field", .{i});
                    return error.ParseJsonFailed;
                };
                const func_obj = tc_obj.get("function") orelse {
                    self.logFmt(.err, "Tool call {} missing 'function' field", .{i});
                    return error.ParseJsonFailed;
                };
                const name = func_obj.object.get("name") orelse {
                    self.logFmt(.err, "Tool call {} missing function 'name'", .{i});
                    return error.ParseJsonFailed;
                };
                const arguments = func_obj.object.get("arguments") orelse {
                    self.logFmt(.err, "Tool call {} missing function 'arguments'", .{i});
                    return error.ParseJsonFailed;
                };
                calls[i] = .{ .id = id.string, .function = .{ .name = name.string, .arguments = arguments.string } };
                self.logFmt(.debug, "Tool call {}: {s}", .{ i, name.string });
            }
            tool_calls = calls;
        }

        const finish_reason = FinishReason.fromStr(if (finish_reason_val) |fr| fr.string else null);
        self.logFmt(.debug, "Finish reason: {s}", .{if (finish_reason) |fr| fr.toStr() else "null"});

        var content_copy: ?[]const u8 = null;
        if (content) |c| {
            content_copy = self.allocator.dupe(u8, c.string) catch |err| {
                self.logError("dupe content", err, null);
                return error.OutOfMemory;
            };
        }

        var reasoning_content_copy: ?[]const u8 = null;
        if (reasoning_content_val) |rc| {
            reasoning_content_copy = self.allocator.dupe(u8, rc.string) catch |err| {
                self.logError("dupe reasoning_content", err, null);
                return error.OutOfMemory;
            };
        }

        // Parse usage information
        var usage: Usage = .{};
        if (root.object.get("usage")) |usage_val| {
            if (usage_val == .object) {
                if (usage_val.object.get("prompt_tokens")) |pt| {
                    if (pt == .integer) usage.prompt_tokens = @intCast(pt.integer);
                }
                if (usage_val.object.get("completion_tokens")) |ct| {
                    if (ct == .integer) usage.completion_tokens = @intCast(ct.integer);
                }
                if (usage_val.object.get("total_tokens")) |tt| {
                    if (tt == .integer) usage.total_tokens = @intCast(tt.integer);
                }
                self.logFmt(.info, "Token usage - prompt: {}, completion: {}, total: {}", .{ usage.prompt_tokens, usage.completion_tokens, usage.total_tokens });
            }
        }

        return .{
            .allocator = self.allocator,
            .content = content_copy,
            .tool_calls = tool_calls,
            .finish_reason = finish_reason,
            .reasoning_content = reasoning_content_copy,
            .usage = usage,
        };
    }

    /// Parse a single SSE line (format: "data: {...}" or "data: [DONE]")
    pub fn parseSseLine(_: Agent, line: []const u8) ?[]const u8 {
        // Skip empty lines
        if (line.len == 0) return null;

        // Check for "data: " prefix
        if (!std.mem.startsWith(u8, line, "data: ")) return null;

        const data = line[6..]; // Skip "data: "

        // Check for [DONE] marker
        if (std.mem.eql(u8, data, "[DONE]")) {
            return null;
        }

        return data;
    }

    /// Parse a streaming chunk JSON into StreamChunk
    pub fn parseStreamChunk(self: Agent, data: []const u8, arena: std.mem.Allocator) ?StreamChunk {
        const parsed = json.parseFromSlice(json.Value, arena, data, .{}) catch |err| {
            const max_data_len = 200;
            const truncated = data.len > max_data_len;
            const data_to_log = if (truncated) data[0..max_data_len] else data;
            if (truncated) {
                self.logFmt(.err, "JSON parse failed: {s}\nData (truncated): {s}...", .{ @errorName(err), data_to_log });
            } else {
                self.logFmt(.err, "JSON parse failed: {s}\nData: {s}", .{ @errorName(err), data_to_log });
            }
            return null;
        };
        defer parsed.deinit();
        const root = parsed.value;

        var chunk: StreamChunk = .{};

        if (root.object.get("choices")) |choices| {
            if (choices.array.items.len > 0) {
                const first_choice = choices.array.items[0];

                if (first_choice.object.get("finish_reason")) |fr| {
                    if (fr == .string) {
                        chunk.finish_reason = FinishReason.fromStr(fr.string);
                    }
                }

                // Handle both "delta" (streaming) and "message" (non-streaming)
                const msg_field = first_choice.object.get("delta") orelse first_choice.object.get("message");
                if (msg_field) |delta| {
                    if (delta.object.get("content")) |content| {
                        if (content == .string and content.string.len > 0) {
                            chunk.content = content.string;
                        }
                    }

                    if (delta.object.get("reasoning_content")) |rc| {
                        if (rc == .string and rc.string.len > 0) {
                            chunk.reasoning_content = rc.string;
                        }
                    }

                    if (delta.object.get("tool_calls")) |tc_delta| {
                        if (tc_delta == .array and tc_delta.array.items.len > 0) {
                            var deltas = arena.alloc(ToolCallDelta, tc_delta.array.items.len) catch |err| {
                                self.logMsg(.debug, "Error allocating ToolCallDelta");
                                self.logMsg(.err, @errorName(err));
                                return null;
                            };

                            for (tc_delta.array.items, 0..) |tc_item, i| {
                                var delta_item: ToolCallDelta = .{ .index = i };

                                if (tc_item == .object) {
                                    if (tc_item.object.get("index")) |idx| {
                                        if (idx == .integer) {
                                            delta_item.index = @intCast(idx.integer);
                                        }
                                    }

                                    if (tc_item.object.get("id")) |id| {
                                        if (id == .string and id.string.len > 0) {
                                            delta_item.id = id.string;
                                        }
                                    }

                                    if (tc_item.object.get("function")) |func| {
                                        if (func == .object) {
                                            if (func.object.get("name")) |name| {
                                                if (name == .string and name.string.len > 0) {
                                                    delta_item.function_name = name.string;
                                                }
                                            }
                                            if (func.object.get("arguments")) |args| {
                                                if (args == .string and args.string.len > 0) {
                                                    delta_item.function_arguments = args.string;
                                                }
                                            }
                                        }
                                    }
                                }
                                deltas[i] = delta_item;
                            }
                            chunk.tool_calls_delta = deltas;
                        }
                    }
                }
            }
        }

        if (root.object.get("usage")) |usage_val| {
            if (usage_val == .object) {
                var usage: Usage = .{};
                if (usage_val.object.get("prompt_tokens")) |pt| {
                    if (pt == .integer) usage.prompt_tokens = @intCast(pt.integer);
                }
                if (usage_val.object.get("completion_tokens")) |ct| {
                    if (ct == .integer) usage.completion_tokens = @intCast(ct.integer);
                }
                if (usage_val.object.get("total_tokens")) |tt| {
                    if (tt == .integer) usage.total_tokens = @intCast(tt.integer);
                }
                chunk.usage = usage;
            }
        }

        return chunk;
    }

    /// Streaming call with callback for each chunk
    pub fn callStreaming(
        self: *Agent,
        params: AgentCall,
        ctx: ?*anyopaque,
        callback: StreamCallback,
        is_cancelled: ?*const fn (?*anyopaque) bool,
    ) CallError!CallResponse {
        self.logMsg(.info, "Building streaming JSON request...");

        const json_body: []u8 = self.buildJsonRequest(params, true) catch |err| {
            self.logError("buildJsonRequest", err, null);
            return error.BuildRequestFailed;
        };

        self.logFmt(.info, "Streaming JSON request built ({} bytes), sending...", .{json_body.len});
        defer self.allocator.free(json_body);

        self.logFmt(.debug, "Streaming request body: {s}", .{json_body});

        const uri_str = std.mem.concat(self.allocator, u8, &.{ self.baseUrl, "/chat/completions" }) catch |err| {
            self.logError("concat URI", err, null);
            return error.OutOfMemory;
        };
        defer self.allocator.free(uri_str);

        const uri = std.Uri.parse(uri_str) catch |err| {
            self.logFmt(.err, "Failed to parse URI '{s}': {s}", .{ uri_str, @errorName(err) });
            return error.InvalidUri;
        };

        self.logRequest("POST", uri_str, json_body.len);

        const auth_value = std.mem.concat(self.allocator, u8, &.{ "Bearer ", self.apiKey }) catch |err| {
            self.logError("concat auth", err, null);
            return error.OutOfMemory;
        };
        defer self.allocator.free(auth_value);

        var req = self.httpClient.request(.POST, uri, .{
            .version = .@"HTTP/1.1",
            .headers = .{
                .authorization = .{ .override = auth_value },
                .content_type = .{ .override = "application/json" },
                .accept_encoding = .{ .override = "identity" },
            },
        }) catch |err| {
            self.logFmt(.err, "HTTP streaming request failed to '{s}': {s}", .{ uri_str, @errorName(err) });
            return error.HttpRequestFailed;
        };
        defer req.deinit();

        if (req.connection) |conn| {
            const stream = conn.stream_reader.getStream();
            const handle = stream.handle;
            const timeout = std.posix.timeval{
                .sec = @intCast(self.httpOptions.read_timeout_ms / 1000),
                .usec = @intCast((self.httpOptions.read_timeout_ms % 1000) * 1000),
            };
            std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch |err| {
                self.logFmt(.warn, "Failed to set socket RCVTIMEO: {s}", .{@errorName(err)});
            };
            std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch |err| {
                self.logFmt(.warn, "Failed to set socket SNDTIMEO: {s}", .{@errorName(err)});
            };
            std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.KEEPALIVE, std.mem.asBytes(&@as(u32, 1))) catch |err| {
                self.logFmt(.warn, "Failed to set socket KEEPALIVE: {s}", .{@errorName(err)});
            };
        }

        req.sendBodyComplete(json_body) catch |err| {
            self.logError("sendBodyComplete", err, null);
            return error.SendBodyFailed;
        };

        const stream_start = timestampMs();
        var redirect_buffer: [8192]u8 = undefined;
        var response = req.receiveHead(&redirect_buffer) catch |err| {
            self.logFmt(.err, "[TIMEOUT] No response after {}ms: {s}", .{ elapsedMs(stream_start), @errorName(err) });
            return error.ReceiveFailed;
        };

        self.logFmt(.info, "[STREAM START] Response headers received in {}ms", .{elapsedMs(stream_start)});

        //
        // Initialize aggregator
        var aggregator = StreamingAggregator.init(self.allocator);
        defer aggregator.deinit();

        // Read response body incrementally
        const transfer_buffer = self.allocator.alloc(u8, self.httpOptions.response_buffer_size) catch |err| {
            self.logError("alloc transfer_buffer", err, null);
            return error.OutOfMemory;
        };
        defer self.allocator.free(transfer_buffer);

        var reader = response.reader(transfer_buffer[0..]);

        // Buffer for accumulating SSE lines
        var line_buffer: std.ArrayList(u8) = .empty;
        defer line_buffer.deinit(self.allocator);

        var chunk_count: usize = 0;
        var parse_failure_count: usize = 0;
        var stream_ended_cleanly = false;
        var total_bytes_read: usize = 0;
        var last_chunk_time = timestampMs();
        var read_buf: [4096]u8 = undefined;

        self.logFmt(.debug, "[STREAM] Starting to read chunks (buffer: {} bytes)...", .{self.httpOptions.response_buffer_size});

        while (true) {

            // Check if cancelled
            if (is_cancelled) |check| {
                if (check(ctx)) {
                    self.logMsg(.info, "[STREAM] Cancelled by user");
                    stream_ended_cleanly = false;
                    break;
                }
            }
            const bytes_read = reader.readSliceShort(&read_buf) catch |err| {
                // EndOfStream is expected when streaming completes
                if (err == error.EndOfStream) {
                    self.logFmt(.debug, "[STREAM END] Stream ended naturally after {} chunks, {} bytes", .{ chunk_count, total_bytes_read });
                    stream_ended_cleanly = true;
                    break;
                }
                // Log the specific error for debugging
                const time_since_last = elapsedMs(last_chunk_time);
                self.logFmt(.err, "[STREAM ERROR] Read failed after {} chunks: {s} (last chunk was {}ms ago)", .{ chunk_count, @errorName(err), time_since_last });

                // Handle specific error types
                if (err == error.WouldBlock) {
                    self.logFmt(.err, "[STREAM ERROR] Socket timeout - no data received within {}ms", .{self.httpOptions.read_timeout_ms});
                } else if (err == error.ConnectionResetByPeer or err == error.BrokenPipe) {
                    self.logFmt(.err, "[STREAM ERROR] Connection closed by server", .{});
                }

                break;
            };

            if (bytes_read == 0) {
                self.logFmt(.info, "[STREAM END] Read returned 0 bytes after {} chunks", .{chunk_count});
                stream_ended_cleanly = true;
                break;
            }

            total_bytes_read += bytes_read;
            last_chunk_time = timestampMs();

            // Process each byte looking for SSE line boundaries
            for (read_buf[0..bytes_read]) |byte| {
                if (byte == '\n') {
                    // Process complete line
                    if (line_buffer.items.len > 0) {
                        const line = line_buffer.items;

                        // Skip empty lines and non-data lines
                        if (self.parseSseLine(line)) |data| {
                            // Use per-chunk arena to prevent memory leaks
                            var chunk_arena = std.heap.ArenaAllocator.init(self.allocator);
                            defer chunk_arena.deinit();

                            if (self.parseStreamChunk(data, chunk_arena.allocator())) |chunk| {
                                chunk_count += 1;

                                // Log progress periodically
                                if (chunk_count % 50 == 0) {
                                    self.logFmt(.debug, "[STREAM PROGRESS] {} chunks, {} bytes, {}ms elapsed", .{ chunk_count, total_bytes_read, elapsedMs(stream_start) });
                                }

                                // Invoke callback
                                callback(ctx, chunk);

                                // Aggregate chunk - this copies data to aggregator's allocator
                                aggregator.processChunk(chunk) catch |err| {
                                    self.logError("processChunk", err, null);
                                };
                            } else {
                                parse_failure_count += 1;
                                self.logFmt(.warn, "[STREAM] Failed to parse chunk {} (data length: {})", .{ parse_failure_count, data.len });
                            }
                        }

                        line_buffer.clearRetainingCapacity();
                    }
                } else if (byte != '\r') {
                    line_buffer.append(self.allocator, byte) catch |err| {
                        self.logError("append line_buffer", err, null);
                    };
                }
            }
        }

        // Process any remaining line
        if (line_buffer.items.len > 0) {
            self.logFmt(.debug, "[STREAM] Processing remaining {} bytes in buffer", .{line_buffer.items.len});
            if (self.parseSseLine(line_buffer.items)) |data| {
                // Use per-chunk arena to prevent memory leaks
                var chunk_arena = std.heap.ArenaAllocator.init(self.allocator);
                defer chunk_arena.deinit();

                if (self.parseStreamChunk(data, chunk_arena.allocator())) |chunk| {
                    chunk_count += 1;
                    callback(ctx, chunk);
                    aggregator.processChunk(chunk) catch |err| {
                        self.logError("processChunk (final)", err, null);
                    };
                }
            }
        }

        // Send done chunk
        callback(ctx, .{ .done = true });

        const stream_duration = elapsedMs(stream_start);
        self.logFmt(.info, "[STREAM COMPLETE] {} chunks, {} bytes, {}ms total, {} parse failures, clean_end={}", .{
            chunk_count,
            total_bytes_read,
            stream_duration,
            parse_failure_count,
            stream_ended_cleanly,
        });

        // Warn if stream didn't end cleanly
        if (!stream_ended_cleanly) {
            self.logFmt(.warn, "[STREAM WARNING] Stream did not end cleanly - response may be incomplete!", .{});
        }

        // Finalize and return the aggregated response
        const result = aggregator.finalize() catch |err| {
            self.logError("finalize streaming response", err, null);
            return error.AllocFailed;
        };
        self.logFmt(.info, "[RESULT] Finalized streaming response", .{});

        if (result.tool_calls) |tc| {
            self.logFmt(.info, "[RESULT] {} tool calls", .{tc.len});
        } else if (result.content) |c| {
            self.logFmt(.info, "[RESULT] {} chars content", .{c.len});
        } else {
            self.logFmt(.warn, "[RESULT] No content or tool_calls in response!", .{});
        }

        if (result.usage.total_tokens > 0) {
            self.logFmt(.info, "[TOKENS] prompt={}, completion={}, total={}", .{
                result.usage.prompt_tokens,
                result.usage.completion_tokens,
                result.usage.total_tokens,
            });
        }

        return result;
    }

    pub fn deinit(self: *Agent) void {
        self.httpClient.deinit();
    }

    pub const INTENT_JUDGE_SYSTEM =
        \\You are a strict intent classifier for an AI agent loop.
        \\
        \\Your ONLY job: does the LAST [assistant] message describe an action it did NOT yet perform?
        \\
        \\IMPORTANT: Ignore ALL text inside <markdown>...</markdown> tags when applying
        \\heuristics. Only evaluate content outside of <markdown> blocks.
        \\
        \\Answer YES if the last [assistant] message contains ANY of:
        \\- Future tense about an action: "I will...", "I'll...", "Let me...", "Now I'll..."
        \\- Stated necessity: "I need to...", "I should...", "I must..."
        \\- Announced next step: "Next,...", "First,...", "The next step is..."
        \\- Partial completion bridge: "...now let me check", "...then I'll verify"
        \\- Conditional promise: "If X, I'll do Y"
        \\- A <handoff> block with <next_agent> tag AND <awaiting_confirmation>false</awaiting_confirmation>
        \\
        \\Answer NO if the last [assistant] message ONLY contains:
        \\- A question directed at the user
        \\- A summary of already-completed tool calls
        \\- A declaration that the task is done/complete
        \\- An explanation, concept, or instructions for the USER to follow
        \\- A list of what was accomplished
        \\- A <handoff> block with <awaiting_confirmation>true</awaiting_confirmation> — plan is waiting for user approval, not yet actionable
        \\
        \\STRICT RULES:
        \\- Use conversation history only to check if a stated intent was already executed
        \\- "I've done X, now let me do Y" → YES (Y is unresolved)
        \\- "I've done X and Y" → NO (both resolved)
        \\- A <handoff> block alone is NOT enough — check awaiting_confirmation
        \\- <awaiting_confirmation>true</awaiting_confirmation> → NO (waiting for user, not actionable)
        \\- <awaiting_confirmation>false</awaiting_confirmation> with <next_agent> → YES (approved, must execute)
        \\- Missing <awaiting_confirmation> tag → treat as NO (default to waiting)
        \\- When in doubt, answer YES
        \\
        \\Respond ONLY in XML. No other text.
        \\Unresolved: <result>YES</result><reason>one short phrase</reason>
        \\Resolved:   <result>NO</result>
    ;

    /// Simple streaming callback for hasUnresolvedIntent - just prints content chunks
    fn intentStreamCallback(ctx: ?*anyopaque, chunk: StreamChunk) void {
        _ = ctx; // No context needed for this simple callback
        if (chunk.done) return;
        if (chunk.content) |content| {
            std.debug.print("{s}", .{content});
        }
    }

    pub fn hasUnresolvedIntent(self: *Agent, messages: []const AgentMessage) !UnresolvedIntentResult {
        if (messages.len == 0) {
            return UnresolvedIntentResult{
                .has_unresolved = false,
                .reason = null,
            };
        }

        const start = if (messages.len > 10) messages.len - 10 else 0;
        const recent_messages = messages[start..];

        var conversation_history = std.ArrayListUnmanaged(u8){};
        defer conversation_history.deinit(self.allocator);

        for (recent_messages) |msg| {
            const role_str = msg.role.toStr();
            const content = msg.content orelse "";
            const reasoning = msg.reasoning_content orelse "";

            if (reasoning.len > 0) {
                try conversation_history.writer(self.allocator).print("[{s}]: {s} {s}\n", .{ role_str, content, reasoning });
            } else {
                try conversation_history.writer(self.allocator).print("[{s}]: {s}\n", .{ role_str, content });
            }
        }

        const user_content = try std.fmt.allocPrint(self.allocator,
            \\Conversation history:
            \\
            \\<conversation>
            \\{s}
            \\</conversation>
            \\
            \\Analyze the conversation above. Does the last [assistant] message describe an action that has NOT been executed yet?
            \\Respond in XML format: <result>YES</result><reason>...</reason> or <result>NO</result>
        , .{conversation_history.items});
        defer self.allocator.free(user_content);

        const call_messages = &.{
            AgentMessage{ .role = .system, .content = Agent.INTENT_JUDGE_SYSTEM },
            AgentMessage{ .role = .user, .content = user_content },
        };

        const call_response = try self.callStreaming(.{
            .tools = &.{},
            .messages = call_messages,
            .temperature = 0.0,
        }, null, intentStreamCallback);
        defer call_response.deinit();

        const answer = call_response.content orelse "";
        std.debug.print("intent answer: {s}\n", .{answer});

        const result_start = std.mem.indexOf(u8, answer, "<result>") orelse return UnresolvedIntentResult{
            .has_unresolved = false,
            .reason = null,
        };
        const result_end = std.mem.indexOf(u8, answer[result_start..], "</result>") orelse return UnresolvedIntentResult{
            .has_unresolved = false,
            .reason = null,
        };
        const result_value = std.mem.trim(u8, answer[result_start + 8 .. result_start + result_end], " \t\n\r");
        std.debug.print("intent result result_value: {s}\n", .{result_value});

        if (std.ascii.eqlIgnoreCase(result_value, "YES")) {
            if (std.mem.indexOf(u8, answer, "<reason>")) |reason_start| {
                if (std.mem.indexOf(u8, answer[reason_start..], "</reason>")) |reason_end_offset| {
                    const reason = std.mem.trim(u8, answer[reason_start + 8 .. reason_start + reason_end_offset], " \t\n\r");
                    if (reason.len > 0) {
                        return UnresolvedIntentResult{
                            .has_unresolved = true,
                            .reason = try self.allocator.dupe(u8, reason),
                        };
                    }
                }
            }
            return UnresolvedIntentResult{
                .has_unresolved = true,
                .reason = null,
            };
        }

        return UnresolvedIntentResult{
            .has_unresolved = false,
            .reason = null,
        };
    }
};


test {
    _ = @import("agent_test.zig");
    _ = @import("streaming_test.zig");
}
