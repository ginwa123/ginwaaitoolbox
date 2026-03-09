const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const logger_mod = tree1_mod.logger;
const sqlite = tree1_mod.sqlite;
const list_skills_tool = tree1_mod.list_skills_tool;

const get_current_agent_by_session_id = @import("get_current_agent_by_session_id.zig");
const save_message = @import("save_message.zig");
const send_tool_result = @import("send_tool_result.zig");

pub fn run(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,
    conn_fd: std.posix.fd_t,
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    _: []const u8,
    session_name: ?[]const u8,
    loop_counter: u32,
    messages_list: *std.ArrayList(agent.AgentMessage),
    tool_call: agent.ToolCall,
) void {
    const result = list_skills_tool.executeListSkills(allocator) catch |err| blk: {
        logger.errFmt("Error executing list_skills: {s}", .{@errorName(err)}) catch {};
        break :blk "{\"error\": \"Failed to list skills\"}";
    };

    logger.debugFmt("LIST_SKILLS RESULT: {s}", .{result}) catch {};

    const tool_result_msg = agent.AgentMessage{
        .role = .tool,
        .content = result,
        .tool_call_id = allocator.dupe(u8, tool_call.id) catch return,
    };
    messages_list.append(allocator, tool_result_msg) catch return;
    const current_agent_res = get_current_agent_by_session_id.run(allocator, db, session_id) catch return;

    save_message.run(allocator, db, session_id, model, cwd, result, null, null, null, "tool", "tool", null, tool_call.id, current_agent_res, session_name, loop_counter) catch {};
    send_tool_result.run(allocator, conn_fd, logger, result, tool_call.id, tool_call.function.name, null);
}
