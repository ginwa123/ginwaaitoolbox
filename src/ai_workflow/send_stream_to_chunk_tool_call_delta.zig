const std = @import("std");
const tree1_mod = @import("tree1");
const agent = tree1_mod.agent;

pub fn run(allocator: std.mem.Allocator, conn_fd: std.posix.fd_t, index: usize, deltas: []const agent.ToolCallDelta) void {
    if (conn_fd < 0) return;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var w = buf.writer(allocator);

    w.print("<response><chunk index=\"{}\"><tool_calls_delta>", .{index}) catch return;
    for (deltas) |delta| {
        w.print("<delta index=\"{}\">", .{delta.index}) catch return;
        if (delta.id) |id| {
            w.print("<id>{s}</id>", .{id}) catch return;
        }
        if (delta.function_name) |name| {
            w.print("<function_name>{s}</function_name>", .{name}) catch return;
        }
        if (delta.function_arguments) |args| {
            w.print("<function_arguments>{s}</function_arguments>", .{args}) catch return;
        }
        w.writeAll("</delta>") catch return;
    }
    w.writeAll("</tool_calls_delta></chunk></response>") catch return;
    // std.debug.print("chunk tool_calls_delta {s}\n", .{buf.items});

    _ = std.posix.write(conn_fd, buf.items) catch return;
    _ = std.posix.write(conn_fd, "\n") catch return;
}
