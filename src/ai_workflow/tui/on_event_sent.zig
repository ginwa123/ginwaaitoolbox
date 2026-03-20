const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const sqlite = tree1_mod.sqlite;
const http_server = @import("nalarcore").http_server;

// ============================================================================
// XML Protocol Constants
// ============================================================================

/// Maximum size for chunk content (32KB)
const MAX_CHUNK_SIZE = 32768;

/// Maximum size for tool call delta chunk (64KB - tool calls can be large)
const MAX_TOOL_CALL_DELTA_SIZE = 65536;

/// XML event types for SSE
const EventType = enum {
    response,
    tool_result,
    chunk,
    reasoning,
    chunk_final,
    tool_call_delta,
};

// ============================================================================
// XML Helper Functions
// ============================================================================

/// Write an XML tag pair with content
fn writeTag(w: anytype, tag: []const u8, value: []const u8) !void {
    _ = try w.writeAll("<");
    _ = try w.writeAll(tag);
    _ = try w.writeAll(">");
    _ = try w.writeAll(value);
    _ = try w.writeAll("</");
    _ = try w.writeAll(tag);
    _ = try w.writeAll(">");
}

/// Write an opening XML tag
fn writeOpenTag(w: anytype, tag: []const u8) !void {
    _ = try w.writeAll("<");
    _ = try w.writeAll(tag);
    _ = try w.writeAll(">");
}

/// Write a closing XML tag
fn writeCloseTag(w: anytype, tag: []const u8) !void {
    _ = try w.writeAll("</");
    _ = try w.writeAll(tag);
    _ = try w.writeAll(">");
}

/// Write a self-closing XML tag
fn writeSelfClosingTag(w: anytype, tag: []const u8) !void {
    _ = try w.writeAll("<");
    _ = try w.writeAll(tag);
    _ = try w.writeAll("/>");
}

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
    session_name: ?[]const u8,
    loop_index: u32,
    temperature: f32,
    is_thinking: bool,
    is_input: bool = false,
    is_output: bool = false,
    parent_session_id: ?[]const u8 = null,
    parent_id: ?[]const u8 = null,
};

/// Send an SSE event to all clients connected to the given session
/// 
/// XML Protocol:
/// - Response events: <response>...</response>
/// - Tool result events: <tool_result>...</tool_result>
/// 
/// Format is determined by whether tool_call_id is set (tool_result) or not (response)
pub fn on_event_send_new(allocator: std.mem.Allocator, input: OnEventInput) !void {
    const sse_manager = http_server.getGlobalSseManager() orelse return;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var w = buf.writer(allocator);

    // Determine event type based on presence of tool_call_id
    const is_tool_result = input.tool_call_id != null;

    // Write opening tag
    if (is_tool_result) {
        _ = try w.writeAll("<tool_result>");
    } else {
        _ = try w.writeAll("<response>");
    }

    // Write response-only fields (not present in tool_result)
    if (!is_tool_result) {
        try writeTag(w, "session_id", input.session_id);
        try writeTag(w, "model", input.model);
        try writeTag(w, "cwd", input.cwd);
    }

    // Write content field (different tag name for tool_result)
    if (input.content) |v| {
        if (is_tool_result) {
            try writeTag(w, "result", v);
        } else {
            try writeTag(w, "content", v);
        }
    }

    // Write optional fields
    if (input.reasoning_content) |v| {
        try writeTag(w, "reasoning_content", v);
    }

    if (!is_tool_result) {
        try writeTag(w, "role", input.role orelse "assistant");
    }

    if (input.finish_reason) |v| {
        try writeTag(w, "finish_reason", v);
    }

    // Write tool calls (only in response events)
    if (input.tool_calls) |calls| {
        _ = try w.writeAll("<tool_calls>");
        for (calls) |call| {
            _ = try w.writeAll("<tool_call>");
            try writeTag(w, "id", call.id);
            try writeTag(w, "name", call.function.name);
            try writeTag(w, "arguments", call.function.arguments);
            _ = try w.writeAll("</tool_call>");
        }
        _ = try w.writeAll("</tool_calls>");
    }

    // Write tool metadata fields
    if (input.tool_call_id) |v| {
        try writeTag(w, "tool_call_id", v);
    }

    if (input.tool_name) |v| {
        try writeTag(w, "tool_name", v);
    }

    // Write response-only fields (metadata)
    if (!is_tool_result) {
        if (input.agent_name) |v| {
            try writeTag(w, "agent_name", v);
        }

        if (input.session_name) |v| {
            try writeTag(w, "session_name", v);
        }

        _ = try w.print("<loop_index>{d}</loop_index>", .{input.loop_index});
        _ = try w.print("<temperature>{d}</temperature>", .{input.temperature});
        _ = try w.print("<is_thinking>{}</is_thinking>", .{input.is_thinking});
        _ = try w.print("<is_input>{}</is_input>", .{input.is_input});
        _ = try w.print("<is_output>{}</is_output>", .{input.is_output});

        if (input.parent_session_id) |v| {
            try writeTag(w, "parent_session_id", v);
        }

        if (input.parent_id) |v| {
            try writeTag(w, "parent_id", v);
        }

        _ = try w.writeAll("</response>");
    } else {
        _ = try w.writeAll("</tool_result>");
    }

    // Send the event via SSE manager
    const event_type: []const u8 = if (is_tool_result) "tool_result" else "response";
    const event = http_server.SseEvent{
        .event_type = event_type,
        .data = buf.items,
    };
    try sse_manager.sendEvent(input.session_id, event);
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
// Structured Serialization Functions
// ============================================================================

/// Serialize a content chunk to XML format
pub fn serializeContentChunk(allocator: std.mem.Allocator, chunk: ContentChunk) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    _ = try w.print(
        \\<response><chunk index="{d}"><content>{s}</content></chunk></response>
    , .{ chunk.index, chunk.content });

    return try buf.toOwnedSlice(allocator);
}

/// Serialize a reasoning chunk to XML format
pub fn serializeReasoningChunk(allocator: std.mem.Allocator, chunk: ReasoningChunk) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    _ = try w.print(
        \\<response><chunk index="{d}"><reasoning_content>{s}</reasoning_content></chunk></response>
    , .{ chunk.index, chunk.reasoning });

    return try buf.toOwnedSlice(allocator);
}

/// Serialize a final chunk with usage information
pub fn serializeFinalChunk(allocator: std.mem.Allocator, chunk: FinalChunk) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    _ = try w.writeAll("<response><chunk index=\"");
    _ = try w.print("{d}\" final=\"true\">", .{chunk.index});

    if (chunk.usage) |u| {
        _ = try w.print(
            \\<usage><prompt_tokens>{d}</prompt_tokens><completion_tokens>{d}</completion_tokens><total_tokens>{d}</total_tokens></usage>
        , .{ u.prompt_tokens, u.completion_tokens, u.total_tokens });
    }

    _ = try w.writeAll("</chunk></response>");

    return try buf.toOwnedSlice(allocator);
}

/// Serialize tool call deltas to XML format
pub fn serializeToolCallDeltas(allocator: std.mem.Allocator, chunk: ToolCallDeltaChunk) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    _ = try w.print("<response><chunk index=\"{d}\"><tool_calls_delta>", .{chunk.index});

    for (chunk.deltas) |delta| {
        _ = try w.print("<delta index=\"{d}\">", .{delta.index});

        if (delta.id) |id| {
            _ = try w.print("<id>{s}</id>", .{id});
        }
        if (delta.function_name) |name| {
            _ = try w.print("<function_name>{s}</function_name>", .{name});
        }
        if (delta.function_arguments) |args| {
            _ = try w.print("<function_arguments>{s}</function_arguments>", .{args});
        }

        _ = try w.writeAll("</delta>");
    }

    _ = try w.writeAll("</tool_calls_delta></chunk></response>");

    return try buf.toOwnedSlice(allocator);
}

/// Legacy sendResponse function - wraps on_event_send_new for backward compatibility
pub fn sendResponse(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    response_type: ResponseType,
    resp: Response,
) void {
    const input = OnEventInput{
        .session_id = session_id,
        .model = "",
        .cwd = "",
        .content = resp.content,
        .reasoning_content = resp.reasoning_content,
        .role = if (response_type == .err) "assistant" else null,
        .finish_reason = if (resp.override_finish_reason) |fr| fr else if (resp.finish_reason) |fr| fr.toStr() else null,
        .tool_calls = null,
        .tool_call_id = resp.tool_call_id,
        .tool_name = resp.tool_name,
        .agent_name = null,
        .session_name = null,
        .loop_index = 0,
        .temperature = 0.0,
        .is_thinking = false,
        .is_input = false,
        .is_output = false,
        .parent_session_id = null,
        .parent_id = null,
    };
    on_event_send_new(allocator, input) catch return;
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
        .event_type = "chunk",
        .data = data,
    };
    sse_manager.sendEvent(session_id, event) catch {};
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
        .event_type = "reasoning",
        .data = data,
    };
    sse_manager.sendEvent(session_id, event) catch {};
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
        .event_type = "chunk_final",
        .data = data,
    };
    sse_manager.sendEvent(session_id, event) catch {};
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
        .event_type = "tool_call_delta",
        .data = data,
    };
    sse_manager.sendEvent(session_id, event) catch {};
}

// ============================================================================
// Tests
// ============================================================================

test {}
