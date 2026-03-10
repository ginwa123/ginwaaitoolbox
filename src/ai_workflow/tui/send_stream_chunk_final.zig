const std = @import("std");
const tree1 = @import("nalarcore");
const agent = tree1.agent;
const http_server = @import("nalarcore").http_server;

pub fn run(allocator: std.mem.Allocator, session_id: []const u8, index: usize, usage: ?agent.Usage) void {
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
