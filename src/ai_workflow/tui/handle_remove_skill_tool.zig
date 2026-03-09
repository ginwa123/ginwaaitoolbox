const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const logger_mod = tree1_mod.logger;
const sqlite = tree1_mod.sqlite;
const remove_skill_tool = tree1_mod.remove_skill_tool;

const save_skill_mod = @import("save_skill.zig");
const send_skill_mod = @import("send_skill.zig");
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
) !void {
    _ = messages_list;

    // Parse arguments JSON to RemoveSkillInput
    const parsed = std.json.parseFromSlice(
        remove_skill_tool.RemoveSkillInput,
        allocator,
        tool_call.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        logger.errFmt("Failed to parse remove_skill arguments: {s}", .{@errorName(err)}) catch {};
        return;
    };
    defer parsed.deinit();

    const result = remove_skill_tool.executeRemoveSkillToString(allocator, parsed.value) catch |err| blk: {
        logger.errFmt("Error executing remove_skill: {s}", .{@errorName(err)}) catch {};
        break :blk try std.fmt.allocPrint(allocator,
            \\<skill_name>{s}</skill_name>
            \\<removed>false</removed>
            \\<error>{s}</error>
        , .{ parsed.value.skill_name, @errorName(err) });
    };
    defer allocator.free(result);

    // Execute SQL to remove skill from database
    const sql = "DELETE FROM session_skills WHERE session_id = ? AND skill_name = ?";
    db.exec(allocator, sql, &.{ session_id, parsed.value.skill_name }) catch |err| {
        logger.errFmt("Failed to remove skill from database: {s}", .{@errorName(err)}) catch {};
    };

    logger.debugFmt("REMOVE_SKILL RESULT: {s}", .{result}) catch {};

    // Send updated skills list to TUI after removal
    send_skill_mod.run(allocator, db, logger, conn_fd, session_id);

    const current_agent_final = try get_current_agent_by_session_id.run(allocator, db, session_id);
    _ = save_message.run(allocator, db, session_id, model, cwd, result, null, null, null, "tool", "tool", null, tool_call.id, current_agent_final, session_name, loop_counter) catch {};
    _ = send_tool_result.run(allocator, conn_fd, logger, result, tool_call.id, tool_call.function.name, null);
}
