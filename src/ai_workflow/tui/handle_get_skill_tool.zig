const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const logger_mod = tree1_mod.logger;
const sqlite = tree1_mod.sqlite;
const get_skill_tool = tree1_mod.get_skill_tool;
const skills = tree1_mod.skills;

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
    session_name: ?[]const u8,
    loop_counter: u32,
    messages_list: *std.ArrayList(agent.AgentMessage),
    tool_call: agent.ToolCall,
    agent_temperature: f32,
    is_thinking: bool,
) !void {
    _ = messages_list;
    // Parse arguments JSON to GetSkillInput
    const parsed = std.json.parseFromSlice(
        get_skill_tool.GetSkillInput,
        allocator,
        tool_call.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        logger.errFmt("Failed to parse get_skill arguments: {s}", .{@errorName(err)}) catch {};
        return;
    };
    defer parsed.deinit();

    const result = get_skill_tool.executeGetSkillToString(allocator, parsed.value) catch |err| blk: {
        logger.errFmt("Error executing get_skill: {s}", .{@errorName(err)}) catch {};
        break :blk "<skill_name></skill_name><content></content><loaded>false</loaded><error>Failed to get skill</error>";
    };
    defer allocator.free(result);

    logger.debugFmt("GET_SKILL RESULT: {s}", .{result}) catch {};

    // Save skill to database for persistence (tool validates and returns content)
    // Extract skill_name from parsed.value since it's already validated
    const content = skills.parseSkill(allocator, parsed.value.skill_name);
    defer if (content) |c| allocator.free(c);

    if (content != null) {
        const already_loaded = save_skill_mod.isLoaded(allocator, db, session_id, parsed.value.skill_name) catch false;
        if (!already_loaded) {
            // Save skill to database for persistence
            save_skill_mod.run(allocator, db, logger, session_id, parsed.value.skill_name, content.?) catch |err| {
                logger.errFmt("Failed to save skill to database: {s}", .{@errorName(err)}) catch {};
            };
            // Send updated skills list to TUI
            send_skill_mod.run(allocator, db, logger, conn_fd, session_id);
        } else {
            logger.debugFmt("Skill '{s}' already loaded, skipping duplicate", .{parsed.value.skill_name}) catch {};
        }
    }

    const current_agent_state = try get_current_agent_by_session_id.run(allocator, db, session_id);
    const current_agent_final = current_agent_state.agent;
    _ = save_message.run(allocator, db, session_id, model, cwd, result, null, null, null, "tool", "tool", null, tool_call.id, current_agent_final, session_name, loop_counter, agent_temperature, is_thinking) catch {};
    _ = send_tool_result.run(allocator, conn_fd, logger, result, tool_call.id, tool_call.function.name, null);
}
