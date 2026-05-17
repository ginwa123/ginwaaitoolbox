const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const sqlite = tree1_mod.sqlite;
const logger = @import("nalarcore").logger;
const models = @import("models.zig");
const gserverz = tree1_mod.gserverz;

// ============================================================================
// Session-to-Client ID mapping for SSE event bus integration
// ============================================================================

// ============================================================================
// JSON Protocol Constants
// ============================================================================
// Note: All buffers are dynamic using heap allocation via std.ArrayList(u8).
// No fixed size limits for chunk content or tool call deltas.

// ============================================================================
// Unified Response Types
// ============================================================================

/// Input parameters for sending SSE events
/// Used by TUI workflow to broadcast messages to connected clients
pub const OnEventInputLLMHistory = struct {
    index: usize = 0,
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
    total_tokens: ?u32 = null,
    diffview_before: ?[]const u8 = null,
    diffview_after: ?[]const u8 = null,
};

/// JSON event payload structure for SSE
pub const SseEventLLMHistory = struct {
    index: ?usize = null,
    content: []const u8,
    type: []const u8 = "full",
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
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
    total_tokens: ?u32 = null,
    diffview_before: ?[]const u8 = null,
    diffview_after: ?[]const u8 = null,
};

/// JSON representation of a tool call
pub const ToolCallJson = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

/// Input parameters for sending SSE session events
/// Reflects the sessions table columns: id, name, status, cwd, created_at, updated_at
pub const OnEventInputSessions = struct {
    action: []const u8, // "created", "updated", "deleted"
    id: []const u8,
    name: []const u8,
    status: []const u8,
    cwd: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

/// JSON event payload for SSE session events
pub const SseEventSessionsPayload = struct {
    action: []const u8,
    session_id: ?[]const u8 = null,
};

pub const SseEvent = struct {
    session_id: []const u8,
    data: []const u8,
    event_type: ?[]const u8 = null,
};

/// Send an SSE event to all clients connected to the given session
///
/// JSON Protocol:
/// - Response events contain all message fields as JSON object
/// - Tool result events include tool_call_id and tool_name
pub fn onEventSendLLMHistory(allocator: std.mem.Allocator, input: OnEventInputLLMHistory) !void {

    // todo dirty code
    const di = try tree1_mod.getSingleton();
    const event_bus = di.event_bus;

    const log = logger.getGlobal();
    const session_id = input.session_id;

    // Trace: log what content we're receiving
    if (input.content) |c| {
        // Truncate content for logging if too long (>500 chars)
        const truncated_content = if (c.len > 500) c[0..500] else c;
        const suffix = if (c.len > 500) "... [truncated]" else "";
        log.?.infoFmt("on_event_send_new[{s}]: content=\"{s}{s}\", len={d}, is_thinking={}, role={s}", .{ session_id,
            truncated_content,
            suffix,
            c.len,
            input.is_thinking,
            input.role orelse "assistant",
        });
    } else {
        log.?.warnFmt("on_event_send_new[{s}]: NO CONTENT!", .{session_id});
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

    const payload = SseEventLLMHistory{
        .index = input.index,
        .content = input.content orelse "",
        .session_id = input.session_id,
        .model = input.model,
        .cwd = input.cwd,
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
        .total_tokens = input.total_tokens,
        .diffview_before = input.diffview_before,
        .diffview_after = input.diffview_after,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    // Use std.json.fmt with format writer
    try buf.print(allocator, "{f}", .{std.json.fmt(payload, .{
        .whitespace = .indent_4,
    })});

    // Duplicate the data so event owns its own copy (buf will be deallocated below)
    const data_copy = try allocator.dupe(u8, buf.items);

    const event = SseEvent{
        .session_id = input.session_id,
        .data = data_copy,
    };
    event_bus.emit(SseEvent, input.session_id, event);
}

/// Send session events to all subscribed clients via SSE
/// Broadcasts session list updates (created, updated, deleted, list actions)
pub fn onEventSendSessions(allocator: std.mem.Allocator, input: OnEventInputSessions) !void {
    if (std.mem.indexOf(u8, input.id, "subagent")) |_| {
        return;
    }

    const di = try tree1_mod.getSingleton();
    const event_bus = di.event_bus;

    const log = logger.getGlobal();

    // Build the payload with action and all session columns
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const payload = .{
        .action = input.action,
        .id = input.id,
        .name = input.name,
        .status = input.status,
        .cwd = input.cwd,
        .created_at = input.created_at,
        .updated_at = input.updated_at,
    };
    try buf.print(allocator, "{f}", .{std.json.fmt(payload, .{
        .whitespace = .indent_4,
    })});

    log.?.debugFmt("on_event_send_sessions: action={s}, id={s}, name={s}, data={s}", .{
        input.action,
        input.id,
        input.name,
        buf.items,
    });

    // Duplicate the data so event owns its own copy (buf will be deallocated below)
    const data_copy = try allocator.dupe(u8, buf.items);

    // Use actual session_id as routing key and in event
    const event = SseEvent{
        .session_id = input.id,
        .data = data_copy,
    };

    event_bus.emit(SseEvent, "sessions", event);

    std.debug.print("SSE_DEBUG: on_event_send_sessions: event emitted, action={s}, id={s}\n", .{ input.action, input.id });
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
    type: []const u8 = "chunk",
};

/// JSON structure for reasoning chunk
const ReasoningChunkJson = struct {
    index: usize,
    reasoning_content: []const u8,
    type: []const u8 = "chunk",
};

/// JSON structure for final chunk with usage
const FinalChunkJson = struct {
    index: usize,
    type: []const u8 = "chunk_final",
    finish_reason: []const u8 = "stop",
    usage: ?ChunkUsage = null,
};

/// JSON structure for tool call delta chunk
const ToolCallDeltaChunkJson = struct {
    index: usize,
    type: []const u8 = "tool_call_delta",
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

    try buf.print(allocator, "{f}", .{std.json.fmt(json_chunk, .{
        .whitespace = .indent_4,
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

    try buf.print(allocator, "{f}", .{std.json.fmt(json_chunk, .{
        .whitespace = .indent_4,
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
        .whitespace = .indent_4,
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

    try buf.print(allocator, "{f}", .{std.json.fmt(json_chunk, .{
        .whitespace = .indent_4,
    })});

    return try buf.toOwnedSlice(allocator);
}

// ============================================================================
// Streaming helpers (using event_bus for SSE)

// ============================================================================

/// Send content chunk during streaming response
pub fn sendStreamChunkContent(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    chunk: ContentChunk,
) void {
    const di = tree1_mod.getSingleton() catch return;
    const event_bus = di.event_bus;

    const data = serializeContentChunk(allocator, chunk) catch return;
    defer allocator.free(data);

    const event = SseEvent{
        .session_id = session_id,
        .data = data,
    };
    event_bus.emit(SseEvent, session_id, event);
}

/// Send reasoning chunk during streaming response
pub fn sendStreamChunkReasoning(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    chunk: ReasoningChunk,
) void {
    const di = tree1_mod.getSingleton() catch return;
    const event_bus = di.event_bus;

    const data = serializeReasoningChunk(allocator, chunk) catch return;
    defer allocator.free(data);

    const event = SseEvent{
        .session_id = session_id,
        .data = data,
    };
    event_bus.emit(SseEvent, session_id, event);
}

/// Send final chunk with usage information during streaming
pub fn sendStreamChunkFinal(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    chunk: FinalChunk,
) void {
    const di = tree1_mod.getSingleton() catch return;
    const event_bus = di.event_bus;

    const data = serializeFinalChunk(allocator, chunk) catch return;
    defer allocator.free(data);

    const event = SseEvent{
        .session_id = session_id,
        .data = data,
    };
    event_bus.emit(SseEvent, session_id, event);
}

/// Send tool call delta chunk during streaming response
pub fn sendStreamToolCallDelta(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    chunk: ToolCallDeltaChunk,
) void {
    const di = tree1_mod.getSingleton() catch return;
    const event_bus = di.event_bus;

    const data = serializeToolCallDeltas(allocator, chunk) catch return;
    defer allocator.free(data);

    const event = SseEvent{
        .session_id = session_id,
        .data = data,
    };
    event_bus.emit(SseEvent, session_id, event);
}
