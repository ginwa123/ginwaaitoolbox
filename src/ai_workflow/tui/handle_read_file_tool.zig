const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const read_file_mod = tree1_mod.read_file;
const tool_models = tree1_mod.tool_models;
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
    agent_temperature: f32,
    is_thinking: bool,
) !void {
    // Fetch current agent from DB
    const current_agent_state = try get_current_agent_by_session_id.run(
        allocator,
        db,
        session_id,
    );
    const current_agent = current_agent_state.agent;
    // Parse arguments JSON to ReadFileInput
    const parsed = try std.json.parseFromSlice(
        tool_models.ReadFileInput,
        allocator,
        tool_call.function.arguments,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const read_opts = read_file_mod.ReadFileOptions{
        .offset = parsed.value.offset,
        .limit = parsed.value.limit,
    };

    const read_result = read_file_mod.read_file(allocator, parsed.value.path, read_opts) catch |err| {
        logger.errFmt("Error reading file: {s}", .{@errorName(err)}) catch {};
        const err_str = try std.fmt.allocPrint(allocator, "Error reading file: {s}", .{@errorName(err)});
        const tool_result_msg = agent.AgentMessage{
            .role = .tool,
            .content = err_str,
            .tool_call_id = try allocator.dupe(u8, tool_call.id),
        };
        _ = try messages_list.append(allocator, tool_result_msg);
        _ = try save_message.run(allocator, db, session_id, model, cwd, err_str, null, null, null, "tool", "tool", null, tool_call.id, current_agent, session_name, loop_counter, agent_temperature, is_thinking);
        _ = send_tool_result.run(allocator, conn_fd, logger, err_str, tool_call.id, tool_call.function.name, null);
        return;
    };
    defer read_result.deinit(allocator);

    const res_content = try read_file_mod.readFileToString(allocator, read_result);
    defer allocator.free(res_content);

    try logger.debugFmt("RESPONSE TOOLS: {s}", .{res_content});

    const tool_result_msg = agent.AgentMessage{
        .role = .tool,
        .content = res_content,
        .tool_call_id = try allocator.dupe(u8, tool_call.id),
    };
    _ = try messages_list.append(allocator, tool_result_msg);
    _ = try save_message.run(allocator, db, session_id, model, cwd, res_content, null, null, null, "tool", "tool", null, tool_call.id, current_agent, session_name, loop_counter, agent_temperature, is_thinking);
    _ = send_tool_result.run(allocator, conn_fd, logger, res_content, tool_call.id, tool_call.function.name, null);
    logger.debugFmt("Tool result added to messages", .{}) catch {};
}

test {
    _ = @import("handle_read_file_tool_test.zig");
}
