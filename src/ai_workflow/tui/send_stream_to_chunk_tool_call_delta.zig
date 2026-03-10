const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const http_server = @import("nalarcore").http_server;

pub fn run(allocator: std.mem.Allocator, session_id: []const u8, index: usize, deltas: []const agent.ToolCallDelta) void {
    const sse_manager = http_server.getGlobalSseManager() orelse return;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var w = buf.writer(allocator);

    w.print("<response><chunk index=\"{}\"><tool_calls_delta>", .{index}) catch return;
    for (deltas) |delta| {
        w.print("<delta index=\"{}\">", .{delta.index}) catch return;
        if (delta.id) |id| {
            w.print("<id>{s}</id>", .{id}) catch return;
        }
        if (delta.function_name) |name| {
            w.print("<function_name>{s}</function_name>", .{name}) catch return;
        }
        if (delta.function_arguments) |args| {
            w.print("<function_arguments>{s}</function_arguments>", .{args}) catch return;
        }
        w.writeAll("</delta>") catch return;
    }
    w.writeAll("</tool_calls_delta></chunk></response>") catch return;

    const event = http_server.SseEvent{
        .event_type = "tool_call_delta",
        .data = buf.items,
    };
    sse_manager.sendEvent(session_id, event, allocator) catch {};
}
