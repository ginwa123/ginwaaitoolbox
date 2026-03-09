const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const write_file_tool = tree1_mod.write_file;
const logger_mod = tree1_mod.logger;
const sqlite = tree1_mod.sqlite;
const save_message = @import("save_message.zig");
const send_tool_result = @import("send_tool_result.zig");
const get_current_agent_by_session_id = @import("get_current_agent_by_session_id.zig");

pub fn run(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,
    conn_fd: std.posix.fd_t,
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    session_name: ?[]const u8,
    loop_counter: u32,
    messages_list: *std.ArrayList(agent.AgentMessage),
    tool_call: agent.ToolCall,
) !void {
    // Fetch current agent from DB
    const current_agent = try get_current_agent_by_session_id.run(
        allocator,
        db,
        session_id,
    );
    // Parse arguments JSON to WriteFileInput
    const parsed = try std.json.parseFromSlice(
        write_file_tool.WriteFileInput,
        allocator,
        tool_call.function.arguments,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    // Convert WriteFileInput to WriteFileOptions for the write_file function
    const opts = write_file_tool.WriteFileOptions{
        .content = parsed.value.content,
        .start_line = parsed.value.start_line,
        .end_line = parsed.value.end_line,
    };

    const write_result = write_file_tool.write_file(allocator, parsed.value.path, opts) catch |err| {
        logger.errFmt("Error executing write_file: {s}", .{@errorName(err)}) catch {};
        const err_str = try std.fmt.allocPrint(allocator, "Error writing file: {s}", .{@errorName(err)});
        defer allocator.free(err_str);
        const tool_result_msg = agent.AgentMessage{
            .role = .tool,
            .content = err_str,
            .tool_call_id = try allocator.dupe(u8, tool_call.id),
        };
        _ = try messages_list.append(allocator, tool_result_msg);
        _ = try save_message.run(allocator, db, session_id, model, cwd, err_str, null, null, null, "tool", "tool", null, tool_call.id, current_agent, session_name, loop_counter);
        _ = send_tool_result.run(allocator, conn_fd, logger, err_str, tool_call.id, tool_call.function.name, null);
        return;
    };
    
    // Convert write result to string format
    const res_write = try write_file_tool.writeFileToString(allocator, write_result);
    defer allocator.free(res_write);
    write_result.deinit(allocator);
    
    try logger.debugFmt("RESPONSE TOOLS (write_file): {s}", .{res_write});

    const tool_result_msg = agent.AgentMessage{
        .role = .tool,
        .content = res_write,
        .tool_call_id = try allocator.dupe(u8, tool_call.id),
    };
    _ = try messages_list.append(allocator, tool_result_msg);
    _ = try save_message.run(allocator, db, session_id, model, cwd, res_write, null, null, null, "tool", "tool", null, tool_call.id, current_agent, session_name, loop_counter);
    _ = send_tool_result.run(allocator, conn_fd, logger, res_write, tool_call.id, tool_call.function.name, null);
    logger.debugFmt("Write file tool result added to messages", .{}) catch {};
}

test {
    _ = @import("handle_write_file_tool_test.zig");
}
