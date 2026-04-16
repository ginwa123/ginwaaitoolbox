const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const sqlite = tree1_mod.sqlite;
const http_server = @import("nalarcore").http_server;
const logger = @import("nalarcore").logger;

// ============================================================================
// JSON Protocol Constants
// ============================================================================
// Note: All buffers are dynamic using heap allocation via std.ArrayList(u8).
// No fixed size limits for chunk content or tool call deltas.

// ============================================================================
// Unified Response Types
// ============================================================================

/// Response type discriminator
pub const ResponseType = enum {
    assistant_response,
    err,
    tool_result,
    user_choice,
};

/// Unified response structure holding all optional fields
pub const Response = struct {
    content: ?[]const u8 = null,
    finish_reason: ?agent.FinishReason = null,
    override_finish_reason: ?[]const u8 = null,
    reasoning_content: ?[]const u8 = null,
    usage: agent.Usage = .{ .prompt_tokens = 0, .completion_tokens = 0, .total_tokens = 0 },
    err_msg: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    tool_result: ?[]const u8 = null,
    command: ?[]const u8 = null,
};

/// Input parameters for sending SSE events
/// Used by TUI workflow to broadcast messages to connected clients
pub const OnEventInput = struct {
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    content: ?[]const u8,
    reasoning_content: ?[]const u8,
    role: ?[]const u8,
    finish_reason: ?[]const u8,
    tool_calls: ?[]agent.ToolCall,
    tool_call_id: ?[]const u8,
    tool_name: ?[]const u8 = null,
    agent_name: ?[]const u8,
    loop_index: u32,
    temperature: f32,
    is_thinking: bool,
    is_input: bool = false,
    is_output: bool = false,
    parent_session_id: ?[]const u8 = null,
    parent_id: ?[]const u8 = null,
};

/// JSON event payload structure for SSE
pub const SseEventPayload = struct {
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    content: ?[]const u8 = null,
    reasoning_content: ?[]const u8 = null,
    role: []const u8 = "assistant",
    finish_reason: ?[]const u8 = null,
    tool_calls: ?[]const ToolCallJson = null,
    tool_call_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    agent_name: ?[]const u8 = null,
    loop_index: u32,
    temperature: f32,
    is_thinking: bool,
    is_input: bool,
    is_output: bool,
    parent_session_id: ?[]const u8 = null,
    parent_id: ?[]const u8 = null,
};

/// JSON representation of a tool call
pub const ToolCallJson = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

/// Send an SSE event to all clients connected to the given session
///
/// JSON Protocol:
/// - Response events contain all message fields as JSON object
/// - Tool result events include tool_call_id and tool_name
pub fn on_event_send_new(allocator: std.mem.Allocator, input: OnEventInput) !void {
    const log = logger.getGlobal();
    const session_id = input.session_id;

    const sse_manager = http_server.getGlobalSseManager() orelse {
        log.?.warnFmt("on_event_send_new[{s}]: no SSE manager available", .{session_id}) catch {};
        return;
    };

    // Trace: log what content we're receiving
    if (input.content) |c| {
        // Truncate content for logging if too long (>500 chars)
        const truncated_content = if (c.len > 500) c[0..500] else c;
        const suffix = if (c.len > 500) "... [truncated]" else "";
        log.?.infoFmt("on_event_send_new[{s}]: content=\"{s}{s}\", len={d}, is_thinking={}, role={s}", .{
            session_id,
            truncated_content,
            suffix,
            c.len,
            input.is_thinking,
            input.role orelse "assistant",
        }) catch {};
    } else {
        log.?.warnFmt("on_event_send_new[{s}]: NO CONTENT!", .{session_id}) catch {};
    }

    // Build tool_calls JSON array if present
    var tool_calls_json: ?[]const ToolCallJson = null;
    var tool_calls_owned: std.ArrayList(ToolCallJson) = .empty;
    defer if (tool_calls_json == null) tool_calls_owned.deinit(allocator);

    if (input.tool_calls) |calls| {
        for (calls) |call| {
            try tool_calls_owned.append(allocator, .{
                .id = call.id,
                .name = call.function.name,
                .arguments = call.function.arguments,
            });
        }
        tool_calls_json = try tool_calls_owned.toOwnedSlice(allocator);
    }

    const payload = SseEventPayload{
        .session_id = input.session_id,
        .model = input.model,
        .cwd = input.cwd,
        .content = input.content,
        .reasoning_content = input.reasoning_content,
        .role = input.role orelse "assistant",
        .finish_reason = input.finish_reason,
        .tool_calls = tool_calls_json,
        .tool_call_id = input.tool_call_id,
        .tool_name = input.tool_name,
        .agent_name = input.agent_name,
        .loop_index = input.loop_index,
        .temperature = input.temperature,
        .is_thinking = input.is_thinking,
        .is_input = input.is_input,
        .is_output = input.is_output,
        .parent_session_id = input.parent_session_id,
        .parent_id = input.parent_id,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    // Use std.json.fmt with format writer
    try buf.writer(allocator).print("{f}", .{std.json.fmt(payload, .{
        .whitespace = .indent_tab,
    })});

    log.?.debugFmt("on_event_send_new[{s}]: buf prepared, size={d}, body={s}", .{
        session_id,
        buf.items.len,
        buf.items,
    }) catch {};

    const event = http_server.SseEvent{
        .data = buf.items,
    };

    log.?.debugFmt("on_event_send_new[{s}]: event created, data_ptr=0x{x}, data_len={d}", .{
        session_id,
        @intFromPtr(event.data.ptr),
        event.data.len,
    }) catch {};

    try sse_manager.enqueueEvent(input.session_id, event);

    log.?.infoFmt("on_event_send_new[{s}]: event enqueued successfully", .{session_id}) catch {};
}

// ============================================================================
// Structured Chunk Types for Streaming
// ============================================================================

/// Structured representation of a content chunk
pub const ContentChunk = struct {
    index: usize,
    content: []const u8,
};

/// Structured representation of a reasoning chunk
pub const ReasoningChunk = struct {
    index: usize,
    reasoning: []const u8,
};

/// Structured representation of usage information
pub const ChunkUsage = struct {
    prompt_tokens: u32,
    completion_tokens: u32,
    total_tokens: u32,
};

/// Structured representation of a final chunk with usage
pub const FinalChunk = struct {
    index: usize,
    usage: ?ChunkUsage,
};

/// Structured representation of a tool call delta
pub const ToolCallDeltaChunk = struct {
    index: usize,
    deltas: []const agent.ToolCallDelta,
};

// ============================================================================
// Structured Serialization Functions (JSON)
// ============================================================================

/// JSON structure for content chunk
const ContentChunkJson = struct {
    index: usize,
    content: []const u8,
    @"type": []const u8 = "chunk",
};

/// JSON structure for reasoning chunk
const ReasoningChunkJson = struct {
    index: usize,
    reasoning_content: []const u8,
    @"type": []const u8 = "reasoning_chunk",
};

/// JSON structure for final chunk with usage
const FinalChunkJson = struct {
    index: usize,
    @"type": []const u8 = "chunk_final",
    finish_reason: []const u8 = "stop",
    usage: ?ChunkUsage = null,
};

/// JSON structure for tool call delta chunk
const ToolCallDeltaChunkJson = struct {
    index: usize,
    @"type": []const u8 = "tool_call_delta",
    deltas: []const agent.ToolCallDelta,
};

/// Serialize a content chunk to JSON format
pub fn serializeContentChunk(allocator: std.mem.Allocator, chunk: ContentChunk) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const json_chunk = ContentChunkJson{
        .index = chunk.index,
        .content = chunk.content,
    };

    try buf.writer(allocator).print("{f}", .{std.json.fmt(json_chunk, .{
        .whitespace = .indent_tab,
    })});

    return try buf.toOwnedSlice(allocator);
}

/// Serialize a reasoning chunk to JSON format

pub fn serializeReasoningChunk(allocator: std.mem.Allocator, chunk: ReasoningChunk) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const json_chunk = ReasoningChunkJson{
        .index = chunk.index,
        .reasoning_content = chunk.reasoning,
    };

    try buf.writer(allocator).print("{f}", .{std.json.fmt(json_chunk, .{
        .whitespace = .indent_tab,
    })});

    return try buf.toOwnedSlice(allocator);
}

/// Serialize a final chunk with usage information

pub fn serializeFinalChunk(allocator: std.mem.Allocator, chunk: FinalChunk) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const json_chunk = FinalChunkJson{
        .index = chunk.index,
        .usage = chunk.usage,
    };

    try buf.writer(allocator).print("{}", .{std.json.fmt(json_chunk, .{
        .whitespace = .indent_tab,
    })});

    return try buf.toOwnedSlice(allocator);
}

/// Serialize tool call deltas to JSON format
pub fn serializeToolCallDeltas(allocator: std.mem.Allocator, chunk: ToolCallDeltaChunk) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const json_chunk = ToolCallDeltaChunkJson{
        .index = chunk.index,
        .deltas = chunk.deltas,
    };

    try buf.writer(allocator).print("{f}", .{std.json.fmt(json_chunk, .{
        .whitespace = .indent_tab,
    })});

    return try buf.toOwnedSlice(allocator);
}

// ============================================================================
// Streaming helpers (using structured serialization)

// ============================================================================

/// Send content chunk during streaming response
pub fn sendStreamChunkContent(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    chunk: ContentChunk,
) void {
    const sse_manager = http_server.getGlobalSseManager() orelse return;
    const data = serializeContentChunk(allocator, chunk) catch return;
    defer allocator.free(data);

    const event = http_server.SseEvent{
        .data = data,
    };
    sse_manager.enqueueEvent(session_id, event) catch {};
}

/// Send reasoning chunk during streaming response
pub fn sendStreamChunkReasoning(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    chunk: ReasoningChunk,
) void {
    const sse_manager = http_server.getGlobalSseManager() orelse return;
    const data = serializeReasoningChunk(allocator, chunk) catch return;
    defer allocator.free(data);

    const event = http_server.SseEvent{
        .data = data,
    };
    sse_manager.enqueueEvent(session_id, event) catch {};
}

/// Send final chunk with usage information during streaming
pub fn sendStreamChunkFinal(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    chunk: FinalChunk,
) void {
    const sse_manager = http_server.getGlobalSseManager() orelse return;
    const data = serializeFinalChunk(allocator, chunk) catch return;
    defer allocator.free(data);

    const event = http_server.SseEvent{
        .data = data,
    };
    sse_manager.enqueueEvent(session_id, event) catch {};
}

/// Send tool call delta chunk during streaming response
pub fn sendStreamToolCallDelta(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    chunk: ToolCallDeltaChunk,
) void {
    const sse_manager = http_server.getGlobalSseManager() orelse return;
    const data = serializeToolCallDeltas(allocator, chunk) catch return;
    defer allocator.free(data);

    const event = http_server.SseEvent{
        .data = data,
    };
    sse_manager.enqueueEvent(session_id, event) catch {};
}

// ============================================================================
// Tests
// ============================================================================

test {}
