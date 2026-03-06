const std = @import("std");
const tree1 = @import("tree1");
const agent = tree1.agent;

pub fn run(allocator: std.mem.Allocator, conn_fd: std.posix.fd_t, index: usize, usage: ?agent.Usage) void {
    if (conn_fd < 0) return;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var w = buf.writer(allocator);

    w.print("<response><chunk index=\"{}\" final=\"true\">", .{index}) catch return;
    // Removed: <finish_reason> - this is sent by sendResponse() as the terminal signal
    if (usage) |u| {
        w.print("<usage><prompt_tokens>{}</prompt_tokens><completion_tokens>{}</completion_tokens><total_tokens>{}</total_tokens></usage>", .{ u.prompt_tokens, u.completion_tokens, u.total_tokens }) catch return;
    }
    w.writeAll("</chunk></response>") catch return;

    // std.debug.print("chunk final {s}\n", .{buf.items});

    _ = std.posix.write(conn_fd, buf.items) catch return;
    _ = std.posix.write(conn_fd, "\n") catch return;
}
