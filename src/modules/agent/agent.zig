const std = @import("std");
const json = std.json;
const bashTool = @import("tools/bash.zig").bashTool;
const bashMod = @import("tools/bash.zig");
const schemas = @import("tools/schemas.zig");
const BashInput = schemas.BashInput;
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;
const log = @import("nalarcore").logger;

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
    tool,
    null,
    /// No finish reason provided
    /// Model returned assistant role (some providers use this)
    assistant,

    pub fn fromStr(s: ?[]const u8) ?FinishReason {
        if (s == null) return .null;
        const str = s.?;
        if (std.mem.eql(u8, str, "stop")) return .stop;
        if (std.mem.eql(u8, str, "length")) return .length;
        if (std.mem.eql(u8, str, "tool_calls")) return .tool_calls;
        if (std.mem.eql(u8, str, "content_filter")) return .content_filter;
        if (std.mem.eql(u8, str, "tool")) return .tool;
        if (std.mem.eql(u8, str, "assistant")) return .assistant;
        return null;
    }

    pub fn toStr(self: FinishReason) []const u8 {
        return switch (self) {
            .stop => "stop",
            .length => "length",
            .tool_calls => "tool_calls",
            .content_filter => "content_filter",
            .tool => "tool",
            .null => "null",
            .assistant => "assistant",
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

        // Store usage - accumulate from chunks (API sends usage in final chunk)
        // Only update if we have valid (non-zero) token counts to avoid overwriting
        // the final usage with intermediate zero values from earlier chunks
        if (chunk.usage) |usage| {
            if (usage.total_tokens > 0) {
                self.usage = usage;
            }
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
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch {
            std.debug.print("fmt alloc failed\n", .{});
            return;
        };
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
        Cancelled,
    };

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
                        // self.logFmt(.info, "[STREAM] finish_reason parsed: {s}", .{fr.string});
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
                            // First pass: collect tool names for the summary log
                            var tool_names_buf: [256]u8 = undefined;
                            var tool_names_len: usize = 0;
                            for (tc_delta.array.items) |tc_item| {
                                if (tc_item == .object) {
                                    if (tc_item.object.get("function")) |func| {
                                        if (func == .object) {
                                            if (func.object.get("name")) |name| {
                                                if (name == .string and name.string.len > 0) {
                                                    if (tool_names_len > 0 and tool_names_len < tool_names_buf.len - 2) {
                                                        tool_names_buf[tool_names_len] = ',';
                                                        tool_names_buf[tool_names_len + 1] = ' ';
                                                        tool_names_len += 2;
                                                    }
                                                    const remaining = tool_names_buf.len - tool_names_len;
                                                    const to_copy = if (name.string.len > remaining) remaining else name.string.len;
                                                    @memcpy(tool_names_buf[tool_names_len..tool_names_len + to_copy], name.string[0..to_copy]);
                                                    tool_names_len += to_copy;
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            // const tool_names_summary = if (tool_names_len > 0) tool_names_buf[0..tool_names_len] else "unknown";
                            // self.logFmt(.info, "[STREAM] AI requesting {} tool call(s): {s}", .{tc_delta.array.items.len, tool_names_summary});

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
                                // Log meaningful tool call details
                                // const fn_name = delta_item.function_name orelse "pending";
                                // const fn_id = delta_item.id orelse "pending";
                                // const args_preview = if (delta_item.function_arguments) |args|
                                //     if (args.len > 50) args[0..50] else args
                                // else
                                //     "none";
                                // self.logFmt(.debug, "[STREAM] Tool[{}] {s} (id={s}): args={s}{s}", .{
                                //     i,
                                //     fn_name,
                                //     fn_id,
                                //     args_preview,
                                //     if (delta_item.function_arguments) |a| if (a.len > 50) "..." else "" else ""
                                // });
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
    /// Streaming call with callback for each chunk - synchronous, no thread needed
    pub fn callStreaming(
        self: *Agent,
        params: AgentCall,
        ctx: ?*anyopaque,
        callback: StreamCallback,
    ) CallError!CallResponse {
        self.logFmt(.info, "[STREAM START] model={s} | messages={} | tools={} | streaming=true", .{
            self.model,
            params.messages.len,
            params.tools.len
        });

        // Build request
        const json_body = self.buildJsonRequest(params, true) catch |err| {
            self.logError("buildJsonRequest", err, null);
            return error.BuildRequestFailed;
        };
        defer self.allocator.free(json_body);
        self.logFmt(.debug, "[STREAM REQUEST] JSON body {s}", .{json_body});
        // const json_preview_len = if (json_body.len > 500) 500 else json_body.len;
        // const json_ellipsis = if (json_body.len > 500) "..." else "";
        // self.logFmt(.debug, "[STREAM REQUEST] JSON body ({} bytes): {s}{s}", .{ json_body.len, json_body[0..json_preview_len], json_ellipsis });

        const uri_str = std.mem.concat(self.allocator, u8, &.{ self.baseUrl, "/chat/completions" }) catch |err| {
            self.logError("concat URI", err, null);
            return error.OutOfMemory;
        };
        defer self.allocator.free(uri_str);

        const uri = std.Uri.parse(uri_str) catch |err| {
            self.logFmt(.err, "Failed to parse URI '{s}': {s}", .{ uri_str, @errorName(err) });
            return error.InvalidUri;
        };

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

        // Set socket timeouts for responsive cancellation
        if (req.connection) |conn| {
            const stream = conn.stream_reader.getStream();
            const handle = stream.handle;
            const timeout = std.posix.timeval{
                .sec = @intCast(self.httpOptions.read_timeout_ms / 1000),
                .usec = @intCast((self.httpOptions.read_timeout_ms % 1000) * 1000),
            };
            std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};
            std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch {};
            std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.KEEPALIVE, std.mem.asBytes(&@as(u32, 1))) catch {};
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

        const stream_duration = elapsedMs(stream_start);
        const stream_duration_fmt = formatDuration(stream_duration);
        self.logFmt(.info, "[STREAM] Connected in {}{s} (HTTP {d})", .{
            stream_duration_fmt.value,
            stream_duration_fmt.unit,
            @intFromEnum(response.head.status)
        });

        // Log transfer details for debugging
        const encoding_str = if (response.head.transfer_encoding == .chunked) "chunked" else "fixed";
        var content_len_buf: [32]u8 = undefined;
        const content_len_str = if (response.head.content_length) |cl|
            std.fmt.bufPrint(&content_len_buf, "{}", .{cl}) catch "?"
        else
            "unknown";
        self.logFmt(.debug, "[STREAM] Transfer: encoding={s}, content_length={s}, keep_alive={}", .{
            encoding_str,
            content_len_str,
            response.head.keep_alive,
        });

        // Handle non-success HTTP status codes
        if (response.head.status.class() == .client_error or response.head.status.class() == .server_error) {
            const status_code = @intFromEnum(response.head.status);
            self.logFmt(.err, "[STREAM] HTTP error status: {d}", .{status_code});

            // Read the error body from the server
            const transfer_buf = self.allocator.alloc(u8, 4096) catch null;
            if (transfer_buf) |buf| {
                defer self.allocator.free(buf);
                var err_reader = response.request.reader.bodyReader(buf, response.head.transfer_encoding, response.head.content_length);

                // Read the error response body
                const error_body = err_reader.allocRemaining(self.allocator, .unlimited) catch null;
                if (error_body) |body| {
                    defer self.allocator.free(body);
                    self.logFmt(.err, "[STREAM] Server error response: {s}", .{body});
                }
            }

            return error.ApiError;
        }

        // Check if response has a body
        if (!response.request.method.responseHasBody()) {
            self.logMsg(.info, "[STREAM] Response has no body (status code)");
            return CallResponse{
                .allocator = self.allocator,
                .content = "",
                .tool_calls = null,
                .finish_reason = null,
            };
        }

        if (response.head.content_length == null and response.head.transfer_encoding != .chunked) {
            self.logMsg(.info, "[STREAM] Response has no body (no content-length, not chunked)");
            return CallResponse{
                .allocator = self.allocator,
                .content = "",
                .tool_calls = null,
                .finish_reason = null,
            };
        }

        // Handle zero content-length to avoid union field access panic
        if (response.head.content_length != null and response.head.content_length.? == 0) {
            self.logMsg(.info, "[STREAM] Response has empty body (content-length=0)");
            return CallResponse{
                .allocator = self.allocator,
                .content = "",
                .tool_calls = null,
                .finish_reason = null,
            };
        }

        var aggregator = StreamingAggregator.init(self.allocator);
        defer aggregator.deinit();

        const transfer_buffer = self.allocator.alloc(u8, self.httpOptions.response_buffer_size) catch |err| {
            self.logError("alloc transfer_buffer", err, null);
            return error.OutOfMemory;
        };
        defer self.allocator.free(transfer_buffer);

        var reader = response.request.reader.bodyReader(transfer_buffer[0..], response.head.transfer_encoding, response.head.content_length);

        // Debug: log reader state and response details
        self.logFmt(.info, "[STREAM] bodyReader called: transfer_encoding={s}, content_length={?}, reader_state={s}", .{
            if (response.head.transfer_encoding == .chunked) "chunked" else "none",
            response.head.content_length,
            switch (response.request.reader.state) {
                .ready => "ready",
                .received_head => "received_head",
                .body_none => "body_none",
                .body_remaining_content_length => |n| blk: {
                    var buf: [32]u8 = undefined;
                    break :blk std.fmt.bufPrint(&buf, "body_remaining_content_length({d})", .{n}) catch "body_remaining_content_length";
                },
                .body_remaining_chunk_len => "body_remaining_chunk_len",
                .closing => "closing",
            },
        });

        // Safety check: verify the reader state is correct before proceeding
        // This is a workaround for a potential Zig std lib issue where the state
        // might not be properly set by bodyReader
        const state_is_valid = switch (response.request.reader.state) {
            .body_remaining_content_length => |_| response.head.transfer_encoding == .none and response.head.content_length != null,
            .body_remaining_chunk_len => response.head.transfer_encoding == .chunked,
            .body_none => response.head.transfer_encoding == .none and response.head.content_length == null,
            else => false,
        };

        if (!state_is_valid) {
            self.logFmt(.err, "[STREAM] Reader state mismatch! State={s} but transfer_encoding={s}, content_length={?}. Treating as empty response.", .{
                switch (response.request.reader.state) {
                    .ready => "ready",
                    .received_head => "received_head",
                    .body_none => "body_none",
                    .body_remaining_content_length => "body_remaining_content_length",
                    .body_remaining_chunk_len => "body_remaining_chunk_len",
                    .closing => "closing",
                },
                if (response.head.transfer_encoding == .chunked) "chunked" else "none",
                response.head.content_length,
            });
            return CallResponse{
                .allocator = self.allocator,
                .content = "",
                .tool_calls = null,
                .finish_reason = null,
            };
        }

        var line_buffer: std.ArrayList(u8) = .empty;
        defer line_buffer.deinit(self.allocator);

        // Reuse arena across all chunks
        var chunk_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer chunk_arena.deinit();

        var chunk_count: usize = 0;
        var stream_ended_cleanly = false;
        var total_bytes_read: usize = 0;

        // Use a fixed-size read buffer
        var read_buf: [8192]u8 = undefined;

        while (true) {

            // Check reader state before attempting to read
            // The state can transition to 'ready' when content-length bytes are exhausted
            const current_state = response.request.reader.state;
            if (current_state == .ready) {
                // Stream has ended - all content-length bytes consumed
                stream_ended_cleanly = true;
                break;
            }

            // Use stream() directly instead of readSliceShort() to avoid the bug where
            // readVec suppresses EndOfStream and then retries, causing a panic
            var writer: std.Io.Writer = .{
                .buffer = &read_buf,
                .end = 0,
                .vtable = &.{ .drain = std.Io.Writer.fixedDrain },
            };

            const bytes_read = reader.stream(&writer, .limited(read_buf.len)) catch |err| {
                if (err == error.EndOfStream) {
                    self.logMsg(.info, "[STREAM] EndOfStream received");
                    stream_ended_cleanly = true;
                    break;
                }
                // Log the error and break instead of continuing to avoid panic
                self.logFmt(.err, "[STREAM] Read error: {s}", .{@errorName(err)});
                stream_ended_cleanly = false;
                break;
            };

            if (bytes_read == 0) {
                // No more data available - this can happen when the stream is exhausted
                // but EndOfStream hasn't been signaled yet (common with some HTTP servers)
                self.logMsg(.info, "[STREAM] Zero bytes read, ending stream");
                stream_ended_cleanly = true;
                break;
            }

            // self.logFmt(.debug, "[STREAM] Read {} bytes", .{bytes_read});

            // Add small yield to prevent tight CPU spinning during streaming
            // This ensures we don't monopolize CPU when reading small chunks rapidly
            if (bytes_read < 64) {
                std.Thread.sleep(100_000); // 100 microseconds for small reads
            }

            total_bytes_read += bytes_read;

            for (read_buf[0..bytes_read]) |byte| {
                if (byte == '\n') {
                    if (line_buffer.items.len > 0) {
                        const line = line_buffer.items;
                        if (self.parseSseLine(line)) |data| {
                            // _ = chunk_arena.reset(.retain_capacity);

                            if (self.parseStreamChunk(data, chunk_arena.allocator())) |chunk| {
                                chunk_count += 1;
                                callback(ctx, chunk);
                                aggregator.processChunk(chunk) catch {};
                            }
                        }
                        line_buffer.clearRetainingCapacity();
                    }
                } else if (byte != '\r') {
                    line_buffer.append(self.allocator, byte) catch {};
                }
            }
        }

        // Process remaining line
        if (line_buffer.items.len > 0) {
            if (self.parseSseLine(line_buffer.items)) |data| {
                _ = chunk_arena.reset(.retain_capacity);
                if (self.parseStreamChunk(data, chunk_arena.allocator())) |chunk| {
                    callback(ctx, chunk);
                    aggregator.processChunk(chunk) catch {};
                }
            }
        }

        callback(ctx, .{ .done = true });

        const fr_str = if (aggregator.finish_reason) |fr| fr.toStr() else "incomplete";
        const content_preview = if (aggregator.content.items.len > 0)
            if (aggregator.content.items.len > 50) aggregator.content.items[0..50] else aggregator.content.items
        else
            "(none)";
        const content_ellipsis = if (aggregator.content.items.len > 50) "..." else "";
        self.logFmt(.info, "[STREAM] Finalizing: {} tool call buffer(s), finish_reason={s}, content_len={} chars", .{
            aggregator.tool_call_buffers.count(),
            fr_str,
            aggregator.content.items.len
        });
        if (aggregator.content.items.len > 0) {
            self.logFmt(.info, "[STREAM] Content preview: {s}{s}", .{ content_preview, content_ellipsis });
        }

        const stream_response = aggregator.finalize() catch |err| {
            self.logError("finalize streaming response", err, null);
            return error.AllocFailed;
        };

        // Log final usage from response with cost estimate
        const prompt_cost = @as(f64, @floatFromInt(stream_response.usage.prompt_tokens)) * 0.000003;
        const completion_cost = @as(f64, @floatFromInt(stream_response.usage.completion_tokens)) * 0.000015;
        const total_cost = prompt_cost + completion_cost;
        self.logFmt(.info, "[STREAM] Complete - Prompt: {} | Completion: {} | Total: {} | Est. cost: ${d:.4}", .{
            stream_response.usage.prompt_tokens,
            stream_response.usage.completion_tokens,
            stream_response.usage.total_tokens,
            total_cost
        });

        return stream_response;
    }

    pub fn deinit(self: *Agent) void {
        self.httpClient.deinit();
    }
};

test {
    _ = @import("agent_test.zig");
    _ = @import("streaming_test.zig");
}
