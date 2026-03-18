const std = @import("std");
const tree1_mod = @import("nalarcore");
const tree1 = @import("nalarcore");
const logger_mod = tree1_mod.logger;
const agent = tree1_mod.agent;
const sqlite = tree1_mod.sqlite;
const http_server = @import("nalarcore").http_server;

/// Maximum size for chunk content (32KB)
const MAX_CHUNK_SIZE = 32768;

/// Maximum size for tool call delta chunk (64KB - tool calls can be large)
const MAX_TOOL_CALL_DELTA_SIZE = 65536;

// ============================================================================
// Send Response - sends a complete response to the TUI
// ============================================================================

/// Send a complete assistant response to the TUI via SSE
pub fn SendResponse(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    logger: *logger_mod.Logger,
    content: ?[]const u8,
    finish_reason: ?agent.FinishReason,
    reasoning_content: ?[]const u8,
    usage: agent.Usage,
    override_finish_reason: ?[]const u8,
) void {
    const sse_manager = http_server.getGlobalSseManager() orelse {
        logger.errFmt("SSE send_response: no global SSE manager", .{}) catch {};
        return;
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var w = buf.writer(allocator);

    w.writeAll("<response><choices><choice><index>0</index><message><role>assistant</role>") catch return;

    if (content) |c| {
        w.writeAll("<content>") catch return;
        w.writeAll(c) catch return;
        w.writeAll("</content>") catch return;
    }

    if (reasoning_content) |rc| {
        w.writeAll("<reasoning_content>") catch return;
        w.writeAll(rc) catch return;
        w.writeAll("</reasoning_content>") catch return;
    }

    w.writeAll("</message>") catch return;

    if (override_finish_reason) |fr| {
        if (fr.len > 0) {
            w.writeAll("<finish_reason>") catch return;
            w.writeAll(fr) catch return;
            w.writeAll("</finish_reason>") catch return;
        }
    } else if (finish_reason) |fr| {
        w.writeAll("<finish_reason>") catch return;
        w.writeAll(fr.toStr()) catch return;
        w.writeAll("</finish_reason>") catch return;
    }

    // Add usage information
    w.print("<usage><prompt_tokens>{}</prompt_tokens><completion_tokens>{}</completion_tokens><total_tokens>{}</total_tokens></usage>", .{ usage.prompt_tokens, usage.completion_tokens, usage.total_tokens }) catch return;

    w.writeAll("</choice></choices></response>") catch return;

    logger.infoFmt("SEND RESPONSE XML: {s}", .{buf.items}) catch {};

    const event = http_server.SseEvent{
        .event_type = "response",
        .data = buf.items,
    };
    sse_manager.sendEvent(session_id, event) catch |err| {
        logger.errFmt("SSE send_response ERROR: {s}, session_id={s}", .{@errorName(err), session_id}) catch {};
        return;
    };
}

// ============================================================================
// Send Error - sends an error response to the TUI
// ============================================================================

/// Send an error message to the TUI via SSE
pub fn sendError(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    logger: *logger_mod.Logger,
    err_msg: []const u8,
    finish_reason: ?[]const u8,
) void {
    const sse_manager = http_server.getGlobalSseManager() orelse return;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var w = buf.writer(allocator);

    // Wrap error in proper response structure with content/markdown for TUI display
    w.writeAll("<response><choices><choice><index>0</index><message><role>assistant</role><content><agent>ErrorAgent</agent><markdown>") catch return;
    w.writeAll(err_msg) catch return;
    w.writeAll("</markdown></content></message><finish_reason>") catch return;
    const fr = finish_reason orelse "stop";
    w.writeAll(fr) catch return;
    w.writeAll("</finish_reason></choice></choices></response>") catch return;

    logger.traceFmt("SEND ERROR XML: {s}", .{buf.items}) catch {};

    const event = http_server.SseEvent{
        .event_type = "error",
        .data = buf.items,
    };
    sse_manager.sendEvent(session_id, event) catch |err| {
        const err_name = @errorName(err);
        logger.errFmt("SSE send error: {s}", .{err_name}) catch {};
    };
}

// ============================================================================
// Send Skill - sends skills list to the TUI
// ============================================================================

/// Send skills list to TUI via SSE
pub fn sendSkill(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,
    session_id: []const u8,
) void {
    const sse_manager = http_server.getGlobalSseManager() orelse return;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var w = buf.writer(allocator);

    w.writeAll("<response><type>skills</type><skills>") catch return;

    // Fetch skills from database
    if (session_id.len > 0) {
        const sql = "SELECT skill_name FROM session_skills WHERE session_id = ?";
        var rows = db.query(allocator, sql, &.{session_id}) catch return;
        defer rows.deinit();

        while (rows.next() catch null) |row| {
            w.writeAll("<skill><name>") catch return;
            w.writeAll(row.values[0]) catch return;
            w.writeAll("</name></skill>") catch return;
            row.deinit(allocator);
        }
    }

    w.writeAll("</skills></response>") catch return;

    logger.debugFmt("SEND SKILLS XML: {s}", .{buf.items}) catch {};

    const event = http_server.SseEvent{
        .event_type = "skills",
        .data = buf.items,
    };
    sse_manager.sendEvent(session_id, event) catch |err| {
        const err_name = @errorName(err);
        logger.errFmt("SSE send skills: {s}", .{err_name}) catch {};
    };
}

// ============================================================================
// Send Stream Chunk Content - sends content chunk during streaming
// ============================================================================

/// Send content chunk during streaming response
pub fn sendStreamChunkContent(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    index: usize,
    content: []const u8,
) void {
    _ = allocator; // No longer needed - using stack buffer
    const sse_manager = http_server.getGlobalSseManager() orelse return;

    // Use fixed-size stack buffer instead of heap allocation
    var buf: [MAX_CHUNK_SIZE]u8 = undefined;
    var pos: usize = 0;

    // Build the XML response directly into stack buffer
    const prefix = std.fmt.bufPrint(buf[pos..], "<response><chunk index=\"{}\"><content>", .{index}) catch return;
    pos += prefix.len;

    if (pos + content.len + 30 > buf.len) return; // Check remaining space for content + closing tags
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

// ============================================================================
// Send Stream Chunk Reasoning - sends reasoning chunk during streaming
// ============================================================================

/// Send reasoning chunk during streaming response
pub fn sendStreamChunkReasoning(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    index: usize,
    reasoning: []const u8,
) void {
    _ = allocator; // No longer needed - using stack buffer
    const sse_manager = http_server.getGlobalSseManager() orelse return;

    // Use fixed-size stack buffer instead of heap allocation
    var buf: [MAX_CHUNK_SIZE]u8 = undefined;
    var pos: usize = 0;

    // Build the XML response directly into stack buffer
    const prefix = std.fmt.bufPrint(buf[pos..], "<response><chunk index=\"{}\"><reasoning_content>", .{index}) catch return;
    pos += prefix.len;

    if (pos + reasoning.len + 40 > buf.len) return; // Check remaining space
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

// ============================================================================
// Send Stream Chunk Final - sends final chunk with usage information
// ============================================================================

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
    // Removed: <finish_reason> - this is sent by sendResponse() as the terminal signal
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

// ============================================================================
// Send Stream Tool Call Delta - sends tool call delta during streaming
// ============================================================================

/// Send tool call delta chunk during streaming response
pub fn sendStreamToolCallDelta(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    index: usize,
    deltas: []const agent.ToolCallDelta,
) void {
    _ = allocator; // No longer needed - using stack buffer
    const sse_manager = http_server.getGlobalSseManager() orelse return;

    // Use fixed-size stack buffer instead of heap allocation
    var buf: [MAX_TOOL_CALL_DELTA_SIZE]u8 = undefined;
    var pos: usize = 0;

    // Build the XML response directly into stack buffer
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
// Send Tool Result - sends tool execution result to the TUI
// ============================================================================

/// Send tool execution result to the TUI via SSE
pub fn SendToolResult(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    logger: *logger_mod.Logger,
    result: []const u8,
    tool_call_id: []const u8,
    tool_name: []const u8,
    command: ?[]const u8,
) void {
    const sse_manager = http_server.getGlobalSseManager() orelse return;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var w = buf.writer(allocator);

    w.writeAll("<response><tool_result><tool_call_id>") catch return;
    w.writeAll(tool_call_id) catch return;
    w.writeAll("</tool_call_id><tool_name>") catch return;
    w.writeAll(tool_name) catch return;
    w.writeAll("</tool_name>") catch return;

    if (command) |cmd| {
        w.writeAll("<command>") catch return;
        w.writeAll(cmd) catch return;
        w.writeAll("</command>") catch return;
    }

    w.writeAll("<result>") catch return;

    w.writeAll(result) catch return;

    w.writeAll("</result></tool_result></response>") catch return;

    logger.traceFmt("SEND TOOL RESULT XML: {s}", .{buf.items}) catch {};

    const event = http_server.SseEvent{
        .event_type = "tool_result",
        .data = buf.items,
    };
    sse_manager.sendEvent(session_id, event) catch |err| {
        logger.errFmt("SSE send tool result: {s}", .{@errorName(err)}) catch {};
    };
}

// ============================================================================
// Send User Choice - sends user_choice finish reason to the TUI
// ============================================================================

/// Send user_choice finish reason to the TUI via SSE
pub fn sendUserChoice(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    logger: *logger_mod.Logger,
) !void {
    const sse_manager = http_server.getGlobalSseManager() orelse return;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var w = buf.writer(allocator);

    w.writeAll("<response><finish_reason>user_choice</finish_reason>") catch return;
    w.writeAll("</response>") catch return;

    logger.traceFmt("SEND SESSIONS XML: {s}", .{buf.items}) catch {};

    const event = http_server.SseEvent{
        .event_type = "user_choice",
        .data = buf.items,
    };
    sse_manager.sendEvent(session_id, event) catch |err| {
        const err_name = @errorName(err);
        logger.errFmt("SSE send user choice: {s}", .{err_name}) catch {};
    };
}

// ============================================================================
// Tests
// ============================================================================

test {}
