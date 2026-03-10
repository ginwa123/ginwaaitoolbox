const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const http_server = @import("nalarcore").http_server;

/// Maximum size for tool call delta chunk (64KB - tool calls can be large)
const MAX_CHUNK_SIZE = 65536;

pub fn run(allocator: std.mem.Allocator, session_id: []const u8, index: usize, deltas: []const agent.ToolCallDelta) void {
    _ = allocator; // No longer needed - using stack buffer
    const sse_manager = http_server.getGlobalSseManager() orelse return;

    // Use fixed-size stack buffer instead of heap allocation
    var buf: [MAX_CHUNK_SIZE]u8 = undefined;
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
