const std = @import("std");
const tree1_mod = @import("nalarcore");
const sqlite = tree1_mod.sqlite;
const logger_mod = tree1_mod.logger;

/// Send skills list to TUI via IPC
pub fn run(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,
    conn_fd: std.posix.fd_t,
    session_id: []const u8,
) void {
    if (conn_fd < 0) return;

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

    _ = std.posix.write(conn_fd, buf.items) catch |err| {
        if (err != error.BrokenPipe) {
            logger.errFmt("Send Skills response error {s}", .{@errorName(err)}) catch {};
        }
    };
    _ = std.posix.write(conn_fd, "\n") catch {};
}

test {
    _ = @import("send_skill_test.zig");
}
