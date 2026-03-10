const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const search_tool = tree1_mod.search_tool;
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
    // Parse arguments JSON to SearchInput
    const parsed = try std.json.parseFromSlice(
        search_tool.SearchInput,
        allocator,
        tool_call.function.arguments,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    var search_result = search_tool.executeSearch(allocator, parsed.value) catch |err| {
        logger.errFmt("Error executing search: {s}", .{@errorName(err)}) catch {};
        const err_str = try std.fmt.allocPrint(allocator, "Error executing search: {s}", .{@errorName(err)});
        defer allocator.free(err_str);
        const tool_result_msg = agent.AgentMessage{
            .role = .tool,
            .content = err_str,
            .tool_call_id = try allocator.dupe(u8, tool_call.id),
        };
        _ = try messages_list.append(allocator, tool_result_msg);
        _ = try save_message.run(allocator, db, session_id, model, cwd, err_str, null, null, null, "tool", "tool", null, tool_call.id, current_agent, session_name, loop_counter, agent_temperature, is_thinking);
        _ = send_tool_result.run(allocator, session_id, logger, err_str, tool_call.id, tool_call.function.name, null);
        return;
    };
    
    // Convert search result to string format
    const res_search = try search_tool.searchResultToString(allocator, search_result);
    defer allocator.free(res_search);
    search_result.deinit(allocator);
    
    try logger.debugFmt("RESPONSE TOOLS (search): {s}", .{res_search});

    const tool_result_msg = agent.AgentMessage{
        .role = .tool,
        .content = res_search,
        .tool_call_id = try allocator.dupe(u8, tool_call.id),
    };
    _ = try messages_list.append(allocator, tool_result_msg);
    _ = try save_message.run(allocator, db, session_id, model, cwd, res_search, null, null, null, "tool", "tool", null, tool_call.id, current_agent, session_name, loop_counter, agent_temperature, is_thinking);
    _ = send_tool_result.run(allocator, session_id, logger, res_search, tool_call.id, tool_call.function.name, null);
    logger.debugFmt("Search tool result added to messages", .{}) catch {};
}

test {
    _ = @import("handle_search_tool_test.zig");
}
