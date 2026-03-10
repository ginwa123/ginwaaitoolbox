const std = @import("std");
const http_server = @import("nalarcore").http_server;

pub fn run(allocator: std.mem.Allocator, session_id: []const u8, index: usize, reasoning: []const u8) void {
    const sse_manager = http_server.getGlobalSseManager() orelse return;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var w = buf.writer(allocator);

    w.print("<response><chunk index=\"{}\"><reasoning_content>", .{index}) catch return;
    w.writeAll(reasoning) catch return;
    w.writeAll("</reasoning_content></chunk></response>") catch return;

    const event = http_server.SseEvent{
        .event_type = "reasoning",
        .data = buf.items,
    };
    sse_manager.sendEvent(session_id, event, allocator) catch {};
}
