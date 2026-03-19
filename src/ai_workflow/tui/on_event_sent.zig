const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const sqlite = tree1_mod.sqlite;
const http_server = @import("nalarcore").http_server;

/// Maximum size for chunk content (32KB)
const MAX_CHUNK_SIZE = 32768;

/// Maximum size for tool call delta chunk (64KB - tool calls can be large)
const MAX_TOOL_CALL_DELTA_SIZE = 65536;

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

pub const OnEventInput = struct { session_id: []const u8, model: []const u8, cwd: []const u8, content: ?[]const u8, reasoning_content: ?[]const u8, role: ?[]const u8, finish_reason: ?[]const u8, tool_calls: ?[]agent.ToolCall, tool_call_id: ?[]const u8, tool_name: ?[]const u8 = null, agent_name: ?[]const u8, session_name: ?[]const u8, loop_index: u32, temperature: f32, is_thinking: bool, is_input: bool = false, is_output: bool = false, parent_session_id: ?[]const u8 = null, parent_id: ?[]const u8 = null };

pub fn onEventSendNew(allocator: std.mem.Allocator, input: OnEventInput) !void {
    const sse_manager = http_server.getGlobalSseManager() orelse return;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var w = buf.writer(allocator);

    // Use <tool_result> format when sending tool results (when tool_call_id is set)
    // This is what the TUI client expects
    const is_tool_result = input.tool_call_id != null;
    if (is_tool_result) {
        _ = try w.writeAll("<tool_result>");
    } else {
        _ = try w.writeAll("<response>");
    }

    if (!is_tool_result) {
        _ = try w.writeAll("<session_id>");
        _ = try w.writeAll(input.session_id);
        _ = try w.writeAll("</session_id>");

        _ = try w.writeAll("<model>");
        _ = try w.writeAll(input.model);
        _ = try w.writeAll("</model>");

        _ = try w.writeAll("<cwd>");
        _ = try w.writeAll(input.cwd);
        _ = try w.writeAll("</cwd>");
    }

    if (input.content) |v| {
        if (is_tool_result) {
            _ = try w.writeAll("<result>");
            _ = try w.writeAll(v);
            _ = try w.writeAll("</result>");
        } else {
            _ = try w.writeAll("<content>");
            _ = try w.writeAll(v);
            _ = try w.writeAll("</content>");
        }
    }

    if (input.reasoning_content) |v| {
        _ = try w.writeAll("<reasoning_content>");
        _ = try w.writeAll(v);
        _ = try w.writeAll("</reasoning_content>");
    }

    if (!is_tool_result) {
        _ = try w.writeAll("<role>");
        _ = try w.writeAll(input.role orelse "assistant");
        _ = try w.writeAll("</role>");
    }

    if (input.finish_reason) |v| {
        _ = try w.writeAll("<finish_reason>");
        _ = try w.writeAll(v);
        _ = try w.writeAll("</finish_reason>");
    }

    if (input.tool_calls) |calls| {
        _ = try w.writeAll("<tool_calls>");
        for (calls) |call| {
            _ = try w.writeAll("<tool_call>");
            _ = try w.writeAll("<id>");
            _ = try w.writeAll(call.id);
            _ = try w.writeAll("</id>");
            _ = try w.writeAll("<name>");
            _ = try w.writeAll(call.function.name);
            _ = try w.writeAll("</name>");
            _ = try w.writeAll("<arguments>");
            _ = try w.writeAll(call.function.arguments);
            _ = try w.writeAll("</arguments>");
            _ = try w.writeAll("</tool_call>");
        }
        _ = try w.writeAll("</tool_calls>");
    }

    if (input.tool_call_id) |v| {
        _ = try w.writeAll("<tool_call_id>");
        _ = try w.writeAll(v);
        _ = try w.writeAll("</tool_call_id>");
    }

    if (input.tool_name) |v| {
        _ = try w.writeAll("<tool_name>");
        _ = try w.writeAll(v);
        _ = try w.writeAll("</tool_name>");
    }

    if (!is_tool_result) {
        if (input.agent_name) |v| {
            _ = try w.writeAll("<agent_name>");
            _ = try w.writeAll(v);
            _ = try w.writeAll("</agent_name>");
        }

        if (input.session_name) |v| {
            _ = try w.writeAll("<session_name>");
            _ = try w.writeAll(v);
            _ = try w.writeAll("</session_name>");
        }

        _ = try w.print("<loop_index>{d}</loop_index>", .{input.loop_index});
        _ = try w.print("<temperature>{d}</temperature>", .{input.temperature});
        _ = try w.print("<is_thinking>{}</is_thinking>", .{input.is_thinking});
        _ = try w.print("<is_input>{}</is_input>", .{input.is_input});
        _ = try w.print("<is_output>{}</is_output>", .{input.is_output});

        if (input.parent_session_id) |v| {
            _ = try w.writeAll("<parent_session_id>");
            _ = try w.writeAll(v);
            _ = try w.writeAll("</parent_session_id>");
        }

        if (input.parent_id) |v| {
            _ = try w.writeAll("<parent_id>");
            _ = try w.writeAll(v);
            _ = try w.writeAll("</parent_id>");
        }

        _ = try w.writeAll("</response>");
    } else {
        _ = try w.writeAll("</tool_result>");
    }

    const event_type: []const u8 = if (is_tool_result) "tool_result" else "response";
    const event = http_server.SseEvent{
        .event_type = event_type,
        .data = buf.items,
    };
    try sse_manager.sendEvent(input.session_id, event);
}

/// Legacy sendResponse function - wraps onEventSendNew for backward compatibility
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
    onEventSendNew(allocator, input) catch return;
}

// ============================================================================
// Streaming helpers
// ============================================================================

/// Send content chunk during streaming response
pub fn sendStreamChunkContent(
    session_id: []const u8,
    index: usize,
    content: []const u8,
) void {
    const sse_manager = http_server.getGlobalSseManager() orelse return;

    var buf: [MAX_CHUNK_SIZE]u8 = undefined;
    var pos: usize = 0;

    const prefix = std.fmt.bufPrint(buf[pos..], "<response><chunk index=\"{}\"><content>", .{index}) catch return;
    pos += prefix.len;

    if (pos + content.len + 30 > buf.len) return;
    @memcpy(buf[pos..][0..content.len], content);
    pos += content.len;

    const suffix = "</content></chunk></response>";
    @memcpy(buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;

    const event = http_server.SseEvent{
        .event_type = "chunk",
        .data = buf[0..pos],
    };
    sse_manager.sendEvent(session_id, event) catch {};
}

/// Send reasoning chunk during streaming response
pub fn sendStreamChunkReasoning(
    session_id: []const u8,
    index: usize,
    reasoning: []const u8,
) void {
    const sse_manager = http_server.getGlobalSseManager() orelse return;

    var buf: [MAX_CHUNK_SIZE]u8 = undefined;
    var pos: usize = 0;

    const prefix = std.fmt.bufPrint(buf[pos..], "<response><chunk index=\"{}\"><reasoning_content>", .{index}) catch return;
    pos += prefix.len;

    if (pos + reasoning.len + 40 > buf.len) return;
    @memcpy(buf[pos..][0..reasoning.len], reasoning);
    pos += reasoning.len;

    const suffix = "</reasoning_content></chunk></response>";
    @memcpy(buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;

    const event = http_server.SseEvent{
        .event_type = "reasoning",
        .data = buf[0..pos],
    };
    sse_manager.sendEvent(session_id, event) catch {};
}

/// Send final chunk with usage information during streaming
pub fn sendStreamChunkFinal(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    index: usize,
    usage: ?agent.Usage,
) void {
    const sse_manager = http_server.getGlobalSseManager() orelse return;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var w = buf.writer(allocator);

    w.print("<response><chunk index=\"{}\" final=\"true\">", .{index}) catch return;
    if (usage) |u| {
        w.print("<usage><prompt_tokens>{}</prompt_tokens><completion_tokens>{}</completion_tokens><total_tokens>{}</total_tokens></usage>", .{ u.prompt_tokens, u.completion_tokens, u.total_tokens }) catch return;
    }
    w.writeAll("</chunk></response>") catch return;

    const event = http_server.SseEvent{
        .event_type = "chunk_final",
        .data = buf.items,
    };
    sse_manager.sendEvent(session_id, event) catch {};
}

/// Send tool call delta chunk during streaming response
pub fn sendStreamToolCallDelta(
    session_id: []const u8,
    index: usize,
    deltas: []const agent.ToolCallDelta,
) void {
    const sse_manager = http_server.getGlobalSseManager() orelse return;

    var buf: [MAX_TOOL_CALL_DELTA_SIZE]u8 = undefined;
    var pos: usize = 0;

    const prefix = std.fmt.bufPrint(buf[pos..], "<response><chunk index=\"{}\"><tool_calls_delta>", .{index}) catch return;
    pos += prefix.len;

    for (deltas) |delta| {
        const delta_start = std.fmt.bufPrint(buf[pos..], "<delta index=\"{}\">", .{delta.index}) catch return;
        pos += delta_start.len;

        if (delta.id) |id| {
            const id_part = std.fmt.bufPrint(buf[pos..], "<id>{s}</id>", .{id}) catch return;
            pos += id_part.len;
        }
        if (delta.function_name) |name| {
            const name_part = std.fmt.bufPrint(buf[pos..], "<function_name>{s}</function_name>", .{name}) catch return;
            pos += name_part.len;
        }
        if (delta.function_arguments) |args| {
            const args_part = std.fmt.bufPrint(buf[pos..], "<function_arguments>{s}</function_arguments>", .{args}) catch return;
            pos += args_part.len;
        }

        const delta_end = "</delta>";
        if (pos + delta_end.len > buf.len) return;
        @memcpy(buf[pos..][0..delta_end.len], delta_end);
        pos += delta_end.len;
    }

    const suffix = "</tool_calls_delta></chunk></response>";
    if (pos + suffix.len > buf.len) return;
    @memcpy(buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;

    const event = http_server.SseEvent{
        .event_type = "tool_call_delta",
        .data = buf[0..pos],
    };
    sse_manager.sendEvent(session_id, event) catch {};
}

// ============================================================================
// Tests
// ============================================================================

test {}
