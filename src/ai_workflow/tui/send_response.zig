const std = @import("std");
const tree1_mod = @import("nalarcore");
const logger_mod = tree1_mod.logger;
const agent = tree1_mod.agent;

pub fn run(allocator: std.mem.Allocator, conn_fd: std.posix.fd_t, logger: *logger_mod.Logger, response: agent.CallResponse, override_finish_reason: ?[]const u8) void {
    if (conn_fd < 0) return;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var w = buf.writer(allocator);

    w.writeAll("<response><choices><choice><index>0</index><message><role>assistant</role>") catch return;

    if (response.content) |content| {
        w.writeAll("<content>") catch return;
        w.writeAll(content) catch return;
        w.writeAll("</content>") catch return;
    }

    if (response.reasoning_content) |rc| {
        w.writeAll("<reasoning_content>") catch return;
        w.writeAll(rc) catch return;
        w.writeAll("</reasoning_content>") catch return;
    }

    if (response.tool_calls) |tc| {
        w.writeAll("<tool_calls>") catch return;
        for (tc) |tci| {
            w.writeAll("<tool_call id=\"") catch return;
            w.writeAll(tci.id) catch return;
            w.writeAll("\" type=\"function\"><function><name>") catch return;
            w.writeAll(tci.function.name) catch return;
            w.writeAll("</name><arguments>") catch return;
            w.writeAll(tci.function.arguments) catch return;
            w.writeAll("</arguments></function></tool_call>") catch return;
        }
        w.writeAll("</tool_calls>") catch return;
    }

    w.writeAll("</message>") catch return;

    if (override_finish_reason) |fr| {
        if (fr.len > 0) {
            w.writeAll("<finish_reason>") catch return;
            w.writeAll(fr) catch return;
            w.writeAll("</finish_reason>") catch return;
        }
    } else if (response.finish_reason) |fr| {
        w.writeAll("<finish_reason>") catch return;
        w.writeAll(fr.toStr()) catch return;
        w.writeAll("</finish_reason>") catch return;
    }

    // Add usage information
    w.print("<usage><prompt_tokens>{}</prompt_tokens><completion_tokens>{}</completion_tokens><total_tokens>{}</total_tokens></usage>", .{ response.usage.prompt_tokens, response.usage.completion_tokens, response.usage.total_tokens }) catch return;

    w.writeAll("</choice></choices></response>") catch return;

    logger.infoFmt("SEND RESPONSE XML: {s}", .{buf.items}) catch {};

    _ = std.posix.write(conn_fd, buf.items) catch |err| {
        if (err != error.BrokenPipe) {
            logger.errFmt("Send Response error {s}", .{@errorName(err)}) catch {};
        }
    };
    _ = std.posix.write(conn_fd, "\n") catch {};
}

test {
    _ = @import("send_response_test.zig");
}
