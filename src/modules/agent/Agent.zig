const std = @import("std");
const json = std.json;
const Reader = std.Io.Reader;
const bashTool = @import("tools/bash.zig").bash_tool;
const bashMod = @import("tools/bash.zig");
const schemas = @import("tools/schemas.zig");
const BashInput = schemas.BashInput;
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
pub const AgentTool = schemas.AgentTool;
pub const prompt = @import("prompts.zig");
pub const LLMModels = @import("LLMModels.zig");

/// Log level for agent logging
const LogLevel = enum { err, warn, info, debug };

// https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create

/// Get current timestamp in milliseconds since epoch
fn timestampMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000));
}

/// Calculate elapsed time in milliseconds
fn elapsedMs(io: std.Io, start: i64) i64 {
    return timestampMs(io) - start;
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

/// Content part types for multimodal messages (text or image_url)
pub const ContentPart = struct {
    part_type: []const u8,
    text: ?[]const u8 = null,
    image_url: ?ImageUrl = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write(self.part_type);
        if (self.text) |t| {
            try stringify.objectField("text");
            try stringify.write(t);
        }
        if (self.image_url) |img| {
            try stringify.objectField("image_url");
            try img.jsonStringify(stringify);
        }
        try stringify.endObject();
    }
};

/// Image URL content for vision support
pub const ImageUrl = struct {
    url: ?[]const u8 = null,
    detail: ?[]const u8 = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        if (self.url) |u| {
            try stringify.objectField("url");
            try stringify.write(u);
        }
        if (self.detail) |d| {
            try stringify.objectField("detail");
            try stringify.write(d);
        }
        try stringify.endObject();
    }
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

    pub fn from_str(s: ?[]const u8) ?FinishReason {
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

    pub fn to_str(self: FinishReason) []const u8 {
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
    content_parts: ?[]const ContentPart = null,
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
        } else if (self.content_parts) |parts| {
            try stringify.objectField("content");
            try stringify.write(parts);
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

/// Stream options for streaming requests - enables usage in streaming responses
const JsonStreamOptions = struct {
    include_usage: bool,
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

            // stream_options with include_usage=true to receive usage in streaming response
            try stringify.objectField("stream_options");
            try stringify.write(.{ .include_usage = true });
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

/// Anthropic content block - can be text, tool_use, or tool_result
const AnthropicContentBlock = struct {
    text: ?[]const u8 = null,
    tool_use: ?AnthropicToolUse = null,
    tool_result: ?AnthropicToolResult = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        if (self.text) |t| {
            try stringify.objectField("type");
            try stringify.write("text");
            try stringify.objectField("text");
            try stringify.write(t);
        } else if (self.tool_use) |tu| {
            try stringify.objectField("type");
            try stringify.write("tool_use");
            try stringify.objectField("id");
            try stringify.write(tu.id);
            try stringify.objectField("name");
            try stringify.write(tu.name);
            try stringify.objectField("input");
            try stringify.write(tu.input);
        } else if (self.tool_result) |tr| {
            try stringify.objectField("type");
            try stringify.write("tool_result");
            try stringify.objectField("tool_use_id");
            try stringify.write(tr.tool_use_id);
            try stringify.objectField("content");
            try stringify.write(tr.content);
        }
        try stringify.endObject();
    }
};

/// Tool use content block
const AnthropicToolUse = struct {
    id: []const u8,
    name: []const u8,
    input: std.json.Value,
};

/// Tool result content block
const AnthropicToolResult = struct {
    tool_use_id: []const u8,
    content: []const u8,
};

/// Union content for a message (single block or array of blocks)
const AnthropicMessageContent = union(enum) {
    single: struct {
        text: []const u8 = "",
    },
    array: []const AnthropicContentBlock,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        switch (self) {
            .single => |s| {
                // For simple text content, just write the string
                try stringify.write(s.text);
            },
            .array => |arr| {
                try stringify.write(arr);
            },
        }
    }
};

/// Anthropic message with role and content
const AnthropicMessage = struct {
    role: []const u8,
    content: AnthropicMessageContent,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("role");
        try stringify.write(self.role);
        try stringify.objectField("content");
        try stringify.write(self.content);
        try stringify.endObject();
    }
};

/// Anthropic thinking configuration
const AnthropicThinking = struct {
    type: []const u8 = "enabled",

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write(self.type);
        try stringify.endObject();
    }
};

/// Anthropic tool input schema
const AnthropicToolInputSchema = struct {
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

/// Anthropic tool definition
const AnthropicTool = struct {
    name: []const u8,
    description: []const u8,
    input_schema: AnthropicToolInputSchema,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("name");
        try stringify.write(self.name);
        try stringify.objectField("description");
        try stringify.write(self.description);
        try stringify.objectField("input_schema");
        try stringify.write(self.input_schema);
        try stringify.endObject();
    }
};

/// Anthropic request with custom serialization
const AnthropicRequest = struct {
    model: []const u8,
    messages: []const AnthropicMessage,
    max_tokens: usize,
    stream: bool,
    tools: ?[]const AnthropicTool = null,
    thinking: ?AnthropicThinking = null,
    temperature: ?f32 = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();

        // model
        try stringify.objectField("model");
        try stringify.write(self.model);

        // messages
        try stringify.objectField("messages");
        try stringify.write(self.messages);

        // max_tokens (required by Anthropic)
        try stringify.objectField("max_tokens");
        try stringify.write(self.max_tokens);

        // temperature (optional)
        if (self.temperature) |t| {
            try stringify.objectField("temperature");
            try stringify.write(t);
        }

        // thinking config (optional, only when enabled)
        if (self.thinking) |th| {
            try stringify.objectField("thinking");
            try stringify.write(th);
        }

        // tools (optional)
        if (self.tools) |t| {
            try stringify.objectField("tools");
            try stringify.write(t);
        }

        // stream (only when true)
        if (self.stream) {
            try stringify.objectField("stream");
            try stringify.write(true);

            // stream_options with include_usage=true
            try stringify.objectField("stream_options");
            try stringify.write(.{ .include_usage = true });
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

    pub fn from_str(s: []const u8) ?Role {
        if (std.mem.eql(u8, s, "system")) return .system;
        if (std.mem.eql(u8, s, "user")) return .user;
        if (std.mem.eql(u8, s, "assistant")) return .assistant;
        if (std.mem.eql(u8, s, "tool")) return .tool;
        return null;
    }

    pub fn to_str(self: Role) []const u8 {
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
    content_parts: ?[]const ContentPart = null,
    tool_calls: ?[]ToolCall = null,
    tool_call_id: ?[]const u8 = null,
    reasoning_content: ?[]const u8 = null,

    pub fn deinit(self: *const AgentMessage, allocator: std.mem.Allocator) void {
        if (self.content) |c| allocator.free(c);
        if (self.content_parts) |parts| {
            for (parts) |part| {
                if (part.text) |t| allocator.free(t);
                if (part.image_url) |img| {
                    if (img.url) |u| allocator.free(u);
                    if (img.detail) |d| allocator.free(d);
                }
            }
            allocator.free(parts);
        }
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

    pub fn process_chunk(self: *StreamingAggregator, chunk: StreamChunk) !void {
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
            content_copy = try self.allocator.dupe(u8, std.mem.trim(u8, self.content.items, &std.ascii.whitespace));
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
    url_style: []const u8 = "openai",
};

pub const HttpOptions = struct {
    /// Overall deadline for the entire streaming read (response head + body).
    /// Triggers `error.StreamTimeout` if exceeded. Default 5 minutes.
    read_timeout_ms: u32 = 300_000,
    /// Idle window during streaming: if no new bytes arrive for this long, the stream
    /// is considered hung and `error.StreamIdleTimeout` is returned.
    /// Should be << read_timeout_ms. Catches network drops that don't produce a
    /// TCP RST/FIN promptly (Wi-Fi disconnect, half-open connection, server crash
    /// without closing the socket). Default 30 seconds.
    idle_timeout_ms: u32 = 30_000,
    /// Buffer size for reading HTTP response body (dynamic streaming, no hard limit)
    /// This is just an internal read buffer - actual content accumulates in dynamic buffers
    response_buffer_size: usize = 256 * 1024,
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
    httpOptions: HttpOptions = .{},
    UrlStyle: []const u8 = "openai",

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Agent {
        return Agent{ .allocator = allocator, .httpClient = std.http.Client{ .allocator = allocator, .io = io } };
    }

    /// Initialize agent with custom HTTP options
    pub fn init_with_options(allocator: std.mem.Allocator, io: std.Io, options: HttpOptions) !Agent {
        return Agent{
            .allocator = allocator,
            .httpClient = std.http.Client{
                .allocator = allocator,
                .io = io,
                .read_buffer_size = options.header_buffer_size,
            },
            .httpOptions = options,
        };
    }

    pub fn log_msg(_: Agent, level: LogLevel, message: []const u8) void {
        std.debug.print("[{s}] {s}\n", .{ @tagName(level), message });
    }

    /// Log with formatted message and context
    pub fn log_fmt(self: Agent, comptime level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch {
            std.debug.print("fmt alloc failed\n", .{});
            return;
        };
        defer self.allocator.free(msg);
        self.log_msg(level, msg);
    }

    /// Log error with context (operation, error name, and optional detail)
    pub fn log_error(self: Agent, operation: []const u8, err: anyerror, detail: ?[]const u8) void {
        if (detail) |d| {
            self.log_fmt(.err, "{s} failed: {s} - {s}", .{ operation, @errorName(err), d });
        } else {
            self.log_fmt(.err, "{s} failed: {s}", .{ operation, @errorName(err) });
        }
    }

    /// Log error with JSON body for debugging API issues
    pub fn log_api_error(self: Agent, operation: []const u8, err: anyerror, body: []const u8) void {
        // Truncate body if too long for logging
        const max_body_len = 500;
        const truncated = body.len > max_body_len;
        const body_to_log = if (truncated) body[0..max_body_len] else body;
        if (truncated) {
            self.log_fmt(.err, "{s} failed: {s}\nResponse (truncated): {s}...", .{ operation, @errorName(err), body_to_log });
        } else {
            self.log_fmt(.err, "{s} failed: {s}\nResponse: {s}", .{ operation, @errorName(err), body_to_log });
        }
    }

    /// Log HTTP request details for debugging
    pub fn log_request(self: Agent, method: []const u8, url: []const u8, body_len: usize) void {
        self.log_fmt(.debug, "HTTP {s} {s} (body: {} bytes)", .{ method, url, body_len });
    }

    pub fn buildJsonAnthropicRequest(self: Agent, params: AgentCall, stream: bool) ![]u8 {
        const allocator = self.allocator;

        // Use arena allocator for temporary allocations
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        // Log input stats
        var total_content_size: usize = 0;
        for (params.messages) |msg| {
            if (msg.content) |c| total_content_size += c.len;
        }
        self.log_fmt(.debug, "ANTHROPIC_STATS: tools={d}, content={d}", .{
            params.tools.len, total_content_size,
        });

        // Convert messages - Anthropic uses different structure
        // For assistant messages with tool_calls, we need to convert to tool_use content blocks
        // For user messages with tool_call_id, we need to convert to tool_result content blocks
        const json_messages = try arena_alloc.alloc(AnthropicMessage, params.messages.len);
        for (params.messages, 0..) |msg, i| {
            if (msg.role == .assistant and msg.tool_calls != null) {
                // Assistant message with tool calls -> content array with text (optional reasoning) + tool_use blocks
                var content_blocks: []AnthropicContentBlock = &.{};
                defer arena_alloc.free(content_blocks);

                // Add reasoning content as text block if present
                if (msg.reasoning_content) |rc| {
                    content_blocks = try arena_alloc.realloc(content_blocks, content_blocks.len + 1);
                    content_blocks[content_blocks.len - 1] = .{ .text = rc };
                }

                // Add tool_use blocks for each tool call
                for (msg.tool_calls.?) |tc| {
                    // Parse the arguments JSON to get the input object
                    const input_value = blk: {
                        const parsed = std.json.parseFromSlice(std.json.Value, arena_alloc, tc.function.arguments, .{}) catch {
                            break :blk std.json.Value{ .null = {} };
                        };
                        break :blk parsed.value;
                    };
                    content_blocks = try arena_alloc.realloc(content_blocks, content_blocks.len + 1);
                    content_blocks[content_blocks.len - 1] = .{
                        .tool_use = .{
                            .id = tc.id,
                            .name = tc.function.name,
                            .input = input_value,
                        },
                    };
                }

                json_messages[i] = .{
                    .role = "assistant",
                    .content = .{
                        .array = content_blocks,
                    },
                };
            } else if (msg.role == .tool) {
                // Tool result message -> tool_result content block
                var tool_content: []AnthropicContentBlock = try arena_alloc.alloc(AnthropicContentBlock, 1);
                tool_content[0] = .{
                    .tool_result = .{
                        .tool_use_id = msg.tool_call_id orelse "",
                        .content = msg.content orelse "",
                    },
                };
                json_messages[i] = .{
                    .role = "user",
                    .content = .{
                        .array = tool_content,
                    },
                };
            } else {
                // Regular message (user/system/assistant with content)
                json_messages[i] = .{
                    .role = msg.role.to_str(),
                    .content = .{
                        .single = .{
                            .text = msg.content orelse "",
                        },
                    },
                };
            }
        }

        // Convert tools to Anthropic format
        var json_tools: ?[]AnthropicTool = null;
        if (params.tools.len > 0) {
            const tool_slice = try arena_alloc.alloc(AnthropicTool, params.tools.len);
            for (params.tools, 0..) |tool, i| {
                const props = tool.function.parameters.properties;
                const json_props = try arena_alloc.alloc(ToolProperty, props.len);
                for (props, 0..) |prop, j| {
                    json_props[j] = prop;
                }
                tool_slice[i] = .{
                    .name = tool.function.name,
                    .description = tool.function.description,
                    .input_schema = .{
                        .properties = json_props,
                        .required = tool.function.parameters.required,
                    },
                };
            }
            json_tools = tool_slice;
        }

        // Build request
        const json_request = AnthropicRequest{
            .model = self.model,
            .messages = json_messages,
            .max_tokens = params.max_tokens orelse self.maxTokens,
            .stream = stream,
            .tools = json_tools,
            .thinking = if (self.thinkingEnabled) .{ .type = "enabled" } else null,
            .temperature = params.temperature,
        };

        // Serialize to JSON
        var aw: std.Io.Writer.Allocating = .init(allocator);
        try aw.writer.print("{f}", .{std.json.fmt(json_request, .{})});
        return aw.toOwnedSlice();
    }

    pub fn buildJsonOpenAIRequest(self: Agent, params: AgentCall, stream: bool) ![]u8 {
        const allocator = self.allocator;

        // Use arena allocator for temporary conversions
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        // Log input sizes and message content sizes
        var total_content_size: usize = 0;
        for (params.messages) |msg| {
            if (msg.content) |c| total_content_size += c.len;
            if (msg.reasoning_content) |rc| total_content_size += rc.len;
        }
        var total_props: usize = 0;
        for (params.tools) |tool| {
            total_props += tool.function.parameters.properties.len;
        }
        self.log_fmt(.debug, "TOOL_STATS: tools={d}, props={d}, content={d}", .{
            params.tools.len, total_props, total_content_size,
        });

        // Convert messages
        const json_messages = try arena_alloc.alloc(JsonMessage, params.messages.len);
        for (params.messages, 0..) |msg, i| {
            var json_tool_calls: ?[]JsonToolCall = null;
            if (msg.tool_calls) |tcs| {
                const tc_slice = try arena_alloc.alloc(JsonToolCall, tcs.len);
                for (tcs, 0..) |tc, j| {
                    // Normalize: empty/missing arguments → "{}" (valid JSON object)
                    const normalized_args = blk: {
                        const raw = tc.function.arguments;
                        if (raw.len == 0) break :blk "{}";
                        // Validate it's parseable JSON
                        const parsed = std.json.parseFromSlice(std.json.Value, arena_alloc, raw, .{}) catch {
                            break :blk "{}";
                        };
                        parsed.deinit();
                        break :blk raw;
                    };
                    tc_slice[j] = .{
                        .id = tc.id,
                        .type = tc.type,
                        .function = .{
                            .name = tc.function.name,
                            .arguments = normalized_args,
                        },
                    };
                }
                json_tool_calls = tc_slice;
            }

            // Convert content_parts if present (for multimodal/vision support)
            var json_content_parts: ?[]const ContentPart = null;
            if (msg.content_parts) |parts| {
                const parts_copy = try arena_alloc.alloc(ContentPart, parts.len);
                for (parts, 0..) |part, j| {
                    parts_copy[j] = .{
                        .part_type = part.part_type,
                        .text = part.text,
                        .image_url = part.image_url,
                    };
                }
                json_content_parts = parts_copy;
            }

            json_messages[i] = .{
                .role = msg.role.to_str(),
                .content = msg.content,
                .content_parts = json_content_parts,
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
        var aw: std.Io.Writer.Allocating = .init(allocator);
        try aw.writer.print("{f}", .{std.json.fmt(json_request, .{})});
        return aw.toOwnedSlice();
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
        /// Overall read deadline (HttpOptions.read_timeout_ms) was exceeded during streaming.
        StreamTimeout,
        /// No new bytes were received for HttpOptions.idle_timeout_ms during streaming.
        /// Catches network drops that don't produce a TCP RST/FIN promptly (Wi-Fi drop,
        /// half-open connection, etc.) — the "stuck on disconnect" symptom.
        StreamIdleTimeout,
        /// Mid-stream read error from the underlying HTTP transport (e.g. ConnectionResetByPeer).
        StreamInterrupted,
        /// Stream ended with 0 chunks and no clean-end signal ([DONE] or state=.closing).
        StreamEmpty,
    };

    /// Parse a single SSE line (format: "data: {...}" or "data: [DONE]")
    pub fn parse_sse_line(_: Agent, line: []const u8) ?[]const u8 {
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
    pub fn parse_stream_chunk(self: Agent, data: []const u8, arena: std.mem.Allocator) ?StreamChunk {
        const parsed = json.parseFromSlice(json.Value, arena, data, .{}) catch |err| {
            const max_data_len = 200;
            const truncated = data.len > max_data_len;
            const data_to_log = if (truncated) data[0..max_data_len] else data;
            if (truncated) {
                self.log_fmt(.err, "JSON parse failed: {s}\nData (truncated): {s}...", .{ @errorName(err), data_to_log });
            } else {
                self.log_fmt(.err, "JSON parse failed: {s}\nData: {s}", .{ @errorName(err), data_to_log });
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
                        chunk.finish_reason = FinishReason.from_str(fr.string);
                        // self.log_fmt(.info, "[STREAM] finish_reason parsed: {s}", .{fr.string});
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
                                                    @memcpy(tool_names_buf[tool_names_len .. tool_names_len + to_copy], name.string[0..to_copy]);
                                                    tool_names_len += to_copy;
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            // const tool_names_summary = if (tool_names_len > 0) tool_names_buf[0..tool_names_len] else "unknown";
                            // self.log_fmt(.info, "[STREAM] AI requesting {} tool call(s): {s}", .{tc_delta.array.items.len, tool_names_summary});

                            var deltas = arena.alloc(ToolCallDelta, tc_delta.array.items.len) catch |err| {
                                self.log_msg(.debug, "Error allocating ToolCallDelta");
                                self.log_msg(.err, @errorName(err));
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
                                // self.log_fmt(.debug, "[STREAM] Tool[{}] {s} (id={s}): args={s}{s}", .{
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
        self.log_fmt(.info, "[STREAM START] model={s} | messages={} | tools={} | streaming=true", .{ self.model, params.messages.len, params.tools.len });

        var json_body: []u8 = undefined;
        // Build request
        if (std.mem.eql(u8, self.UrlStyle, "openai")) {
            json_body = self.buildJsonOpenAIRequest(params, true) catch |err| {
                self.log_error("buildJsonRequest", err, null);
                // Log more detail for memory errors
                const err_name = @errorName(err);
                if (std.mem.eql(u8, err_name, "OutOfMemory")) {
                    self.log_fmt(.err, "OUT_OF_MEMORY: messages={d}, tools={d}", .{
                        params.messages.len,
                        params.tools.len,
                    });
                }
                return error.BuildRequestFailed;
            };
        } else {
            // Anthropic style
            json_body = self.buildJsonAnthropicRequest(params, true) catch |err| {
                self.log_error("buildJsonAnthropicRequest", err, null);
                const err_name = @errorName(err);
                if (std.mem.eql(u8, err_name, "OutOfMemory")) {
                    self.log_fmt(.err, "OUT_OF_MEMORY: messages={d}, tools={d}", .{
                        params.messages.len,
                        params.tools.len,
                    });
                }
                return error.BuildRequestFailed;
            };
        }
        defer self.allocator.free(json_body);

        // Estimate tokens: ~4 chars per token (rough approximation for debugging)
        const estimated_tokens = @divFloor(json_body.len + 3, 4);
        self.log_fmt(.info, "[TOKEN ESTIMATE] sending ~{} tokens ({} bytes)", .{ estimated_tokens, json_body.len });

        // Log request (truncated for safety)
        const json_preview_len = if (json_body.len > 500) 500 else json_body.len;
        const json_ellipsis = if (json_body.len > 500) "..." else "";
        self.log_fmt(.debug, "[STREAM REQUEST] JSON body ({} bytes): {s}{s}", .{ json_body.len, json_body[0..json_preview_len], json_ellipsis });

        // Determine endpoint based on url_style
        const endpoint = if (std.mem.eql(u8, self.UrlStyle, "anthropic"))
            "/messages"
        else
            "/chat/completions";
        const uri_str = std.mem.concat(self.allocator, u8, &.{ self.baseUrl, endpoint }) catch |err| {
            self.log_error("concat URI", err, null);
            return error.OutOfMemory;
        };
        defer self.allocator.free(uri_str);

        const uri = std.Uri.parse(uri_str) catch |err| {
            self.log_fmt(.err, "Failed to parse URI '{s}': {s}", .{ uri_str, @errorName(err) });
            return error.InvalidUri;
        };

        // Build auth header (both OpenAI and Anthropic use Bearer token)
        const auth_value = std.mem.concat(self.allocator, u8, &.{ "Bearer ", self.apiKey }) catch |err| {
            self.log_error("concat auth", err, null);
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
            self.log_fmt(.err, "HTTP streaming request failed to '{s}': {s}", .{ uri_str, @errorName(err) });
            return error.HttpRequestFailed;
        };
        defer req.deinit();

        req.sendBodyComplete(json_body) catch |err| {
            self.log_error("sendBodyComplete", err, null);
            return error.SendBodyFailed;
        };

        const stream_start = timestampMs(self.httpClient.io);
        var redirect_buffer: [8192]u8 = undefined;
        var response = req.receiveHead(&redirect_buffer) catch |err| {
            self.log_fmt(.err, "[TIMEOUT] No response after {}ms: {s}", .{ elapsedMs(self.httpClient.io, stream_start), @errorName(err) });
            return error.ReceiveFailed;
        };

        const stream_duration = elapsedMs(self.httpClient.io, stream_start);
        const stream_duration_fmt = formatDuration(stream_duration);
        self.log_fmt(.info, "[STREAM] Connected in {}{s} (HTTP {d})", .{ stream_duration_fmt.value, stream_duration_fmt.unit, @intFromEnum(response.head.status) });

        // Log transfer details for debugging
        const encoding_str = if (response.head.transfer_encoding == .chunked) "chunked" else "fixed";
        var content_len_buf: [32]u8 = undefined;
        const content_len_str = if (response.head.content_length) |cl|
            std.fmt.bufPrint(&content_len_buf, "{}", .{cl}) catch "?"
        else
            "unknown";
        self.log_fmt(.debug, "[STREAM] Transfer: encoding={s}, content_length={s}, keep_alive={}", .{
            encoding_str,
            content_len_str,
            response.head.keep_alive,
        });

        // Handle non-success HTTP status codes
        if (response.head.status.class() == .client_error or response.head.status.class() == .server_error) {
            const status_code = @intFromEnum(response.head.status);
            self.log_fmt(.err, "[STREAM] HTTP error status: {d}", .{status_code});

            // Read the error body from the server
            const transfer_buf = self.allocator.alloc(u8, 4096) catch null;
            if (transfer_buf) |buf| {
                defer self.allocator.free(buf);
                var err_reader = response.request.reader.bodyReader(buf, response.head.transfer_encoding, response.head.content_length);

                // Read the error response body
                const error_body = err_reader.allocRemaining(self.allocator, .unlimited) catch null;
                if (error_body) |body| {
                    defer self.allocator.free(body);
                    self.log_fmt(.err, "[STREAM] Server error response: {s}", .{body});
                }
            }

            return error.ApiError;
        }

        // Check if response has a body
        if (!response.request.method.responseHasBody()) {
            self.log_msg(.info, "[STREAM] Response has no body (status code)");
            return CallResponse{
                .allocator = self.allocator,
                .content = "",
                .tool_calls = null,
                .finish_reason = null,
            };
        }

        if (response.head.content_length == null and response.head.transfer_encoding != .chunked) {
            self.log_msg(.info, "[STREAM] Response has no body (no content-length, not chunked)");
            return CallResponse{
                .allocator = self.allocator,
                .content = "",
                .tool_calls = null,
                .finish_reason = null,
            };
        }

        // Handle zero content-length to avoid union field access panic
        if (response.head.content_length != null and response.head.content_length.? == 0) {
            self.log_msg(.info, "[STREAM] Response has empty body (content-length=0)");
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
            self.log_error("alloc transfer_buffer", err, null);
            return error.OutOfMemory;
        };
        defer self.allocator.free(transfer_buffer);

        // Debug: log reader state and response details
        self.log_fmt(.info, "[STREAM] bodyReader called: transfer_encoding={s}, content_length={?}, reader_state={s}", .{
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

        var line_buffer: std.ArrayList(u8) = .empty;
        defer line_buffer.deinit(self.allocator);

        // Reuse arena across all chunks
        var chunk_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer chunk_arena.deinit();

        var chunk_count: usize = 0;
        var stream_ended_cleanly = false;
        var total_bytes_read: usize = 0;

        // Deadline tracking for stream hang detection. Without this, a network drop
        // (e.g. Wi-Fi disconnect, half-open TCP) leaves readSliceShort returning 0
        // forever, and the workflow gets stuck waiting for a response that will
        // never come. See audit/plan: "no read deadline on the streaming body".
        const stream_read_deadline_ms: i64 = @intCast(self.httpOptions.read_timeout_ms);
        const stream_idle_deadline_ms: i64 = @intCast(self.httpOptions.idle_timeout_ms);
        var last_byte_at_ms: i64 = timestampMs(self.httpClient.io);

        // Get a reader from bodyReader - this properly handles chunked transfer encoding
        const reader = response.request.reader.bodyReader(transfer_buffer, response.head.transfer_encoding, response.head.content_length);
        self.log_fmt(.info, "[STREAM] bodyReader returned reader, state={s}", .{
            switch (response.request.reader.state) {
                .ready => "ready",
                .received_head => "received_head",
                .body_none => "body_none",
                .body_remaining_content_length => "body_remaining_content_length",
                .body_remaining_chunk_len => "body_remaining_chunk_len",
                .closing => "closing",
            },
        });

        // Allocate a buffer for reading
        const read_buffer = self.allocator.alloc(u8, 8192) catch {
            self.log_msg(.err, "[STREAM] failed to alloc read_buffer");
            return error.OutOfMemory;
        };
        defer self.allocator.free(read_buffer);

        while (true) {
            // Deadline check 1: overall stream deadline. Detects "stuck forever" hangs.
            const overall_elapsed_ms = elapsedMs(self.httpClient.io, stream_start);
            if (overall_elapsed_ms > stream_read_deadline_ms) {
                self.log_fmt(.err, "[STREAM] overall deadline exceeded: {}ms > {}ms (chunks={}, bytes={})", .{
                    overall_elapsed_ms, stream_read_deadline_ms, chunk_count, total_bytes_read,
                });
                return error.StreamTimeout;
            }

            // Deadline check 2: idle window. Detects network drops that don't error
            // out (TCP keepalive hasn't noticed yet) but also don't deliver data.
            const idle_elapsed_ms = elapsedMs(self.httpClient.io, last_byte_at_ms);
            if (idle_elapsed_ms > stream_idle_deadline_ms) {
                self.log_fmt(.err, "[STREAM] idle for {}ms (no bytes received), total_elapsed={}ms, chunks={}", .{
                    idle_elapsed_ms, overall_elapsed_ms, chunk_count,
                });
                return error.StreamIdleTimeout;
            }

            self.log_msg(.info, "[STREAM] top of loop");

            // Check reader state
            const current_state = response.request.reader.state;
            if (current_state == .ready) {
                stream_ended_cleanly = true;
                self.log_msg(.info, "[STREAM] Reader state is ready, stream ended");
                break;
            }

            self.log_fmt(.info, "[STREAM] about to readSliceShort, state={s}", .{
                switch (current_state) {
                    .ready => "ready",
                    .received_head => "received_head",
                    .body_none => "body_none",
                    .body_remaining_content_length => "body_remaining_content_length",
                    .body_remaining_chunk_len => "body_remaining_chunk_len",
                    .closing => "closing",
                },
            });

            // Read using bodyReader's readSliceShort. Any read error here is a real
            // transport failure (e.g. ConnectionResetByPeer, ConnectionTimedOut) — we
            // MUST surface it to the caller instead of swallowing it and returning a
            // half-populated response. This is the core fix for "stream silently
            // truncated on network drop".
            const n = reader.readSliceShort(read_buffer[0..]) catch |err| {
                self.log_fmt(.err, "[STREAM] read error after {}ms: {s} (chunks={}, bytes={})", .{
                    overall_elapsed_ms, @errorName(err), chunk_count, total_bytes_read,
                });
                return error.StreamInterrupted;
            };
            self.log_fmt(.info, "[STREAM] readSliceShort returned n={}", .{n});

            if (n == 0) {
                // n == 0 = "no data available right now" (EAGAIN-equivalent). It is NOT
                // a clean stream end on its own. The previous code did a single in-line
                // retry and then gave up, which masked slow LLMs and half-open
                // connections. New behavior:
                //   - If the reader is in .closing state, the server closed the socket
                //     properly -> clean end, break.
                //   - Otherwise, sleep briefly and let the top-of-loop deadline checks
                //     decide whether we're idle for too long.
                if (response.request.reader.state == .closing) {
                    stream_ended_cleanly = true;
                    self.log_msg(.info, "[STREAM] Reader state is closing, stream ended cleanly");
                    break;
                }
                std.Io.sleep(self.httpClient.io, .{ .nanoseconds = 50_000 }, .real) catch {};
                continue;
            }

            const bytes_read: usize = @intCast(n);
            total_bytes_read += bytes_read;
            // Reset the idle window: we just got data, so any future silence is
            // a fresh idle interval, not a continuation of the previous one.
            last_byte_at_ms = timestampMs(self.httpClient.io);
            self.log_fmt(.info, "[STREAM] read {} bytes (total={})", .{ bytes_read, total_bytes_read });

            // Add small yield to prevent tight CPU spinning during streaming
            if (bytes_read < 64) {
                std.Io.sleep(self.httpClient.io, .{ .nanoseconds = 100_000 }, .real) catch {};
            }

            for (read_buffer[0..bytes_read]) |byte| {
                if (byte == '\n') {
                    if (line_buffer.items.len > 0) {
                        const line = line_buffer.items;
                        self.log_fmt(.info, "[STREAM] line buffer: \"{s}\"", .{line});
                        if (self.parse_sse_line(line)) |data| {
                            self.log_fmt(.info, "[STREAM] SSE data: \"{s}\"", .{data});
                            // _ = chunk_arena.reset(.retain_capacity);

                            if (self.parse_stream_chunk(data, chunk_arena.allocator())) |chunk| {
                                chunk_count += 1;
                                self.log_fmt(.info, "[STREAM] parsed chunk #{}: content_len={}, reasoning_len={}, tool_calls={}", .{
                                    chunk_count,
                                    if (chunk.content) |c| c.len else 0,
                                    if (chunk.reasoning_content) |r| r.len else 0,
                                    if (chunk.tool_calls_delta) |t| t.len else 0,
                                });
                                callback(ctx, chunk);
                                aggregator.process_chunk(chunk) catch {};
                            } else {
                                self.log_fmt(.err, "[STREAM] parse_stream_chunk returned null for data: {s}", .{data});
                            }
                        } else {
                            self.log_fmt(.info, "[STREAM] parse_sse_line returned null for line: {s}", .{line});
                        }
                        line_buffer.clearRetainingCapacity();
                    }
                } else if (byte != '\r') {
                    line_buffer.append(self.allocator, byte) catch {};
                }
            }
        }

        // Process remaining line (if any) - this is content we received before the
        // loop ended. We process it first so the aggregator has the full picture
        // before we decide whether the stream ended cleanly.
        if (line_buffer.items.len > 0) {
            if (self.parse_sse_line(line_buffer.items)) |data| {
                _ = chunk_arena.reset(.retain_capacity);
                if (self.parse_stream_chunk(data, chunk_arena.allocator())) |chunk| {
                    callback(ctx, chunk);
                    aggregator.process_chunk(chunk) catch {};
                }
            }
        }

        // Enforce clean-end semantics. The previous code always sent the done
        // callback and returned a CallResponse, even when the loop exited via a
        // silent `break` on read error. That hid network drops from the caller.
        // New rule: a successful return requires the server to have cleanly
        // ended the stream (state == .closing, [DONE] marker, or fixed
        // content_length fully consumed). Otherwise we propagate an error so
        // the workflow's retry path can take over.
        if (!stream_ended_cleanly) {
            if (chunk_count == 0) {
                self.log_fmt(.err, "[STREAM] stream ended with 0 chunks and no clean-end signal - returning StreamEmpty", .{});
                return error.StreamEmpty;
            }
            self.log_fmt(.err, "[STREAM] stream did not end cleanly after {} chunks ({} bytes, {}ms elapsed) - returning StreamInterrupted", .{
                chunk_count,
                total_bytes_read,
                elapsedMs(self.httpClient.io, stream_start),
            });
            return error.StreamInterrupted;
        }

        callback(ctx, .{ .done = true });
        self.log_fmt(.info, "[STREAM] Sent done marker, chunk_count={}", .{chunk_count});

        const fr_str = if (aggregator.finish_reason) |fr| fr.to_str() else "incomplete";
        const content_preview = if (aggregator.content.items.len > 0)
            if (aggregator.content.items.len > 50) aggregator.content.items[0..50] else aggregator.content.items
        else
            "(none)";
        const content_ellipsis = if (aggregator.content.items.len > 50) "..." else "";
        self.log_fmt(.info, "[STREAM] Finalizing: {} tool call buffer(s), finish_reason={s}, content_len={} chars", .{ aggregator.tool_call_buffers.count(), fr_str, aggregator.content.items.len });
        if (aggregator.content.items.len > 0) {
            self.log_fmt(.info, "[STREAM] Content preview: {s}{s}", .{ content_preview, content_ellipsis });
        }

        const stream_response = aggregator.finalize() catch |err| {
            self.log_error("finalize streaming response", err, null);
            return error.AllocFailed;
        };

        // Log final usage from response with cost estimate
        const prompt_cost = @as(f64, @floatFromInt(stream_response.usage.prompt_tokens)) * 0.000003;
        const completion_cost = @as(f64, @floatFromInt(stream_response.usage.completion_tokens)) * 0.000015;
        const total_cost = prompt_cost + completion_cost;
        self.log_fmt(.info, "[STREAM] Complete - Prompt: {} | Completion: {} | Total: {} | Est. cost: ${d:.4}", .{ stream_response.usage.prompt_tokens, stream_response.usage.completion_tokens, stream_response.usage.total_tokens, total_cost });

        return stream_response;
    }

    pub fn deinit(self: *Agent) void {
        self.httpClient.deinit();
    }
};
