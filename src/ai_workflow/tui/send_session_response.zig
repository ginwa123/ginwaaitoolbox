const std = @import("std");
const tree1_mod = @import("nalarcore");
const tui_workflow = @import("tui_workflow.zig");
const logger_mod = tree1_mod.logger;

/// Get the current agent from the last message itree1_mod.tui_workflow;n the database.
/// Returns "ExplorationAgent" if no messages exist for this session.
pub fn run(allocator: std.mem.Allocator, conn_fd: std.posix.fd_t, logger: *logger_mod.Logger, sessions: []tui_workflow.SessionInfo) void {
    if (conn_fd < 0) return;

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

    _ = std.posix.write(conn_fd, buf.items) catch |err| {
        if (err != error.BrokenPipe) {
            logger.errFmt("Send Sessions response error {s}", .{@errorName(err)}) catch {};
        }
    };
    _ = std.posix.write(conn_fd, "\n") catch {};
}
