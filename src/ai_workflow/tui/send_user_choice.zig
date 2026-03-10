const std = @import("std");
const tree1_mod = @import("nalarcore");
const logger_mod = tree1_mod.logger;
const http_server = @import("nalarcore").http_server;

pub fn run(
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
    sse_manager.sendEvent(session_id, event, allocator) catch |err| {
        logger.errFmt("SSE send user choice: {s}", .{@errorName(err)}) catch {};
    };
}
