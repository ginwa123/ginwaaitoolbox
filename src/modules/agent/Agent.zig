const std = @import("std");
const builtin = @import("builtin");
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
    url_style: []const u8 = "openai",
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
    httpClient: std.http.Client,
    thinkingEnabled: bool = true,
    allocator: std.mem.Allocator,
    httpOptions: HttpOptions = .{},
    UrlStyle: []const u8 = "openai",

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Agent {
        return Agent{
            .allocator = allocator,
            .httpClient = std.http.Client{ .allocator = allocator, .io = io },
        };
    }

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

    /// Apply TCP keepalive so that dead connections (Wi-Fi drop, server crash
    /// without FIN/RST) are detected by the OS rather than hanging forever.
    ///
    /// With keepidle=10, keepintvl=5, keepcnt=3 the OS detects a dead
    /// connection in ~25s and returns ConnectionResetByPeer from readSliceShort,
    /// which the streaming loop surfaces as StreamInterrupted.
    ///
    /// NOTE: Do NOT use SO_RCVTIMEO with Zig 0.16's std.Io Threaded backend.
    /// The backend treats EAGAIN as a programmer bug and panics. TCP keepalive
    /// is the correct mechanism here.
    fn apply_tcp_keepalive(self: Agent, req: anytype) ?i32 {
        // Windows: std.posix.setsockopt has @compileError("use std.Io instead")
        // on Windows. The full std.Io.Net migration of the streaming sockets
        // is a larger follow-up; for now we skip keepalive on Windows, which
        // means the watchdog does not spawn and stall-detection falls back to
        // TCP's default ~2h timeout. The connection still works.
        if (builtin.os.tag == .windows) return null;

        const conn = req.connection orelse {
            self.log_msg(.warn, "[STREAM] cannot set TCP keepalive: no connection");
            return null;
        };
        const sock = conn.stream_reader.stream.socket.handle;

        const on: c_int = 1;
        std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.KEEPALIVE,
            std.mem.asBytes(&on)) catch |err| {
            self.log_fmt(.warn, "[STREAM] SO_KEEPALIVE failed: {s}", .{@errorName(err)});
            return sock;
        };

        // First keepalive probe after 10s of idle. `TCP.KEEPIDLE`
        // is Linux-only; on macOS the equivalent is to set the
        // `KEEPALIVE` option (which doubles as the idle timer on
        // Darwin). Skip the idle config on macOS — the 5s probe
        // interval + 3 probes already detects a dead connection
        // quickly using the default ~2h idle.
        if (builtin.os.tag == .linux) {
            const keepidle: c_int = 10;
            std.posix.setsockopt(sock, std.posix.IPPROTO.TCP, std.posix.TCP.KEEPIDLE,
                std.mem.asBytes(&keepidle)) catch {};
        }

        // Probe every 5s
        const keepintvl: c_int = 5;
        std.posix.setsockopt(sock, std.posix.IPPROTO.TCP, std.posix.TCP.KEEPINTVL,
            std.mem.asBytes(&keepintvl)) catch {};

        // Give up after 3 failed probes (~25s total to detect dead connection)
        const keepcnt: c_int = 3;
        std.posix.setsockopt(sock, std.posix.IPPROTO.TCP, std.posix.TCP.KEEPCNT,
            std.mem.asBytes(&keepcnt)) catch {};

        self.log_fmt(.debug, "[STREAM] TCP keepalive set: idle=10s, intvl=5s, cnt=3 (detects dead conn in ~25s)", .{});
        return sock;
    }

    /// Background thread that force-closes the stream socket when the read
    /// loop stalls. Works around the std.Io.Threaded "parked in recv()" problem:
    /// the user-space deadline checks in the read loop never fire while the
    /// worker is blocked in the kernel. The watchdog calls shutdown(SHUT_RD)
    /// on the socket from outside the Io runtime, which (per Linux shutdown(2)
    /// man page) "may" unblock a pending recv; the watchdog then also dup2's
    /// the socket fd to /dev/null so the Io runtime's later close() succeeds
    /// (no EBADF / no panic).
    ///
    /// close() alone would also unblock the recv but causes a "use after free"
    /// panic in std.Io.Threaded.closeFd when the Io runtime later closes the
    /// already-closed fd. The dup2 trick leaves the fd NUMBER valid (pointing
    /// to /dev/null) so the later close() succeeds.
    ///
    /// This watchdog is purely additive — keepalive (above) remains as a slower
    /// secondary defense for cases where the watchdog itself is delayed.
    const StreamWatchdog = struct {
        /// shutdown(2) "how" constants on Linux.
        ///   SHUT_RD   = 0  (further receives disallowed; may unblock recv)
        ///   SHUT_WR   = 1
        ///   SHUT_RDWR = 2
        const SHUT_RD: i32 = 0;
        fd: std.atomic.Value(i32), // -1 when cancelled; the live socket fd otherwise
        last_byte_ms: std.atomic.Value(i64), // wall-clock ms of last received byte
        cancel: std.atomic.Value(bool), // set by main thread on exit
        fired_for: std.atomic.Value(u8), // 0=none, 1=idle, 2=max_total
        thread: std.Thread,
        start_ms: i64,
        idle_timeout_ms: i64,
        max_total_ms: i64,

        const Reason = enum(u8) { none = 0, idle = 1, max_total = 2 };

        fn threadMain(wd: *StreamWatchdog) void {
            while (true) {
                // `std.os.windows.kernel32.Sleep` was removed from the Zig 0.16
                // stdlib (verified: 0 hits for `Sleep` in
                // /usr/local/lib/zig/std/os/windows/kernel32.zig). The
                // helpers.sleepMillis wrapper handles the per-platform sleep
                // call (POSIX `nanosleep` on Linux/macOS, kernel32.Sleep on
                // Windows) without requiring an `io: std.Io` runtime.
                helpers.sleepMillis(250);
                if (wd.cancel.load(.acquire)) return;
                const fd_now = wd.fd.load(.acquire);
                if (fd_now < 0) return; // main thread reset fd
                const now = wallClockMs();
                if (now - wd.start_ms >= wd.max_total_ms) {
                    wd.fired_for.store(@intFromEnum(Reason.max_total), .release);
                    forceCancel(fd_now);
                    return;
                }
                if (now - wd.last_byte_ms.load(.acquire) >= wd.idle_timeout_ms) {
                    wd.fired_for.store(@intFromEnum(Reason.idle), .release);
                    forceCancel(fd_now);
                    return;
                }
            }
        }

        /// Cancel the in-flight recv by atomically replacing the socket fd
        /// with /dev/null via dup2(2). This:
        ///   1. Closes the underlying TCP socket (kernel sends FIN, recv returns).
        ///   2. Leaves the fd NUMBER valid in the process (now pointing to /dev/null).
        ///   3. The Io runtime's later close() on this fd closes the /dev/null
        ///      reference harmlessly — no "use after free" / EBADF panic.
        ///
        /// Why not just close()? The Io runtime stores the original socket fd
        /// in its Connection struct and calls close() on it during deinit.
        /// If we close() it first, the runtime's close returns EBADF which
        /// std.Io.Threaded's closeFd treats as a programmer bug and panics
        /// (recoverableOsBugDetected → unreachable in debug).
        ///
        /// Why not just shutdown(SHUT_RDWR)? The shutdown() syscall sends FIN
        /// to the peer but does NOT unblock a recv() that's already in
        /// progress on the local side (the kernel is waiting for data, not
        /// for the peer's FIN). The local recv would remain stuck.
        fn forceCancel(fd_now: i32) void {
            // This function uses Linux-only syscalls (shutdown, dup2, open /dev/null)
            // to force-cancel a blocked recv. On Windows, these syscalls are not
            // available. The stream watchdog is a best-effort mechanism; on Windows
            // we rely on TCP keepalive and the Io runtime's timeout instead.
            if (builtin.os.tag != .linux) return;

            // Two-pronged approach: shutdown(SHUT_RD) "may" unblock the pending
            // recv on Linux (per shutdown(2) man page). If it doesn't, the
            // dup2-to-/dev/null trick replaces the socket fd with /dev/null so
            // the Io runtime's later close() succeeds (no EBADF / no panic).
            // Together, they cover both:
            //   - The recv that may return when the socket's read side is shut down.
            //   - The Io's later close() that must not see a closed fd.
            //
            // Why we can't just close() the socket:
            //   std.Io.Threaded treats close() on a bad fd as a programmer bug
            //   and panics in debug. The dup2 leaves the fd NUMBER valid
            //   (now pointing to /dev/null) so the later close() succeeds.
            _ = std.os.linux.shutdown(fd_now, SHUT_RD);

            const devnull_rc = std.os.linux.open("/dev/null", .{}, 0);
            if (devnull_rc > std.math.maxInt(i32)) return;
            const devnull_fd: i32 = @intCast(devnull_rc);
            const dup2_rc = std.os.linux.dup2(devnull_fd, fd_now);
            if (dup2_rc > std.math.maxInt(i32)) {
                _ = std.os.linux.close(devnull_fd);
                return;
            }
            _ = std.os.linux.close(devnull_fd);
        }

        fn wallClockMs() i64 {
            if (builtin.os.tag == .windows) {
                // NOTE: this is wall-clock seconds × 1000 (epoch = 1970-01-01).
                // The POSIX branch below uses CLOCK_MONOTONIC (epoch = boot
                // time on Linux), so the two paths have different epochs and
                // ARE NOT COMPARABLE across processes. We preserve the
                // pre-existing behavior here for the Windows build (which
                // never compiled before this fix); the difference is
                // negligible for the StreamWatchdog's relative-time
                // accounting — both clocks increase monotonically.
                return @import("../../helpers/mod.zig").unixTimestamp() * 1000;
            } else {
                // CLOCK_MONOTONIC is a POSIX thing. std.c.clock_gettime
                // cannot be referenced on Windows in Zig 0.16 (clockid_t is
                // void there), so we declare our own extern in helpers/mod.zig
                // and use it here.
                //
                // CLOCK_MONOTONIC = 1 works on Linux glibc but returns
                // EINVAL on macOS arm64 (the Darwin kernel routes that
                // clock ID differently — it expects CLOCK_UPTIME_RAW = 8
                // for the "seconds since boot" semantic). The unchecked
                // `_ =` was masking the failure, leaving ts uninitialized
                // and producing a garbage `sec * 1000` that overflowed i64.
                // Probe CLOCK_MONOTONIC first; on EINVAL, retry with
                // CLOCK_UPTIME_RAW (8). Both clocks increase monotonically,
                // so the StreamWatchdog's relative-time accounting is
                // unaffected by the swap.
                var ts: helpers.PosixTimespec = undefined;
                if (helpers.clock_gettime(1, &ts) != 0) {
                    _ = helpers.clock_gettime(8, &ts);
                }
                const sec: i64 = @intCast(ts.sec);
                return sec * 1000 + @divFloor(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
            }
        }
    };

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
                defer arena_alloc.free(content_blocks);

                if (msg.reasoning_content) |rc| {
                    content_blocks = try arena_alloc.realloc(content_blocks, content_blocks.len + 1);
                    content_blocks[content_blocks.len - 1] = .{ .text = rc };
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
                        .tool_use = .{
                            .id = tc.id,
                            .name = tc.function.name,
                            .input = input_value,
                        },
                    };
                }

                json_messages[i] = .{
                    .role = "assistant",
                    .content = .{ .array = content_blocks },
                };
            } else if (msg.role == .tool) {
                var tool_content: []AnthropicContentBlock = try arena_alloc.alloc(AnthropicContentBlock, 1);
                tool_content[0] = .{
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

    pub fn callStreaming(
        self: *Agent,
        params: AgentCall,
        ctx: ?*anyopaque,
        callback: StreamCallback,
    ) CallError!CallResponse {
        self.log_fmt(.info, "[STREAM START] model={s} | messages={} | tools={} | streaming=true", .{
            self.model, params.messages.len, params.tools.len,
        });

        var json_body: []u8 = undefined;
        if (std.mem.eql(u8, self.UrlStyle, "openai")) {
            json_body = self.buildJsonOpenAIRequest(params, true) catch |err| {
                self.log_error("buildJsonRequest", err, null);
                return error.BuildRequestFailed;
            };
        } else {
            json_body = self.buildJsonAnthropicRequest(params, true) catch |err| {
                self.log_error("buildJsonAnthropicRequest", err, null);
                return error.BuildRequestFailed;
            };
        }
        defer self.allocator.free(json_body);

        const estimated_tokens = @divFloor(json_body.len + 3, 4);
        self.log_fmt(.info, "[TOKEN ESTIMATE] sending ~{} tokens ({} bytes)", .{ estimated_tokens, json_body.len });

        const json_preview_len = if (json_body.len > 500) 500 else json_body.len;
        const json_ellipsis = if (json_body.len > 500) "..." else "";
        self.log_fmt(.debug, "[STREAM REQUEST] JSON body ({} bytes): {s}{s}", .{ json_body.len, json_body[0..json_preview_len], json_ellipsis });

        const endpoint = if (std.mem.eql(u8, self.UrlStyle, "anthropic")) "/messages" else "/chat/completions";
        const uri_str = std.mem.concat(self.allocator, u8, &.{ self.baseUrl, endpoint }) catch |err| {
            self.log_error("concat URI", err, null);
            return error.OutOfMemory;
        };
        defer self.allocator.free(uri_str);

        const uri = std.Uri.parse(uri_str) catch |err| {
            self.log_fmt(.err, "Failed to parse URI '{s}': {s}", .{ uri_str, @errorName(err) });
            return error.InvalidUri;
        };

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

        // Apply TCP keepalive AFTER sending body, BEFORE receiving head.
        // This detects dead connections (~25s) via ConnectionResetByPeer
        // without triggering the EAGAIN panic that SO_RCVTIMEO causes in
        // Zig 0.16's std.Io Threaded backend.
        const stream_fd_opt = self.apply_tcp_keepalive(&req);

        const stream_start = timestampMs(self.httpClient.io);

        // Spawn the watchdog thread if we got a live socket fd. The watchdog
        // force-closes the fd when idle/max timeouts expire, which forces the
        // Io worker's recv() to return an error and the read loop to exit.
        //
        // IMPORTANT: `watchdog` MUST be in function scope (not inside the
        // if block) so its address stays valid for the spawned thread. The
        // thread runs concurrently with the rest of callStreaming and reads
        // `wd.fd` / `wd.fired_for` etc. via the pointer it received. If `wd`
        // were scoped to the if block, the thread would access a dangling
        // pointer the moment the block exits — the exact bug that caused the
        // watchdog to silently never fire in earlier iterations.
        var watchdog: ?StreamWatchdog = null;
        if (stream_fd_opt) |fd| {
            const now_ms = StreamWatchdog.wallClockMs();
            watchdog = .{
                .fd = std.atomic.Value(i32).init(fd),
                .last_byte_ms = std.atomic.Value(i64).init(now_ms),
                .cancel = std.atomic.Value(bool).init(false),
                .fired_for = std.atomic.Value(u8).init(@intFromEnum(StreamWatchdog.Reason.none)),
                .thread = undefined,
                .start_ms = now_ms,
                .idle_timeout_ms = @intCast(self.httpOptions.idle_timeout_ms),
                .max_total_ms = @intCast(self.httpOptions.read_timeout_ms),
            };
            if (std.Thread.spawn(.{}, StreamWatchdog.threadMain, .{&watchdog.?})) |t| {
                watchdog.?.thread = t;
                self.log_fmt(.debug, "[STREAM] watchdog spawned: fd={d} idle_ms={d} max_ms={d}", .{
                    fd, watchdog.?.idle_timeout_ms, watchdog.?.max_total_ms,
                });
            } else |err| {
                self.log_fmt(.warn, "[STREAM] watchdog thread spawn failed: {s}", .{@errorName(err)});
                watchdog = null;
            }
        }
        // Defer watchdog cleanup. Fires on every exit path (normal and error).
        // Order matters: this fires BEFORE req.deinit() because defer is LIFO.
        // We reset fd to -1 first so the watchdog stops trying to close it,
        // then set cancel, then join.
        defer if (watchdog) |*wd| {
            wd.fd.store(-1, .release);
            wd.cancel.store(true, .release);
            wd.thread.join();
            // Note: we deliberately do NOT translate fired_for back to a
            // CallError variant. If the watchdog fired, the existing read loop
            // error path already returned error.StreamInterrupted (which is
            // semantically correct: the connection died). The exact variant
            // (Idle vs Total) is observable only via the watchdog's atomic
            // fired_for field, which is preserved for debugging.
        };
        var redirect_buffer: [8192]u8 = undefined;
        var response = req.receiveHead(&redirect_buffer) catch |err| {
            self.log_fmt(.err, "[TIMEOUT] No response after {}ms: {s}", .{
                elapsedMs(self.httpClient.io, stream_start), @errorName(err),
            });
            return error.ReceiveFailed;
        };

        const stream_duration = elapsedMs(self.httpClient.io, stream_start);
        const stream_duration_fmt = formatDuration(stream_duration);
        self.log_fmt(.info, "[STREAM] Connected in {}{s} (HTTP {d})", .{
            stream_duration_fmt.value, stream_duration_fmt.unit, @intFromEnum(response.head.status),
        });

        const encoding_str = if (response.head.transfer_encoding == .chunked) "chunked" else "fixed";
        var content_len_buf: [32]u8 = undefined;
        const content_len_str = if (response.head.content_length) |cl|
            std.fmt.bufPrint(&content_len_buf, "{}", .{cl}) catch "?"
        else
            "unknown";
        self.log_fmt(.debug, "[STREAM] Transfer: encoding={s}, content_length={s}, keep_alive={}", .{
            encoding_str, content_len_str, response.head.keep_alive,
        });

        if (response.head.status.class() == .client_error or response.head.status.class() == .server_error) {
            const status_code = @intFromEnum(response.head.status);
            self.log_fmt(.err, "[STREAM] HTTP error status: {d}", .{status_code});
            const transfer_buf = self.allocator.alloc(u8, 4096) catch null;
            if (transfer_buf) |buf| {
                defer self.allocator.free(buf);
                var err_reader = response.request.reader.bodyReader(buf, response.head.transfer_encoding, response.head.content_length);
                const error_body = err_reader.allocRemaining(self.allocator, .unlimited) catch null;
                if (error_body) |body| {
                    defer self.allocator.free(body);
                    self.log_fmt(.err, "[STREAM] Server error response: {s}", .{body});
                }
            }
            return error.ApiError;
        }

        if (!response.request.method.responseHasBody()) {
            self.log_msg(.info, "[STREAM] Response has no body (status code)");
            return CallResponse{ .allocator = self.allocator, .content = "", .tool_calls = null, .finish_reason = null };
        }

        if (response.head.content_length == null and response.head.transfer_encoding != .chunked) {
            self.log_msg(.info, "[STREAM] Response has no body (no content-length, not chunked)");
            return CallResponse{ .allocator = self.allocator, .content = "", .tool_calls = null, .finish_reason = null };
        }

        if (response.head.content_length != null and response.head.content_length.? == 0) {
            self.log_msg(.info, "[STREAM] Response has empty body (content-length=0)");
            return CallResponse{ .allocator = self.allocator, .content = "", .tool_calls = null, .finish_reason = null };
        }

        var aggregator = StreamingAggregator.init(self.allocator);
        defer aggregator.deinit();

        const transfer_buffer = self.allocator.alloc(u8, self.httpOptions.response_buffer_size) catch |err| {
            self.log_error("alloc transfer_buffer", err, null);
            return error.OutOfMemory;
        };
        defer self.allocator.free(transfer_buffer);

        self.log_fmt(.info, "[STREAM] bodyReader called: transfer_encoding={s}, content_length={?}", .{
            if (response.head.transfer_encoding == .chunked) "chunked" else "none",
            response.head.content_length,
        });

        var line_buffer: std.ArrayList(u8) = .empty;
        defer line_buffer.deinit(self.allocator);

        var chunk_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer chunk_arena.deinit();

        var chunk_count: usize = 0;
        var stream_ended_cleanly = false;
        var total_bytes_read: usize = 0;

        const stream_read_deadline_ms: i64 = @intCast(self.httpOptions.read_timeout_ms);
        const stream_idle_deadline_ms: i64 = @intCast(self.httpOptions.idle_timeout_ms);

        // last_byte_at_ms tracks when we last received real data.
        // It is updated AFTER readSliceShort returns with n > 0.
        // The idle check runs AFTER each readSliceShort call, so it can
        // correctly accumulate idle time across blocking syscall durations.
        var last_byte_at_ms: i64 = timestampMs(self.httpClient.io);

        const reader = response.request.reader.bodyReader(
            transfer_buffer,
            response.head.transfer_encoding,
            response.head.content_length,
        );

        const read_buffer = self.allocator.alloc(u8, 8192) catch {
            self.log_msg(.err, "[STREAM] failed to alloc read_buffer");
            return error.OutOfMemory;
        };
        defer self.allocator.free(read_buffer);

        while (true) {
            // Check reader state for clean end BEFORE blocking on read.
            const state_before = response.request.reader.state;
            if (state_before == .ready) {
                stream_ended_cleanly = true;
                self.log_msg(.info, "[STREAM] Reader state is ready, stream ended cleanly");
                break;
            }

            // ---------------------------------------------------------------
            // Block here until data arrives, stream ends, or a transport
            // error occurs (e.g. ConnectionResetByPeer from TCP keepalive).
            //
            // readSliceShort returns:
            //   n > 0          → got data, update idle timer, process bytes
            //   n == 0         → no data yet or stream closing, check state
            //   EndOfStream    → clean close from peer
            //   ReadFailed     → transport error (keepalive detected dead conn)
            // ---------------------------------------------------------------
            const n = reader.readSliceShort(read_buffer[0..]) catch |err| {
                if (err == error.ReadFailed) {
                    // ReadFailed can be raised by TWO distinct layers:
                    //   1. Transport: conn.stream_reader.err (RST/ECONNRESET/EPIPE/etc.)
                    //      set by Io/net.zig when io.vtable.netRead fails.
                    //   2. HTTP protocol: response.request.reader.body_err
                    //      (HttpChunkInvalid / HttpChunkTruncated / HttpHeadersOversize)
                    //      set by chunkedStream / chunkedDiscard in std/http.zig when
                    //      the chunked-encoded body is malformed or the server closed
                    //      cleanly before sending the terminating chunk.
                    // The previous diagnostic only checked (1), so a clean TCP FIN
                    // before any body data was logged as "null underlying" instead of
                    // the real "HttpChunkTruncated" cause. Check BOTH layers.
                    const conn = response.request.connection orelse {
                        self.log_msg(.err, "[STREAM] ReadFailed with no connection");
                        return error.StreamInterrupted;
                    };
                    const http_err_opt: ?std.http.Reader.BodyError =
                        response.request.reader.body_err;
                    const transport_err_opt: ?std.Io.net.Stream.Reader.Error =
                        conn.stream_reader.err;
                    if (http_err_opt) |he| {
                        // HTTP-level error (most common: server sent 200 + chunked
                        // headers, then closed cleanly before sending any chunks →
                        // HttpChunkTruncated). The transport is fine; the response
                        // body is just truncated.
                        self.log_fmt(.err, "[STREAM] http error: {s} (chunks={}, bytes={}, transport={?s})", .{
                            @errorName(he), chunk_count, total_bytes_read,
                            if (transport_err_opt) |t| @errorName(t) else null,
                        });
                    } else if (transport_err_opt) |te| {
                        // Transport-level error (typical: ConnectionResetByPeer
                        // from TCP keepalive detecting a dead conn after ~25s).
                        self.log_fmt(.err, "[STREAM] transport error: {s} (chunks={}, bytes={}, elapsed={}ms)", .{
                            @errorName(te), chunk_count, total_bytes_read,
                            elapsedMs(self.httpClient.io, stream_start),
                        });
                    } else {
                        // Both null is rare — readSliceShort got ReadFailed from
                        // somewhere other than transport or chunked-parser. Log
                        // with the explicit "AND no body_err" wording so future
                        // grep for "null underlying" is unambiguous about which
                        // variant fired.
                        self.log_fmt(.err, "[STREAM] ReadFailed with null transport AND null body_err (chunks={}, bytes={})", .{
                            chunk_count, total_bytes_read,
                        });
                    }
                    // If the watchdog triggered the close, translate the
                    // StreamInterrupted to the more specific timeout variant.
                    // Without this, the caller can't distinguish "kernel
                    // detected dead connection" from "watchdog killed a stall".
                    if (watchdog) |*wd| {
                        switch (wd.fired_for.load(.acquire)) {
                            @intFromEnum(StreamWatchdog.Reason.idle) => return error.StreamIdleTimeout,
                            @intFromEnum(StreamWatchdog.Reason.max_total) => return error.StreamTimeout,
                            else => {},
                        }
                    }
                    return error.StreamInterrupted;
                }
                // EndOfStream: clean close from peer.
                // But if we don't have a finish_reason, the server died unexpectedly
                // mid-stream (no finish event was received before the FIN).
                // This is a transport interruption, not a clean end.
                if (aggregator.finish_reason == null) {
                    self.log_fmt(.err, "[STREAM] EndOfStream without finish_reason (chunks={}, bytes={})", .{
                        chunk_count, total_bytes_read,
                    });
                    return error.StreamInterrupted;
                }
                self.log_msg(.info, "[STREAM] EndOfStream from readSliceShort");
                stream_ended_cleanly = true;
                break;
            };

            // ---------------------------------------------------------------
            // Deadline checks run AFTER readSliceShort returns, not before.
            // This is the key fix: the idle timer accumulates correctly because
            // we measure elapsed time after the blocking call returns, rather
            // than resetting last_byte_at_ms based on when we entered the loop.
            // ---------------------------------------------------------------
            const now_ms = timestampMs(self.httpClient.io);
            const overall_elapsed_ms = now_ms - stream_start;
            const idle_elapsed_ms = now_ms - last_byte_at_ms;

            // Overall stream deadline
            if (overall_elapsed_ms > stream_read_deadline_ms) {
                self.log_fmt(.err, "[STREAM] overall deadline exceeded: {}ms > {}ms (chunks={}, bytes={})", .{
                    overall_elapsed_ms, stream_read_deadline_ms, chunk_count, total_bytes_read,
                });
                return error.StreamTimeout;
            }

            if (n == 0) {
                // No data returned. Check for clean close.
                const state_after = response.request.reader.state;
                if (state_after == .closing or state_after == .ready) {
                    stream_ended_cleanly = true;
                    self.log_msg(.info, "[STREAM] Reader closing/ready with n=0, stream ended cleanly");
                    break;
                }

                // Check idle timeout - this fires if keepalive detected dead conn
                // and readSliceShort keeps returning 0 without an error.
                if (idle_elapsed_ms >= stream_idle_deadline_ms) {
                    self.log_fmt(.err, "[STREAM] idle timeout: {}ms with no data (chunks={}, bytes={})", .{
                        idle_elapsed_ms, chunk_count, total_bytes_read,
                    });
                    return error.StreamIdleTimeout;
                }

                // Brief yield to avoid busy-spinning on n=0.
                std.Io.sleep(self.httpClient.io, .{ .nanoseconds = 50_000 }, .real) catch {};
                continue;
            }

            // Got real data - reset idle timer and accumulate bytes.
            last_byte_at_ms = now_ms;
            if (watchdog) |*wd| wd.last_byte_ms.store(now_ms, .release);
            total_bytes_read += n;
            self.log_fmt(.debug, "[STREAM] read {} bytes (total={})", .{ n, total_bytes_read });

            // Small yield to prevent tight CPU spinning on very fast streams.
            if (n < 64) {
                std.Io.sleep(self.httpClient.io, .{ .nanoseconds = 100_000 }, .real) catch {};
            }

            // Parse bytes into SSE lines.
            for (read_buffer[0..n]) |byte| {
                if (byte == '\n') {
                    if (line_buffer.items.len > 0) {
                        const line = line_buffer.items;
                        if (self.parse_sse_line(line)) |data| {
                            _ = chunk_arena.reset(.retain_capacity);
                            if (self.parse_stream_chunk(data, chunk_arena.allocator())) |chunk| {
                                chunk_count += 1;
                                self.log_fmt(.debug, "[STREAM] chunk #{}: content={}, reasoning={}, tool_calls={}", .{
                                    chunk_count,
                                    if (chunk.content) |c| c.len else 0,
                                    if (chunk.reasoning_content) |r| r.len else 0,
                                    if (chunk.tool_calls_delta) |t| t.len else 0,
                                });
                                callback(ctx, chunk);
                                aggregator.process_chunk(chunk) catch {};
                            } else {
                                self.log_fmt(.err, "[STREAM] parse_stream_chunk returned null for: {s}", .{data});
                            }
                        }
                        line_buffer.clearRetainingCapacity();
                    }
                } else if (byte != '\r') {
                    line_buffer.append(self.allocator, byte) catch {};
                }
            }
        }

        // Process any remaining partial line.
        if (line_buffer.items.len > 0) {
            if (self.parse_sse_line(line_buffer.items)) |data| {
                _ = chunk_arena.reset(.retain_capacity);
                if (self.parse_stream_chunk(data, chunk_arena.allocator())) |chunk| {
                    callback(ctx, chunk);
                    aggregator.process_chunk(chunk) catch {};
                }
            }
        }

        // If the watchdog fired (force-closed the socket), translate to the
        // appropriate timeout variant. The dup2-to-/dev/null trick produces
        // an EOF on the read loop, which would otherwise fall through to
        // StreamEmpty / StreamInterrupted. The user wants to know whether
        // the LLM call was killed by a deadline vs an actual clean end.
        if (watchdog) |*wd| {
            switch (wd.fired_for.load(.acquire)) {
                @intFromEnum(StreamWatchdog.Reason.idle) => {
                    self.log_fmt(.err, "[STREAM] watchdog fired (idle timeout, {d}ms)", .{
                        elapsedMs(self.httpClient.io, stream_start),
                    });
                    return error.StreamIdleTimeout;
                },
                @intFromEnum(StreamWatchdog.Reason.max_total) => {
                    self.log_fmt(.err, "[STREAM] watchdog fired (max total timeout, {d}ms)", .{
                        elapsedMs(self.httpClient.io, stream_start),
                    });
                    return error.StreamTimeout;
                },
                else => {},
            }
        }

        // Enforce clean-end semantics.
        if (!stream_ended_cleanly) {
            if (chunk_count == 0) {
                self.log_fmt(.err, "[STREAM] ended with 0 chunks and no clean-end signal", .{});
                return error.StreamEmpty;
            }
            self.log_fmt(.err, "[STREAM] did not end cleanly: chunks={}, bytes={}, elapsed={}ms", .{
                chunk_count, total_bytes_read, elapsedMs(self.httpClient.io, stream_start),
            });
            return error.StreamInterrupted;
        }

        callback(ctx, .{ .done = true });

        const fr_str = if (aggregator.finish_reason) |fr| fr.to_str() else "incomplete";
        self.log_fmt(.info, "[STREAM] Finalizing: finish_reason={s}, content_len={}, tool_buffers={}", .{
            fr_str, aggregator.content.items.len, aggregator.tool_call_buffers.count(),
        });

        const stream_response = aggregator.finalize() catch |err| {
            self.log_error("finalize streaming response", err, null);
            return error.AllocFailed;
        };

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
        self.httpClient.deinit();
    }
};
