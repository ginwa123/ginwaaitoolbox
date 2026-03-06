const std = @import("std");
const tree1_mod = @import("tree1");
const logger_mod = tree1_mod.logger;

pub fn run(allocator: std.mem.Allocator, conn_fd: std.posix.fd_t, logger: *logger_mod.Logger, err_msg: []const u8, finish_reason: ?[]const u8) void {
    if (conn_fd < 0) return;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var w = buf.writer(allocator);

    // Wrap error in proper response structure with content/markdown for TUI display
    w.writeAll("<response><choices><choice><index>0</index><message><role>assistant</role><content><agent>ErrorAgent</agent><markdown>") catch return;
    w.writeAll(err_msg) catch return;
    w.writeAll("</markdown></content></message><finish_reason>") catch return;
    const fr = finish_reason orelse "stop";
    w.writeAll(fr) catch return;
    w.writeAll("</finish_reason></choice></choices></response>") catch return;

    logger.traceFmt("SEND ERROR XML: {s}", .{buf.items}) catch {};

    _ = std.posix.write(conn_fd, buf.items) catch |err| {
        if (err != error.BrokenPipe) {
            logger.errFmt("Send Error response error {s}", .{@errorName(err)}) catch {};
        }
    };
    _ = std.posix.write(conn_fd, "\n") catch {};
}
