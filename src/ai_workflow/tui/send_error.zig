const std = @import("std");
const tree1_mod = @import("nalarcore");
const logger_mod = tree1_mod.logger;
const http_server = @import("nalarcore").http_server;

pub fn run(allocator: std.mem.Allocator, session_id: []const u8, logger: *logger_mod.Logger, err_msg: []const u8, finish_reason: ?[]const u8) void {
    const sse_manager = http_server.getGlobalSseManager() orelse return;

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

    const event = http_server.SseEvent{
        .event_type = "error",
        .data = buf.items,
    };
    sse_manager.sendEvent(session_id, event) catch |err| {
        logger.errFmt("SSE send error: {s}", .{@errorName(err)}) catch {};
    };
}

test {
    _ = @import("send_error_test.zig");
}
