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
const helpers = @import("../../helpers/mod.zig");
const custom_http_client = @import("custom_http_client");

/// Log level for agent logging
const LogLevel = enum { err, warn, info, debug };

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
    reason: ?[]const u8,
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
    stop,
    length,
    tool_calls,
    content_filter,
    tool,
    null,
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

const JsonFunctionCall = struct {
    name: []const u8,
    arguments: []const u8,
};

const JsonToolCall = struct {
    id: []const u8,
    type: []const u8 = "function",
    function: JsonFunctionCall,
};

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

const JsonToolFunction = struct {
    name: []const u8,
    description: []const u8,
    parameters: JsonToolParameters,
};

const JsonTool = struct {
    type: []const u8,
    function: JsonToolFunction,
};

const JsonThinkingConfig = struct {
    type: []const u8 = "disabled",
};

const JsonStreamOptions = struct {
    include_usage: bool,
};

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

    /// Optional end-user identifier. Omitted from the JSON body when null
    /// or empty. Maps to OpenAI's `user` request-body parameter. See
    /// https://platform.openai.com/docs/api-reference/chat/create.
    user: ?[]const u8 = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("model");
        try stringify.write(self.model);
        if (self.thinking) |th| {
            try stringify.objectField("thinking");
            try stringify.write(th);
        }
        try stringify.objectField("enable_thinking");
        try stringify.write(self.enable_thinking);
        try stringify.objectField("messages");
        try stringify.write(self.messages);
        try stringify.objectField("temperature");
        try stringify.write(self.temperature);
        try stringify.objectField("max_tokens");
        try stringify.write(self.max_tokens);
        if (self.stream) {
            try stringify.objectField("stream");
            try stringify.write(true);
            try stringify.objectField("stream_options");
            try stringify.write(.{ .include_usage = true });
        }
        if (self.tools) |t| {
            try stringify.objectField("tools");
            try stringify.write(t);
            try stringify.objectField("tool_choice");
            try stringify.write(self.tool_choice.?);
        }
        if (self.user) |u| {
            if (u.len > 0) {
                try stringify.objectField("user");
                try stringify.write(u);
            }
        }
        try stringify.endObject();
    }
};

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

const AnthropicToolUse = struct {
    id: []const u8,
    name: []const u8,
    input: std.json.Value,
};

const AnthropicToolResult = struct {
    tool_use_id: []const u8,
    content: []const u8,
};

const AnthropicMessageContent = union(enum) {
    single: struct {
        text: []const u8 = "",
    },
    array: []const AnthropicContentBlock,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        switch (self) {
            .single => |s| try stringify.write(s.text),
            .array => |arr| try stringify.write(arr),
        }
    }
};

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

const AnthropicThinking = struct {
    type: []const u8 = "enabled",

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("type");
        try stringify.write(self.type);
        try stringify.endObject();
    }
};

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

/// Anthropic `metadata` block. Currently only `user_id` is supported —
/// Anthropic's Messages API accepts arbitrary key/value metadata but
/// nalar only uses `user_id` for the LLM-API end-user identifier.
const AnthropicMetadata = struct {
    user_id: []const u8,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("user_id");
        try stringify.write(self.user_id);
        try stringify.endObject();
    }
};

const AnthropicRequest = struct {
    model: []const u8,
    messages: []const AnthropicMessage,
    max_tokens: usize,
    stream: bool,
    tools: ?[]const AnthropicTool = null,
    thinking: ?AnthropicThinking = null,
    temperature: ?f32 = null,

    /// Optional metadata block. Currently emits `{"user_id": "..."}`
    /// from `Agent.userIdentifier`. See
    /// https://docs.claude.com/en/api/messages.
    metadata: ?AnthropicMetadata = null,

    pub fn jsonStringify(self: @This(), stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try stringify.objectField("model");
        try stringify.write(self.model);
        try stringify.objectField("messages");
        try stringify.write(self.messages);
        try stringify.objectField("max_tokens");
        try stringify.write(self.max_tokens);
        if (self.temperature) |t| {
            try stringify.objectField("temperature");
            try stringify.write(t);
        }
        if (self.thinking) |th| {
            try stringify.objectField("thinking");
            try stringify.write(th);
        }
        if (self.tools) |t| {
            try stringify.objectField("tools");
            try stringify.write(t);
        }
        if (self.stream) {
            try stringify.objectField("stream");
            try stringify.write(true);
            try stringify.objectField("stream_options");
            try stringify.write(.{ .include_usage = true });
        }
        if (self.metadata) |m| {
            try stringify.objectField("metadata");
            try stringify.write(m);
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
    system,
    user,
    assistant,
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
    /// DB primary key from `llm_history.id` (19-digit timestamp string).
    /// NULL for messages synthesized in-memory (e.g. system prompts at
    /// workflow.zig:1046-1064). Populated by
    /// `transform_llm_history_to_agent_message` for messages loaded from
    /// the DB. Used by `buildCompactionEnvelope` to embed real ids in
    /// the `<compact_messages>` envelope so `search_history`
    /// can find them.
    id: ?[]const u8 = null,
    role: Role,
    content: ?[]const u8,
    content_parts: ?[]const ContentPart = null,
    tool_calls: ?[]ToolCall = null,
    tool_call_id: ?[]const u8 = null,
    reasoning_content: ?[]const u8 = null,

    pub fn deinit(self: *const AgentMessage, allocator: std.mem.Allocator) void {
        if (self.id) |i| allocator.free(i);
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

pub const Usage = struct {
    prompt_tokens: usize = 0,
    completion_tokens: usize = 0,
    total_tokens: usize = 0,
};

pub const ToolCallDelta = struct {
    index: usize,
    id: ?[]const u8 = null,
    function_name: ?[]const u8 = null,
    function_arguments: ?[]const u8 = null,
};

pub const StreamChunk = struct {
    content: ?[]const u8 = null,
    reasoning_content: ?[]const u8 = null,
    tool_calls_delta: ?[]const ToolCallDelta = null,
    finish_reason: ?FinishReason = null,
    usage: ?Usage = null,
    done: bool = false,
};

pub const StreamCallback = *const fn (ctx: ?*anyopaque, chunk: StreamChunk) void;

pub const StreamingAggregator = struct {
    allocator: std.mem.Allocator,
    content: std.ArrayList(u8),
    reasoning_content: std.ArrayList(u8),
    tool_calls: std.ArrayList(ToolCall),
    finish_reason: ?FinishReason = null,
    usage: Usage = .{},

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

        if (chunk.content) |c| {
            try self.content.appendSlice(self.allocator, c);
        }
        if (chunk.reasoning_content) |rc| {
            try self.reasoning_content.appendSlice(self.allocator, rc);
        }

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

        if (chunk.finish_reason) |fr| {
            self.finish_reason = fr;
        }

        if (chunk.usage) |usage| {
            if (usage.total_tokens > 0) {
                self.usage = usage;
            }
        }
    }

    pub fn finalize(self: *StreamingAggregator) !CallResponse {
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
    /// Overall deadline for the entire streaming read (response head + body).
    /// Triggers `error.StreamTimeout` if exceeded. Default 5 minutes.
    read_timeout_ms: u32 = 300_000,
    /// Idle window: if no new bytes arrive for this long after readSliceShort
    /// returns, the stream is considered hung. With TCP keepalive set to ~25s,
    /// keep this comfortably above the keepalive window so keepalive probes
    /// have time to fire and return an error (StreamInterrupted) before this
    /// deadline (StreamIdleTimeout) triggers. Hard floor: 30_000 (1.2× the
    /// ~25s keepalive window).
    ///
    /// Raised from 60_000 (2026-06-28) to 180_000 to accommodate reasoning
    /// models (Claude with extended thinking, OpenAI o1/o3, DeepSeek R1,
    /// Qwen QwQ) that routinely pause for tens of seconds to minutes
    /// between SSE chunks while reasoning internally. The previous 60s
    /// default fired StreamIdleTimeout on perfectly healthy streams.
    idle_timeout_ms: u32 = 180_000,
    /// Buffer size for reading HTTP response body
    response_buffer_size: usize = 256 * 1024,
    /// Buffer size for HTTP headers
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
    client: custom_http_client.Client,
    io: std.Io,
    thinkingEnabled: bool = true,
    allocator: std.mem.Allocator,
    httpOptions: HttpOptions = .{},
    UrlStyle: []const u8 = "openai",
    userIdentifier: []const u8 = "AnakMagang",
    /// Most recent server/transporter error detail (e.g. the JSON error body
    /// the LLM provider returned for HTTP >=400, or a synthesized reason for
    /// mid-stream failures like scanner errors / missing finish_reason).
    /// Heap-allocated via `self.allocator`; freed by `deinit()`. Survives
    /// only until the next `callStreaming` call or `deinit()`. Workflow
    /// reads this in its retry-catch block to log WHY the call failed —
    /// without it we only see error names like "ApiError" /
    /// "StreamInterrupted" and have no way to distinguish a rate limit
    /// from an auth failure from a transport glitch.
    last_error_message: ?[]const u8 = null,

    /// Anthropic-only: cached input_tokens from the `message_start` event.
    /// Emitted on the first `content_block_delta` chunk so the aggregator
    /// sees a single usage event (mirrors how the OpenAI parser uses
    /// `stream_options.include_usage=true` to get a trailing usage chunk).
    /// Reset to 0 at the top of every `callStreaming` invocation.
    _anthropic_input_tokens: u32 = 0,
    /// Anthropic-only: guard so the cached input_tokens are sent exactly
    /// once per call (on the first delta). Reset to false at the top of
    /// every `callStreaming` invocation.
    _anthropic_usage_emitted: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Agent {
        return Agent{
            .allocator = allocator,
            .io = io,
            .client = custom_http_client.Client.init(allocator),
        };
    }

    pub fn init_with_options(allocator: std.mem.Allocator, io: std.Io, options: HttpOptions) Agent {
        return Agent{
            .allocator = allocator,
            .io = io,
            .client = custom_http_client.Client.init(allocator),
            .httpOptions = options,
        };
    }

    pub fn log_msg(_: Agent, level: LogLevel, message: []const u8) void {
        std.debug.print("[{s}] {s}\n", .{ @tagName(level), message });
    }

    pub fn log_fmt(self: Agent, comptime level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch {
            std.debug.print("fmt alloc failed\n", .{});
            return;
        };
        defer self.allocator.free(msg);
        self.log_msg(level, msg);
    }

    pub fn log_error(self: Agent, operation: []const u8, err: anyerror, detail: ?[]const u8) void {
        if (detail) |d| {
            self.log_fmt(.err, "{s} failed: {s} - {s}", .{ operation, @errorName(err), d });
        } else {
            self.log_fmt(.err, "{s} failed: {s}", .{ operation, @errorName(err) });
        }
    }

    pub fn log_api_error(self: Agent, operation: []const u8, err: anyerror, body: []const u8) void {
        const max_body_len = 500;
        const truncated = body.len > max_body_len;
        const body_to_log = if (truncated) body[0..max_body_len] else body;
        if (truncated) {
            self.log_fmt(.err, "{s} failed: {s}\nResponse (truncated): {s}...", .{ operation, @errorName(err), body_to_log });
        } else {
            self.log_fmt(.err, "{s} failed: {s}\nResponse: {s}", .{ operation, @errorName(err), body_to_log });
        }
    }

    pub fn log_request(self: Agent, method: []const u8, url: []const u8, body_len: usize) void {
        self.log_fmt(.debug, "HTTP {s} {s} (body: {} bytes)", .{ method, url, body_len });
    }


    pub fn buildJsonAnthropicRequest(self: Agent, params: AgentCall, stream: bool) ![]u8 {
        const allocator = self.allocator;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        var total_content_size: usize = 0;
        for (params.messages) |msg| {
            if (msg.content) |c| total_content_size += c.len;
        }
        self.log_fmt(.debug, "ANTHROPIC_STATS: tools={d}, content={d}", .{
            params.tools.len, total_content_size,
        });

        const json_messages = try arena_alloc.alloc(AnthropicMessage, params.messages.len);
        for (params.messages, 0..) |msg, i| {
            if (msg.role == .assistant and msg.tool_calls != null) {
                var content_blocks: []AnthropicContentBlock = &.{};
                // NOTE: content_blocks is stored into json_messages[i].content
                // below and must stay alive until the whole request has been
                // serialized by std.json.fmt in this function. It's an
                // arena allocation — the arena is torn down by the `defer
                // arena.deinit()` above once this function returns, so it
                // must NOT be freed early here. (Freeing it early via
                // arena_alloc.free() would rewind the arena's bump pointer
                // and let it get silently overwritten by later allocations
                // in this same function — e.g. the next message's content
                // blocks, or the tools array.)

                if (msg.reasoning_content) |rc| {
                    content_blocks = try arena_alloc.realloc(content_blocks, content_blocks.len + 1);
                    // CRITICAL: explicitly set ALL three optional fields. In
                    // Zig 0.16, `.{ .text = rc }` only initializes .text — the
                    // other fields stay as whatever was in the arena's
                    // uninitialized memory (0xAA debug poison from previous
                    // occupants), and `AnthropicContentBlock.jsonStringify`'s
                    // `if (self.text)` reads the poisoned bytes as a slice
                    // pointer → SEGV in utf8ValidateSlice.
                    content_blocks[content_blocks.len - 1] = .{
                        .text = rc,
                        .tool_use = null,
                        .tool_result = null,
                    };
                }

                for (msg.tool_calls.?) |tc| {
                    const input_value = blk: {
                        const parsed = std.json.parseFromSlice(std.json.Value, arena_alloc, tc.function.arguments, .{}) catch {
                            break :blk std.json.Value{ .null = {} };
                        };
                        break :blk parsed.value;
                    };
                    content_blocks = try arena_alloc.realloc(content_blocks, content_blocks.len + 1);
                    content_blocks[content_blocks.len - 1] = .{
                        .text = null,
                        .tool_use = .{
                            .id = tc.id,
                            .name = tc.function.name,
                            .input = input_value,
                        },
                        .tool_result = null,
                    };
                }

                json_messages[i] = .{
                    .role = "assistant",
                    .content = .{ .array = content_blocks },
                };
            } else if (msg.role == .tool) {
                const tool_content = try arena_alloc.alloc(AnthropicContentBlock, 1);
                tool_content[0] = .{
                    .text = null,
                    .tool_use = null,
                    .tool_result = .{
                        .tool_use_id = msg.tool_call_id orelse "",
                        .content = msg.content orelse "",
                    },
                };
                json_messages[i] = .{
                    .role = "user",
                    .content = .{ .array = tool_content },
                };
            } else {
                json_messages[i] = .{
                    .role = msg.role.to_str(),
                    .content = .{ .single = .{ .text = msg.content orelse "" } },
                };
            }
        }

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

        const json_request = AnthropicRequest{
            .model = self.model,
            .messages = json_messages,
            .max_tokens = params.max_tokens orelse self.maxTokens,
            .stream = stream,
            .tools = json_tools,
            .thinking = if (self.thinkingEnabled) .{ .type = "enabled" } else null,
            .temperature = params.temperature,
            .metadata = if (self.userIdentifier.len > 0)
                .{ .user_id = self.userIdentifier }
            else
                null,
        };

        var aw: std.Io.Writer.Allocating = .init(allocator);
        try aw.writer.print("{f}", .{std.json.fmt(json_request, .{})});
        return aw.toOwnedSlice();
    }

    pub fn buildJsonOpenAIRequest(self: Agent, params: AgentCall, stream: bool) ![]u8 {
        const allocator = self.allocator;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

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

        const json_messages = try arena_alloc.alloc(JsonMessage, params.messages.len);
        for (params.messages, 0..) |msg, i| {
            var json_tool_calls: ?[]JsonToolCall = null;
            if (msg.tool_calls) |tcs| {
                const tc_slice = try arena_alloc.alloc(JsonToolCall, tcs.len);
                for (tcs, 0..) |tc, j| {
                    const normalized_args = blk: {
                        const raw = tc.function.arguments;
                        if (raw.len == 0) break :blk "{}";
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
            .user = if (self.userIdentifier.len > 0) self.userIdentifier else null,
        };

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
        /// Overall read deadline (HttpOptions.read_timeout_ms) was exceeded.
        StreamTimeout,
        /// No new bytes for HttpOptions.idle_timeout_ms after readSliceShort returned.
        /// With TCP keepalive, this fires after keepalive detects the dead connection
        /// (~25s) and readSliceShort returns an error, then the idle check triggers.
        StreamIdleTimeout,
        /// Mid-stream transport error (e.g. ConnectionResetByPeer from keepalive).
        StreamInterrupted,
        /// Stream ended with 0 chunks and no clean-end signal.
        StreamEmpty,
    };

    pub fn parse_sse_line(_: Agent, line: []const u8) ?[]const u8 {
        if (line.len == 0) return null;
        if (!std.mem.startsWith(u8, line, "data: ")) return null;
        const data = line[6..];
        if (std.mem.eql(u8, data, "[DONE]")) return null;
        return data;
    }

    pub fn parse_stream_chunk(self: *Agent, data: []const u8, arena: std.mem.Allocator) ?StreamChunk {
        // Anthropic uses a different SSE event shape (`event:` + `data:`
        // pairs with a `type` field, not `choices[0].delta`). Dispatch on
        // UrlStyle so the rest of the pipeline (StreamingAggregator,
        // CallResponse, the workflow loop) sees the same StreamChunk shape
        // regardless of provider.
        if (std.mem.eql(u8, self.UrlStyle, "anthropic")) {
            return self.parse_anthropic_stream_chunk(data, arena);
        }
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
                    }
                }

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
                                self.log_fmt(.err, "Error allocating ToolCallDelta: {s}", .{@errorName(err)});
                                return null;
                            };
                            for (tc_delta.array.items, 0..) |tc_item, i| {
                                var delta_item: ToolCallDelta = .{ .index = i };
                                if (tc_item == .object) {
                                    if (tc_item.object.get("index")) |idx| {
                                        if (idx == .integer) delta_item.index = @intCast(idx.integer);
                                    }
                                    if (tc_item.object.get("id")) |id| {
                                        if (id == .string and id.string.len > 0) delta_item.id = id.string;
                                    }
                                    if (tc_item.object.get("function")) |func| {
                                        if (func == .object) {
                                            if (func.object.get("name")) |name| {
                                                if (name == .string and name.string.len > 0) delta_item.function_name = name.string;
                                            }
                                            if (func.object.get("arguments")) |args| {
                                                if (args == .string and args.string.len > 0) delta_item.function_arguments = args.string;
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

    /// Anthropic streaming-SSE → StreamChunk mapper.
    ///
    /// Anthropic's /v1/messages streams `event:` + `data:` pairs (the wire
    /// shape the OpenAI parser doesn't understand). We translate the events
    /// the workflow cares about into the same `StreamChunk` shape the
    /// OpenAI parser produces, so the rest of the pipeline
    /// (StreamingAggregator, CallResponse, the workflow loop) doesn't need
    /// to know which provider it's talking to.
    ///
    /// Event → StreamChunk mapping (see
    /// docs/superpowers/plans/2026-08-13-anthropic-profile-sse-parsing.md
    /// for the full spec):
    ///   message_start           → caches input_tokens (no chunk emitted)
    ///   content_block_delta     → text_delta|thinking_delta|input_json_delta
    ///   content_block_start     → tool_use → tool_calls_delta[i] with id+name
    ///   message_delta           → finish_reason + output_tokens (usage chunk)
    ///   message_stop            → no-op (signal-only)
    ///   content_block_stop      → no-op (signal-only)
    ///   anything else           → return null
    ///
    /// Per-call scratch state lives on the Agent struct (reset at the top
    /// of `callStreaming`): `_anthropic_input_tokens` (cached from
    /// message_start) and `_anthropic_usage_emitted` (guard so the cached
    /// input_tokens are emitted on the first delta only).
    fn parse_anthropic_stream_chunk(
        self: *Agent,
        data: []const u8,
        arena: std.mem.Allocator,
    ) ?StreamChunk {
        const parsed = json.parseFromSlice(json.Value, arena, data, .{}) catch |err| {
            const max_data_len = 200;
            const truncated = data.len > max_data_len;
            const data_to_log = if (truncated) data[0..max_data_len] else data;
            if (truncated) {
                self.log_fmt(.err, "Anthropic SSE JSON parse failed: {s}\nData (truncated): {s}...", .{ @errorName(err), data_to_log });
            } else {
                self.log_fmt(.err, "Anthropic SSE JSON parse failed: {s}\nData: {s}", .{ @errorName(err), data_to_log });
            }
            return null;
        };
        defer parsed.deinit();

        const root = parsed.value;
        const type_val = root.object.get("type") orelse return null;
        if (type_val != .string) return null;
        const event_type = type_val.string;

        if (std.mem.eql(u8, event_type, "message_start")) {
            // Cache input_tokens from message.message.usage.input_tokens.
            // Emit no chunk — the first delta will carry the usage.
            const message = root.object.get("message") orelse return null;
            if (message != .object) return null;
            const usage = message.object.get("usage") orelse return null;
            if (usage != .object) return null;
            if (usage.object.get("input_tokens")) |it| {
                if (it == .integer) self._anthropic_input_tokens = @intCast(it.integer);
            }
            return null;
        }

        var chunk: StreamChunk = .{};

        if (std.mem.eql(u8, event_type, "content_block_start")) {
            const index = root.object.get("index") orelse return null;
            const cb = root.object.get("content_block") orelse return null;
            if (index != .integer or cb != .object) return null;
            const cb_type = cb.object.get("type") orelse return null;
            if (cb_type != .string) return null;
            // Only tool_use blocks need a tool_calls_delta here (text /
            // thinking blocks just carry content deltas — handled below).
            if (!std.mem.eql(u8, cb_type.string, "tool_use")) return null;

            const id_val = cb.object.get("id") orelse return null;
            const name_val = cb.object.get("name") orelse return null;
            if (id_val != .string or name_val != .string) return null;

            const delta_slice = arena.alloc(ToolCallDelta, 1) catch return null;
            delta_slice[0] = .{
                .index = @intCast(index.integer),
                .id = id_val.string,
                .function_name = name_val.string,
            };
            chunk.tool_calls_delta = delta_slice;
        } else if (std.mem.eql(u8, event_type, "content_block_delta")) {
            const index_val = root.object.get("index") orelse return null;
            const delta = root.object.get("delta") orelse return null;
            if (index_val != .integer or delta != .object) return null;
            const index: usize = @intCast(index_val.integer);

            const delta_type = delta.object.get("type") orelse return null;
            if (delta_type != .string) return null;

            if (std.mem.eql(u8, delta_type.string, "text_delta")) {
                const text = delta.object.get("text") orelse return null;
                if (text != .string) return null;
                chunk.content = text.string;
            } else if (std.mem.eql(u8, delta_type.string, "thinking_delta")) {
                const thinking = delta.object.get("thinking") orelse return null;
                if (thinking != .string) return null;
                chunk.reasoning_content = thinking.string;
            } else if (std.mem.eql(u8, delta_type.string, "input_json_delta")) {
                const partial = delta.object.get("partial_json") orelse return null;
                if (partial != .string) return null;
                const delta_slice = arena.alloc(ToolCallDelta, 1) catch return null;
                delta_slice[0] = .{
                    .index = index,
                    .function_arguments = partial.string,
                };
                chunk.tool_calls_delta = delta_slice;
            } else {
                return null; // unknown delta.type — ignore
            }

            // Emit a usage chunk on the FIRST delta so the aggregator sees
            // the cached input_tokens count. Mirrors the OpenAI parser's
            // use of `stream_options.include_usage=true`.
            if (self._anthropic_input_tokens > 0 and !self._anthropic_usage_emitted) {
                chunk.usage = .{
                    .prompt_tokens = self._anthropic_input_tokens,
                    .completion_tokens = 0,
                    .total_tokens = self._anthropic_input_tokens,
                };
                self._anthropic_usage_emitted = true;
            }
        } else if (std.mem.eql(u8, event_type, "message_delta")) {
            const delta = root.object.get("delta") orelse return null;
            if (delta != .object) return null;
            if (delta.object.get("stop_reason")) |sr| {
                if (sr == .string) {
                    chunk.finish_reason = FinishReason.from_str(map_anthropic_stop_reason(sr.string));
                }
            }
            if (root.object.get("usage")) |usage_val| {
                if (usage_val == .object) {
                    if (usage_val.object.get("output_tokens")) |ot| {
                        if (ot == .integer) {
                            chunk.usage = .{
                                .prompt_tokens = self._anthropic_input_tokens,
                                .completion_tokens = @intCast(ot.integer),
                                .total_tokens = self._anthropic_input_tokens + @as(u32, @intCast(ot.integer)),
                            };
                        }
                    }
                }
            }
        } else {
            // message_stop, content_block_stop, ping, anything else — no-op.
            return null;
        }

        return chunk;
    }

    /// Anthropic's stop_reason strings don't match OpenAI's. Map them so
    /// the workflow's finish_reason handling stays provider-agnostic:
    ///   end_turn       → "stop"
    ///   tool_use       → "tool_calls"
    ///   max_tokens     → "length"
    ///   stop_sequence  → "stop"
    ///   refusal        → "content_filter"
    fn map_anthropic_stop_reason(s: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, s, "end_turn")) return "stop";
        if (std.mem.eql(u8, s, "tool_use")) return "tool_calls";
        if (std.mem.eql(u8, s, "max_tokens")) return "length";
        if (std.mem.eql(u8, s, "stop_sequence")) return "stop";
        if (std.mem.eql(u8, s, "refusal")) return "content_filter";
        return null;
    }

    pub fn callStreaming(
        self: *Agent,
        params: AgentCall,
        ctx: ?*anyopaque,
        callback: StreamCallback,
    ) CallError!CallResponse {
        self.log_fmt(.info, "[STREAM START] model={s} | messages={} | tools={} | streaming=true", .{
            self.model, params.messages.len, params.tools.len,
        });

        // Reset per-call Anthropic parser scratch state. The Agent is reused
        // across many calls; without this reset, the second call would see
        // stale input_tokens + a stuck `_usage_emitted` flag.
        self._anthropic_input_tokens = 0;
        self._anthropic_usage_emitted = false;

        // 1. Build JSON body (unchanged from Agent.zig).
        var json_body: []u8 = undefined;
        if (std.mem.eql(u8, self.UrlStyle, "openai")) {
            json_body = self.buildJsonOpenAIRequest(params, true) catch |err| {
                self.log_error("buildJsonRequest", err, null);
                return error.BuildRequestFailed;
            };
        } else if (std.mem.eql(u8, self.UrlStyle, "anthropic")) {
            json_body = self.buildJsonAnthropicRequest(params, true) catch |err| {
                self.log_error("buildJsonAnthropicRequest", err, null);
                return error.BuildRequestFailed;
            };
        } else {
            json_body = self.buildJsonOpenAIRequest(params, true) catch |err| {
                self.log_error("buildJsonRequest", err, null);
                return error.BuildRequestFailed;
            };
        }

        defer self.allocator.free(json_body);

        const estimated_tokens = @divFloor(json_body.len + 3, 4);
        self.log_fmt(.info, "[TOKEN ESTIMATE] sending ~{} tokens ({} bytes)", .{ estimated_tokens, json_body.len });

        const json_preview_len = if (json_body.len > 500) 500 else json_body.len;
        const json_ellipsis = if (json_body.len > 500) "..." else "";
        self.log_fmt(.debug, "[STREAM REQUEST] JSON body ({} bytes): {s}{s}", .{ json_body.len, json_body[0..json_preview_len], json_ellipsis });

        // 2. Compose URL: baseUrl + endpoint.
        // Anthropic's correct API path is /v1/messages.
        const endpoint = if (std.mem.eql(u8, self.UrlStyle, "anthropic"))
            "/v1/messages"
        else
            "/chat/completions";
        const uri_str = std.mem.concat(self.allocator, u8, &.{ self.baseUrl, endpoint }) catch |err| {
            self.log_error("concat URI", err, null);
            return error.OutOfMemory;
        };
        defer self.allocator.free(uri_str);

        // Validate the URL scheme BEFORE handing it to libcurl. libcurl
        // returns CURLE_UNSUPPORTED_PROTOCOL (LocalError.UnsupportedProtocol)
        // for any URL it can't parse a scheme out of — which surfaces to
        // the workflow as `scanner.next failed ...: UnsupportedProtocol`
        // with no hint about *why*. Catching it here lets us name the
        // actual misconfiguration (empty base_url, missing scheme, typo
        // like "htttps://") instead of forcing the user to dig through
        // libcurl docs.
        const has_http_scheme = std.mem.startsWith(u8, uri_str, "http://") or
            std.mem.startsWith(u8, uri_str, "https://");
        if (!has_http_scheme) {
            const detail = std.fmt.allocPrint(
                self.allocator,
                "baseUrl+endpoint={s} has no http:// or https:// scheme — check api_key/model/base_url in config",
                .{uri_str},
            ) catch null;
            if (detail) |d| {
                if (self.last_error_message) |prev| self.allocator.free(prev);
                self.last_error_message = d;
            }
            self.log_fmt(.err, "[STREAM] unsupported URL scheme (must start with http:// or https://): {s}", .{uri_str});
            return error.InvalidUri;
        }

        // 3. Compose auth header.
        const auth_value = std.mem.concat(self.allocator, u8, &.{ "Bearer ", self.apiKey }) catch |err| {
            self.log_error("concat auth", err, null);
            return error.OutOfMemory;
        };
        defer self.allocator.free(auth_value);

        // 4. Build the custom_http_client.Request.
        const headers = [_]custom_http_client.Header{
            .{ .name = "authorization", .value = auth_value },
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "accept-encoding", .value = "identity" },
        };
        const req = custom_http_client.Request{
            .method = .POST,
            .url = uri_str,
            .headers = &headers,
            .body = json_body,
        };

        // 5. Build Options. Standard libcurl timeouts — no custom watchdog.
        // CURLOPT_TIMEOUT_MS covers the total deadline; libcurl will fire it
        // when the server stalls without sending bytes.
        const options = custom_http_client.Options{
            .timeout_ms = self.httpOptions.read_timeout_ms,
            .connect_timeout_ms = 30_000,
            .follow_redirects = false,
            .verify_ssl = true,
        };

        // 6. Open the streaming request.
        var stream = self.client.openStream(self.io, req, options) catch |err| {
            self.log_fmt(.err, "[STREAM] openStream failed: {s}", .{@errorName(err)});
            return error.HttpRequestFailed;
        };
        defer stream.deinit();

        const status = stream.statusCode();
        self.log_fmt(.info, "[STREAM] Connected with HTTP {d}", .{status});

        if (status >= 400) {
            self.log_fmt(.err, "[STREAM] HTTP error status: {d}", .{status});
            // Drain the error body so the workflow catch block can log the
            // server's actual reason (rate limit, auth, model not found,
            // context length, etc.) instead of just `error.ApiError`. Cap at
            // 4 KiB to avoid blowing up logs on a runaway server response;
            // truncated payloads get a trailing "..." marker.
            var body_buf: std.ArrayList(u8) = .empty;
            defer body_buf.deinit(self.allocator);
            const max_body_len: usize = 4096;
            drain_loop: while (body_buf.items.len < max_body_len) {
                const next_chunk = stream.next() catch break :drain_loop;
                if (next_chunk) |chunk| {
                    const remaining = max_body_len - body_buf.items.len;
                    const to_copy = @min(chunk.len, remaining);
                    body_buf.appendSlice(self.allocator, chunk[0..to_copy]) catch break :drain_loop;
                    if (chunk.len > to_copy) break :drain_loop;
                } else break :drain_loop;
            }
            const truncated = body_buf.items.len >= max_body_len;
            if (body_buf.items.len > 0) {
                const msg = std.fmt.allocPrint(
                    self.allocator,
                    "HTTP {d}: {s}{s}",
                    .{ status, body_buf.items, if (truncated) "..." else "" },
                ) catch null;
                if (msg) |m| {
                    if (self.last_error_message) |prev| self.allocator.free(prev);
                    self.last_error_message = m;
                }
            }
            return error.ApiError;
        }

        // 7. SSE scanner for line-by-line reads.
        var scanner = custom_http_client.StreamScanner.init(&stream, false);
        defer scanner.deinit();

        // 8. Aggregator.
        var aggregator = StreamingAggregator.init(self.allocator);
        defer aggregator.deinit();

        var line_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer line_arena.deinit();

        // Raw SSE sample buffer. Populated when parse_stream_chunk returns null
        // AND chunk_count stays at 0 — lets us surface the server's actual
        // payload in the StreamInterrupted error message instead of hiding
        // everything behind "0 chunk(s)". Capped at 2 KiB; we keep the FIRST
        // bytes so the user sees the start of the stream (auth errors and
        // framework-specific envelopes tend to appear there).
        var raw_sse_sample: std.ArrayList(u8) = .empty;
        defer raw_sse_sample.deinit(self.allocator);
        const max_raw_sse_sample_len: usize = 2048;

        var chunk_count: usize = 0;
        var stream_ended_cleanly = false;

        // 9. SSE loop. The scanner's inferred error set is wider than
        // CallError (it includes libcurl's LocalError variants like
        // DnsError / TlsError / OperationTimedOut), so we use a
        // `catch` that maps any scanner error to a CallError variant
        // and returns — instead of `try`, which would fail to propagate
        // errors outside CallError.
        //
        // `scanner.next()` can return null for two reasons:
        //   (a) the worker has finished cleanly (clean EOF); or
        //   (b) the polling budget elapsed without a chunk arriving.
        // `StreamScanner` does NOT distinguish the two — both return
        // null. Reasoning-model LLMs (Claude extended thinking, OpenAI
        // o1/o3, DeepSeek R1) routinely pause 30-60s+ between chunks,
        // so a polling-budget return would otherwise produce a spurious
        // `StreamInterrupted` on a healthy stream.
        //
        // Mitigations:
        //   - `custom_http_client.StreamScanner.next()` was bumped from
        //     5s to 300s in commit `…` (matches libcurl's
        //     CURLOPT_TIMEOUT_MS) — fixes the common case.
        //   - This loop treats a null as "give the worker one more
        //     chance" — call next() again. If the worker has truly
        //     finished, the second call returns null immediately. If
        //     the worker is still going, the second call blocks until
        //     the next chunk or the libcurl timeout.
        var scanner_null_count: u32 = 0;
        while (true) {
            const next_result = scanner.next() catch |err| {
                self.log_fmt(.err, "[STREAM] scanner.next failed: {s}", .{@errorName(err)});
                // Surface the underlying scanner error name to the workflow
                // catch block so it can tell apart a parse failure from a
                // network drop from an EOF mid-line, instead of all collapsing
                // into "StreamInterrupted". Special-case `UnsupportedProtocol`
                // when the URL was https:// — the vendored libcurl in
                // src/modules/custom_http_client/vendor/curl/ is built with
                // --disable-ssl (see scripts/build-vendor-curl.sh:8-18), so
                // the only way an https URL produces CURLE_UNSUPPORTED_PROTOCOL
                // is that the vendored libcurl literally doesn't know the
                // scheme. A bare `UnsupportedProtocol` is otherwise opaque.
                const detail: ?[]u8 = if (err == error.UnsupportedProtocol and
                    std.mem.startsWith(u8, uri_str, "https://"))
                std.fmt.allocPrint(
                    self.allocator,
                    "scanner.next failed after {d} chunk(s): UnsupportedProtocol — vendored libcurl was built --disable-ssl (see custom_http_client/scripts/build-vendor-curl.sh); URL must be http:// until OpenSSL is vendored, or change base_url in ~/.config/nalar/config.json to an http:// endpoint",
                    .{chunk_count},
                ) catch null
                else
                    std.fmt.allocPrint(
                        self.allocator,
                        "scanner.next failed after {d} chunk(s): {s}",
                        .{ chunk_count, @errorName(err) },
                    ) catch null;
                if (detail) |d| {
                    if (self.last_error_message) |prev| self.allocator.free(prev);
                    self.last_error_message = d;
                }
                return error.StreamInterrupted;
            };
            if (next_result) |line| {
                scanner_null_count = 0;
                if (self.parse_sse_line(line)) |data| {
                    _ = line_arena.reset(.retain_capacity);
                    if (self.parse_stream_chunk(data, line_arena.allocator())) |chunk| {
                        chunk_count += 1;
                        callback(ctx, chunk);
                        aggregator.process_chunk(chunk) catch {};
                    } else {
                        self.log_fmt(.err, "[STREAM] parse_stream_chunk returned null for: {s}", .{data});
                        // Capture the raw SSE data line for the final-error
                        // message — only while chunk_count == 0 (i.e. the
                        // server's first lines are still unparsed). Once we
                        // successfully parse ANY chunk we know the format
                        // is one we understand, so additional raw samples
                        // would just be noise.
                        if (chunk_count == 0 and raw_sse_sample.items.len < max_raw_sse_sample_len) {
                            raw_sse_sample.appendSlice(self.allocator, data) catch {};
                            raw_sse_sample.append(self.allocator, '\n') catch {};
                        }
                    }
                } else {
                    // parse_sse_line returned null: this line isn't a `data: …`
                    // payload. Could be `event: …` (Anthropic) or `id:`/`retry:`
                    // (SSE boilerplate) or — more importantly for diagnosis —
                    // a non-SSE response the server returned anyway (e.g. a
                    // 404 HTML body when the URL was wrong). Capture the full
                    // raw line so the final error message reveals the actual
                    // server output, not just "0 chunk(s)".
                    if (chunk_count == 0 and raw_sse_sample.items.len < max_raw_sse_sample_len) {
                        raw_sse_sample.appendSlice(self.allocator, line) catch {};
                        raw_sse_sample.append(self.allocator, '\n') catch {};
                    }
                }
                continue;
            }
            // next() returned null. The worker MIGHT have finished
            // (clean EOF) OR the polling budget might have elapsed
            // (worker still going). One more call lets us tell apart
            // the two: a clean EOF returns null immediately on the
            // second call, a polling timeout blocks until the next
            // chunk. We cap at 2 nulls in a row to be defensive —
            // if the second call also returns null, the worker
            // definitely finished.
            scanner_null_count += 1;
            if (scanner_null_count >= 2) break;
        }

        // 10. The scanner returned null twice in a row, which means
        // the worker has definitively finished (clean EOF) without
        // sending a finish_reason chunk. Treat as a mid-stream death.
        if (aggregator.finish_reason == null) {
            self.log_fmt(.err, "[STREAM] stream ended without finish_reason (chunks={})", .{chunk_count});
            // Tell the workflow catch block HOW the stream died and roughly
            // how far it got, so the user can distinguish "the server cut
            // us off after a few tokens" from "it never started streaming
            // at all" — both surface as StreamInterrupted today.
            //
            // When chunk_count stayed at 0 BUT we received SOME SSE lines,
            // the server is speaking a format we don't understand (most
            // commonly: a profile configured with the wrong `url_style`,
            // e.g. an OpenAI-compatible relay configured as `anthropic`).
            // In that case we fold a truncated raw sample into the error
            // message so the user can SEE what the server actually sent,
            // instead of staring at an opaque "0 chunk(s)".
            const sample_truncated = raw_sse_sample.items.len >= max_raw_sse_sample_len;
            const sample_for_msg: []const u8 = if (raw_sse_sample.items.len > 0)
                if (sample_truncated)
                    raw_sse_sample.items[0 .. max_raw_sse_sample_len - 3] ++ "..."
                else
                    raw_sse_sample.items
            else
                "";
            const detail: ?[]u8 = if (sample_for_msg.len > 0)
                std.fmt.allocPrint(
                    self.allocator,
                    "stream ended without finish_reason after {d} chunk(s); first server lines: {s}",
                    .{ chunk_count, sample_for_msg },
                ) catch null
            else
                std.fmt.allocPrint(
                    self.allocator,
                    "stream ended without finish_reason after {d} chunk(s)",
                    .{chunk_count},
                ) catch null;
            if (detail) |d| {
                if (self.last_error_message) |prev| self.allocator.free(prev);
                self.last_error_message = d;
            }
            return error.StreamInterrupted;
        }
        stream_ended_cleanly = true;

        callback(ctx, .{ .done = true });

        // 11. Finalize.
        const stream_response = aggregator.finalize() catch |err| {
            self.log_error("finalize streaming response", err, null);
            return error.AllocFailed;
        };

        // 12. Cost tracking (matches Agent.zig's pricing).
        const prompt_cost = @as(f64, @floatFromInt(stream_response.usage.prompt_tokens)) * 0.000003;
        const completion_cost = @as(f64, @floatFromInt(stream_response.usage.completion_tokens)) * 0.000015;
        const total_cost = prompt_cost + completion_cost;
        self.log_fmt(.info, "[STREAM] Complete - Prompt: {} | Completion: {} | Total: {} | Est. cost: ${d:.4}", .{
            stream_response.usage.prompt_tokens,
            stream_response.usage.completion_tokens,
            stream_response.usage.total_tokens,
            total_cost,
        });

        return stream_response;
    }

    pub fn deinit(self: *Agent) void {
        if (self.last_error_message) |msg| {
            self.allocator.free(msg);
            self.last_error_message = null;
        }
        self.client.deinit();
    }
};
