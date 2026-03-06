const std = @import("std");
const tree1_mod = @import("tree1");
const agent = tree1_mod.agent;
const bash_tool = tree1_mod.bash_tool;
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
    current_agent: []const u8,
    session_name: ?[]const u8,
    loop_counter: u32,
    messages_list: *std.ArrayList(agent.AgentMessage),
    tool_call: agent.ToolCall,
) !void {
    // Parse arguments JSON to BashInput
    const parsed = try std.json.parseFromSlice(
        tool_models.BashInput,
        allocator,
        tool_call.function.arguments,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const res_bash = bash_tool.executeBash(allocator, parsed.value) catch |err| blk: {
        logger.errFmt("Error executing bash: {s}", .{@errorName(err)}) catch {};
        break :blk "Error executing command";
    };
    try logger.debugFmt("RESPONSE TOOLS: {s}", .{res_bash});

    const tool_result_msg = agent.AgentMessage{
        .role = .tool,
        .content = res_bash,
        .tool_call_id = try allocator.dupe(u8, tool_call.id),
    };
    try messages_list.append(allocator, tool_result_msg);
    _ = try save_message.run(allocator, db, session_id, model, cwd, res_bash, null, "tool", "tool", null, tool_call.id, current_agent, session_name, loop_counter);
    send_tool_result.run(allocator, conn_fd, logger, res_bash, tool_call.id, tool_call.function.name, null);
    logger.debugFmt("Tool result added to messages", .{}) catch {};
}
