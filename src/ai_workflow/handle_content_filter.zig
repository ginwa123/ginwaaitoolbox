const std = @import("std");
const tree1_mod = @import("tree1");
const agent = tree1_mod.agent;
const logger_mod = tree1_mod.logger;
const sqlite = tree1_mod.sqlite;
const save_message = @import("save_message.zig");
const send_response = @import("send_response.zig");
const send_error = @import("send_error.zig");

pub fn run(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,
    conn_fd: std.posix.fd_t,
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    current_agent: []const u8,
    session_name: ?[]const u8,
    loop_counter: u32,
    res_dynamic_agent: agent.CallResponse,
) !bool {
    logger.infoFmt("FINISH REASON CONTENT FILTER - content was filtered due to safety policies", .{}) catch {};

    // Save the filtered response to history
    save_message.run(allocator, db, session_id, model, cwd, null, res_dynamic_agent, agent.Role.assistant.toStr(), null, null, null, current_agent, session_name, loop_counter) catch |err| {
        logger.errFmt("saveMessage error: {s}", .{@errorName(err)}) catch {};
    };

    // Send error response to client with content_filter finish reason
    // The response content may be empty or contain partial filtered content
    if (res_dynamic_agent.content) |c| {
        if (c.len > 0) {
            // Send the partial content with content_filter finish reason
            send_response.run(allocator, conn_fd, logger, res_dynamic_agent, "content_filter");
        } else {
            // No content, send error message
            send_error.run(allocator, conn_fd, logger, "Content was filtered due to safety policies. Please rephrase your request.", "user_choice");
        }
    } else {
        // No content, send error message
        send_error.run(allocator, conn_fd, logger, "Content was filtered due to safety policies. Please rephrase your request.", "user_choice");
    }
    
    return true; // Signal caller to break the loop
}

test {
    _ = @import("handle_content_filter_test.zig");
}
