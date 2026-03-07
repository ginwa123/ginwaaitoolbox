const std = @import("std");
const tree1_mod = @import("nalarcore");
const logger_mod = tree1_mod.logger;

pub fn run(
    allocator: std.mem.Allocator,
    conn_fd: std.posix.fd_t,
    logger: *logger_mod.Logger,
) !void {
    if (conn_fd < 0) return;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var w = buf.writer(allocator);

    w.writeAll("<response><finish_reason>user_choice</finish_reason>") catch return;
    w.writeAll("</response>") catch return;

    logger.traceFmt("SEND SESSIONS XML: {s}", .{buf.items}) catch {};

    _ = std.posix.write(conn_fd, buf.items) catch |err| {
        if (err != error.BrokenPipe) {
            logger.errFmt("Send Sessions response error {s}", .{@errorName(err)}) catch {};
        }
    };
    _ = std.posix.write(conn_fd, "\n") catch {};
}
