const std = @import("std");
const mod = @import("mod.zig");
const nalarcore = mod.nalarcore;
const agent = nalarcore.agent;
const event_bus_mod = nalarcore.event_bus;
const logger_mod = nalarcore.loggermod;
const helpers = nalarcore.helpers;
const SseEvent = mod.SseEvent;
const SkillInfo = mod.SkillInfo;

/// JSON representation of a tool call
const ToolCallJson = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

const SseEventLLMHistory = struct {
    index: ?usize = null,
    content: []const u8,
    type: []const u8 = "full",
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    reasoning_content: ?[]const u8 = null,
    role: []const u8 = "assistant",
    finish_reason: ?[]const u8 = null,
    tool_calls_json: ?[]const u8 = null,
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
    image_url: ?[]const u8 = null,
    session_skills: ?[]const SkillInfo = null,
};

pub const OnEventInputLLMHistory = struct {
    index: usize = 0,
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    content: ?[]const u8,
    reasoning_content: ?[]const u8,
    role: ?[]const u8,
    finish_reason: ?[]const u8,
    tool_calls_json: ?[]const u8,
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
    image_url: ?[]const u8 = null,
    session_skills: []const SkillInfo,
};

pub const OnEventSendLLMHistoryInput = struct { allocator: std.mem.Allocator, io: std.Io, logger: ?*logger_mod.Logger, event_bus: *event_bus_mod.EventBus, entity: OnEventInputLLMHistory };

pub fn onEventSendLLMHistory(
    obj: OnEventSendLLMHistoryInput,
) !void {
    const input = obj.entity;
    const log = obj.logger;
    const session_id = input.session_id;
    const allocator = obj.allocator;
    const event_bus = obj.event_bus;

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
        });
    } else {
        log.?.warnFmt("on_event_send_new[{s}]: NO CONTENT!", .{session_id});
    }

    // Sanitize content + reasoning_content to valid UTF-8 before JSON
    // serialization. Without this, Zig 0.16's std.json.fmt emits
    // invalid-UTF-8 strings as ARRAYS of bytes (because
    // emit_strings_as_arrays defaults to false but only applies when the
    // slice is valid UTF-8 — see /usr/local/lib/zig/std/json/Stringify.zig:506).
    // The bash tool's stdout can contain binary bytes (e.g. 0x89, 0x93
    // from test programs printing raw bytes) that are invalid UTF-8 and
    // would otherwise corrupt the SSE payload — the frontend would
    // receive content as [60, 116, 111, ...] instead of "...". This is
    // the same fix used by `sessionMessagesHandler` for the REST path
    // (see http_handlers/session_messages_get.zig).
    const sanitized_content: ?[]u8 = blk: {
        const c = input.content orelse break :blk null;
        break :blk try helpers.sanitize.sanitizeUtf8(allocator, c);
    };
    defer if (sanitized_content) |s| allocator.free(s);

    const sanitized_reasoning: ?[]u8 = blk: {
        const r = input.reasoning_content orelse break :blk null;
        break :blk try helpers.sanitize.sanitizeUtf8(allocator, r);
    };
    defer if (sanitized_reasoning) |s| allocator.free(s);

    // Build tool_calls JSON array if present

    // Convert llm_history.SkillInfo to local SkillInfo for SSE payload
    var session_skills_json: ?[]const SkillInfo = null;
    var session_skills_owned: std.ArrayList(SkillInfo) = .empty;
    defer if (session_skills_json == null) session_skills_owned.deinit(allocator);

    for (input.session_skills) |skill| {
        try session_skills_owned.append(allocator, .{
            .skill_name = skill.skill_name,
            .content = skill.content,
            .loaded_at = skill.loaded_at,
        });
    }
    session_skills_json = try session_skills_owned.toOwnedSlice(allocator);

    const payload = SseEventLLMHistory{
        .index = input.index,
        .content = if (sanitized_content) |s| s else (input.content orelse ""),
        .session_id = input.session_id,
        .model = input.model,
        .cwd = input.cwd,
        .reasoning_content = if (sanitized_reasoning) |s| s else input.reasoning_content,
        .role = input.role orelse "assistant",
        .finish_reason = input.finish_reason,
        .tool_calls_json = input.tool_calls_json,
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
        .image_url = input.image_url,
        .session_skills = session_skills_json,
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
        .event_type = "llm_full",
    };
    // Per-session emit (kept for any future server-side fan-out that
    // needs only this session's events).
    event_bus.emit(SseEvent, input.session_id, event);
    // Central broadcast: subscribers to bare "llm" receive ALL sessions'
    // LLM events. The frontend listener filter narrows to the current
    // session_id on the JS side.
    event_bus.emit(SseEvent, "llm", event);
}
