const std = @import("std");
const tree1_mod = @import("nalarcore");
const sqlite = tree1_mod.sqlite;
const logger_mod = tree1_mod.logger;
const http_server = @import("nalarcore").http_server;

/// Send skills list to TUI via SSE
pub fn run(
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
        logger.errFmt("SSE send skills: {s}", .{@errorName(err)}) catch {};
    };
}

test {
    _ = @import("send_skill_test.zig");
}
