const std = @import("std");

pub fn run(allocator: std.mem.Allocator, conn_fd: std.posix.fd_t, index: usize, content: []const u8) void {
    if (conn_fd < 0) return;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var w = buf.writer(allocator);

    w.print("<response><chunk index=\"{}\"><content>", .{index}) catch return;
    w.writeAll(content) catch return;
    w.writeAll("</content></chunk></response>") catch return;

    _ = std.posix.write(conn_fd, buf.items) catch return;
    _ = std.posix.write(conn_fd, "\n") catch return;
}
