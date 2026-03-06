const std = @import("std");
const tree1_mod = @import("tree1");
const logger_mod = tree1_mod.logger;

pub fn run(allocator: std.mem.Allocator, conn_fd: std.posix.fd_t, logger: *logger_mod.Logger, result: []const u8, tool_call_id: []const u8, tool_name: []const u8) void {
    if (conn_fd < 0) return;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var w = buf.writer(allocator);

    w.writeAll("<response><tool_result><tool_call_id>") catch return;
    w.writeAll(tool_call_id) catch return;
    w.writeAll("</tool_call_id><tool_name>") catch return;
    w.writeAll(tool_name) catch return;
    w.writeAll("</tool_name><result>") catch return;

    w.writeAll(result) catch return;

    w.writeAll("</result></tool_result></response>") catch return;

    logger.traceFmt("SEND TOOL RESULT XML: {s}", .{buf.items}) catch {};

    _ = std.posix.write(conn_fd, buf.items) catch |err| {
        if (err != error.BrokenPipe) {
            logger.errFmt("Send Tool Result error {s}", .{@errorName(err)}) catch {};
        }
    };
    _ = std.posix.write(conn_fd, "\n") catch {};
}
