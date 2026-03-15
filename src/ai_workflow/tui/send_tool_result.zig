const std = @import("std");
const tree1_mod = @import("nalarcore");
const logger_mod = tree1_mod.logger;
const http_server = @import("nalarcore").http_server;

pub fn SendToolResult(allocator: std.mem.Allocator, session_id: []const u8, logger: *logger_mod.Logger, result: []const u8, tool_call_id: []const u8, tool_name: []const u8, command: ?[]const u8) void {
    const sse_manager = http_server.getGlobalSseManager() orelse return;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var w = buf.writer(allocator);

    w.writeAll("<response><tool_result><tool_call_id>") catch return;
    w.writeAll(tool_call_id) catch return;
    w.writeAll("</tool_call_id><tool_name>") catch return;
    w.writeAll(tool_name) catch return;
    w.writeAll("</tool_name>") catch return;

    if (command) |cmd| {
        w.writeAll("<command>") catch return;
        w.writeAll(cmd) catch return;
        w.writeAll("</command>") catch return;
    }

    w.writeAll("<result>") catch return;

    w.writeAll(result) catch return;

    w.writeAll("</result></tool_result></response>") catch return;

    logger.traceFmt("SEND TOOL RESULT XML: {s}", .{buf.items}) catch {};

    const event = http_server.SseEvent{
        .event_type = "tool_result",
        .data = buf.items,
    };
    sse_manager.sendEvent(session_id, event) catch |err| {
        logger.errFmt("SSE send tool result: {s}", .{@errorName(err)}) catch {};
    };
}

test {
    _ = @import("send_tool_result_test.zig");
}
