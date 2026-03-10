const std = @import("std");
const tree1_mod = @import("nalarcore");
const tui_workflow = @import("tui_workflow.zig");
const logger_mod = tree1_mod.logger;
const http_server = @import("nalarcore").http_server;

/// Get the current agent from the last message itree1_mod.tui_workflow;n the database.
/// Returns "ExplorationAgent" if no messages exist for this session.
pub fn run(allocator: std.mem.Allocator, session_id: []const u8, logger: *logger_mod.Logger, sessions: []tui_workflow.SessionInfo) void {
    const sse_manager = http_server.getGlobalSseManager() orelse return;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var w = buf.writer(allocator);

    w.writeAll("<response><type>sessions</type><sessions>") catch return;
    for (sessions) |session| {
        w.writeAll("<session><id>") catch return;
        w.writeAll(session.session_id) catch return;
        w.writeAll("</id><dir>") catch return;
        w.writeAll(session.session_dir) catch return;
        w.writeAll("</dir><created>") catch return;
        w.writeAll(session.created_at) catch return;
        w.writeAll("</created></session>") catch return;
    }
    w.writeAll("</sessions></response>") catch return;

    logger.traceFmt("SEND SESSIONS XML: {s}", .{buf.items}) catch {};

    const event = http_server.SseEvent{
        .event_type = "sessions",
        .data = buf.items,
    };
    sse_manager.sendEvent(session_id, event) catch |err| {
        logger.errFmt("SSE send sessions: {s}", .{@errorName(err)}) catch {};
    };
}

test {
    _ = @import("send_session_response_test.zig");
}
