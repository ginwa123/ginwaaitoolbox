const std = @import("std");
const tree1_mod = @import("nalarcore");
const logger_mod = tree1_mod.logger;
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

// ============================================================================
// Send Response - Unified handler for all response types
// ============================================================================

/// Send a unified response to the TUI via SSE
/// Handles: assistant_response, error, tool_result, user_choice
pub fn sendResponse(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    logger: *logger_mod.Logger,
    response_type: ResponseType,
    resp: Response,
) void {
    const sse_manager = http_server.getGlobalSseManager() orelse return;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var w = buf.writer(allocator);

    switch (response_type) {
        .assistant_response => {
            w.writeAll("<response><choices><choice><index>0</index><message><role>assistant</role>") catch return;

            if (resp.content) |c| {
                w.writeAll("<content>") catch return;
                w.writeAll(c) catch return;
                w.writeAll("</content>") catch return;
            }

            if (resp.reasoning_content) |rc| {
                w.writeAll("<reasoning_content>") catch return;
                w.writeAll(rc) catch return;
                w.writeAll("</reasoning_content>") catch return;
            }

            w.writeAll("</message>") catch return;

            if (resp.override_finish_reason) |fr| {
                if (fr.len > 0) {
                    w.writeAll("<finish_reason>") catch return;
                    w.writeAll(fr) catch return;
                    w.writeAll("</finish_reason>") catch return;
                }
            } else if (resp.finish_reason) |fr| {
                w.writeAll("<finish_reason>") catch return;
                w.writeAll(fr.toStr()) catch return;
                w.writeAll("</finish_reason>") catch return;
            }

            w.print("<usage><prompt_tokens>{}</prompt_tokens><completion_tokens>{}</completion_tokens><total_tokens>{}</total_tokens></usage>", .{ resp.usage.prompt_tokens, resp.usage.completion_tokens, resp.usage.total_tokens }) catch return;
            w.writeAll("</choice></choices></response>") catch return;
        },
        .err => {
            w.writeAll("<response><choices><choice><index>0</index><message><role>assistant</role><content><agent>ErrorAgent</agent><markdown>") catch return;
            w.writeAll(resp.err_msg orelse "") catch return;
            w.writeAll("</markdown></content></message><finish_reason>") catch return;
            const fr = resp.override_finish_reason orelse "stop";
            w.writeAll(fr) catch return;
            w.writeAll("</finish_reason></choice></choices></response>") catch return;
        },
        .tool_result => {
            w.writeAll("<response><tool_result><tool_call_id>") catch return;
            w.writeAll(resp.tool_call_id orelse "") catch return;
            w.writeAll("</tool_call_id><tool_name>") catch return;
            w.writeAll(resp.tool_name orelse "") catch return;
            w.writeAll("</tool_name>") catch return;

            if (resp.command) |cmd| {
                w.writeAll("<command>") catch return;
                w.writeAll(cmd) catch return;
                w.writeAll("</command>") catch return;
            }

            w.writeAll("<result>") catch return;
            w.writeAll(resp.tool_result orelse "") catch return;
            w.writeAll("</result></tool_result></response>") catch return;
        },
        .user_choice => {
            w.writeAll("<response><finish_reason>user_choice</finish_reason></response>") catch return;
        },
    }

    const event_type: []const u8 = switch (response_type) {
        .assistant_response => "response",
        .err => "error",
        .tool_result => "tool_result",
        .user_choice => "user_choice",
    };

    const event = http_server.SseEvent{
        .event_type = event_type,
        .data = buf.items,
    };
    sse_manager.sendEvent(session_id, event) catch |err| {
        logger.errFmt("SSE send error: {s}", .{@errorName(err)}) catch {};
    };
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
