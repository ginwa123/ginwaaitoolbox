const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const text_replace_tool = tree1_mod.text_replace;
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
    // Parse arguments JSON to TextReplaceInput
    const parsed = try std.json.parseFromSlice(
        text_replace_tool.TextReplaceInput,
        allocator,
        tool_call.function.arguments,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const text_replace_result = text_replace_tool.text_replace(
        allocator,
        parsed.value.path,
        parsed.value.old_str,
        parsed.value.new_str,
    ) catch |err| {
        logger.errFmt("Error executing text_replace: {s}", .{@errorName(err)}) catch {};
        const err_str = try std.fmt.allocPrint(allocator, "Error replacing text: {s}", .{@errorName(err)});
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
    
    // Convert text_replace result to string format
    const res_replace = try text_replace_tool.textReplaceToString(allocator, text_replace_result);
    defer allocator.free(res_replace);
    text_replace_result.deinit(allocator);
    
    try logger.debugFmt("RESPONSE TOOLS (text_replace): {s}", .{res_replace});

    const tool_result_msg = agent.AgentMessage{
        .role = .tool,
        .content = res_replace,
        .tool_call_id = try allocator.dupe(u8, tool_call.id),
    };
    _ = try messages_list.append(allocator, tool_result_msg);
    _ = try save_message.run(allocator, db, session_id, model, cwd, res_replace, null, null, null, "tool", "tool", null, tool_call.id, current_agent, session_name, loop_counter);
    _ = send_tool_result.run(allocator, conn_fd, logger, res_replace, tool_call.id, tool_call.function.name, null);
    logger.debugFmt("Text replace tool result added to messages", .{}) catch {};
}
