const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const logger_mod = tree1_mod.logger;
const sqlite = tree1_mod.sqlite;
const config_mod = @import("../../modules/config/config.zig");
const save_message = @import("save_message.zig");
const send_response = @import("send_response.zig");
const handle_change_agent_tool = @import("handle_change_agent_tool.zig");
const handle_bash_tool = @import("handle_bash_tool.zig");
const handle_read_file_tool = @import("handle_read_file_tool.zig");
const handle_search_tool = @import("handle_search_tool.zig");
const handle_write_file_tool = @import("handle_write_file_tool.zig");
const handle_text_replace_tool = @import("handle_text_replace_tool.zig");
const handle_list_skills_tool = @import("handle_list_skills_tool.zig");
const handle_get_skill_tool = @import("handle_get_skill_tool.zig");
const handle_remove_skill_tool = @import("handle_remove_skill_tool.zig");
const handle_spawn_sub_agent = @import("handle_spawn_sub_agent.zig");
const handle_mcp_tool = @import("handle_mcp_tool.zig");
const loop_detector = tree1_mod.loop_detector;
const get_current_agent_by_session_id = @import("get_current_agent_by_session_id.zig");

// Forward declaration for TUIWorkflow
const TUIWorkflow = @import("tui_workflow.zig").TUIWorkflow;

pub fn run(
    allocator: std.mem.Allocator,
    tui_workflow: *TUIWorkflow,
    db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    session_name: ?[]const u8,
    loop_counter: u32,
    messages_list: *std.ArrayList(agent.AgentMessage),
    res_dynamic_agent: agent.CallResponse,
    agent_temperature: *f32,
    isThinking: *bool,
    api_key: []const u8,
    base_url: []const u8,
    config: *const config_mod.LlmConfig,
) !void {
    logger.infoFmt("[HANDLE_TOOL] START - finish_reason: {?s}, tool_calls: {}", .{ if (res_dynamic_agent.finish_reason) |fr| fr.toStr() else null, res_dynamic_agent.tool_calls != null }) catch {};
    if (res_dynamic_agent.tool_calls) |tc| {
        logger.infoFmt("[HANDLE_TOOL] tool_calls count: {}", .{tc.len}) catch {};
    } else {
        logger.warnFmt("[HANDLE_TOOL] tool_calls is NULL!", .{}) catch {};
    }
    send_response.run(allocator, session_id, logger, res_dynamic_agent, null);
    if (res_dynamic_agent.tool_calls) |tc| {
        // Add assistant message with tool_calls to history
        var assistant_tool_calls = try allocator.alloc(agent.ToolCall, tc.len);
        for (tc, 0..) |tool_call, i| {
            assistant_tool_calls[i] = .{
                .id = try allocator.dupe(u8, tool_call.id),
                .function = .{
                    .name = try allocator.dupe(u8, tool_call.function.name),
                    .arguments = try allocator.dupe(u8, tool_call.function.arguments),
                },
            };
        }

        // Fetch current agent from DB for save_message
        const current_agent_state = try get_current_agent_by_session_id.run(
            allocator,
            db,
            session_id,
        );
        const current_agent_for_save = current_agent_state.agent;

        _ = try save_message.run(
            allocator, db, session_id, model, cwd,
            null,
            res_dynamic_agent.content,
            if (res_dynamic_agent.finish_reason) |fr| fr.toStr() else null,
            res_dynamic_agent.reasoning_content,
            agent.Role.assistant.toStr(), null, assistant_tool_calls, null, current_agent_for_save, session_name, loop_counter, agent_temperature.*, isThinking.*);

        // Execute each tool call and add tool result messages
        for (tc) |tool_call| {
            logger.infoFmt("[HANDLE_TOOL] Processing tool: '{s}' (id: '{s}')", .{ tool_call.function.name, tool_call.id }) catch {};
            if (tui_workflow.loop_detector.check(tool_call.function.arguments)) {
                const warning = try std.fmt.allocPrint(
                    allocator,
                    "WARNING: Identical command repeated: {s}\n" ++
                        "Empty output means no results found — do NOT retry. Proceed with what you know.",
                    .{tool_call.function.arguments},
                );
                const tool_result_msg = agent.AgentMessage{
                    .role = .tool,
                    .content = warning,
                    .tool_call_id = try allocator.dupe(u8, tool_call.id),
                };
                try messages_list.append(allocator, tool_result_msg);
                continue;
            }

            if (std.mem.eql(u8, tool_call.function.name, "change_agent_tool")) {
                try handle_change_agent_tool.run(allocator, db, logger, session_id, model, cwd, session_name, loop_counter, messages_list, tool_call, agent_temperature, isThinking);
            }
            if (std.mem.eql(u8, tool_call.function.name, "bash")) {
                _ = handle_bash_tool.run(allocator, db, logger, session_id, model, cwd, session_name, loop_counter, messages_list, tool_call, agent_temperature.*, isThinking.*) catch |err| {
                    logger.errFmt("Error handling bash tool: {s}", .{@errorName(err)}) catch {};
                };
            }

            if (std.mem.eql(u8, tool_call.function.name, "read_file")) {
                _ = handle_read_file_tool.run(allocator, db, logger, session_id, model, cwd, session_name, loop_counter, messages_list, tool_call, agent_temperature.*, isThinking.*) catch |err| {
                    logger.errFmt("Error handling read_file tool: {s}", .{@errorName(err)}) catch {};
                };
            }

            if (std.mem.eql(u8, tool_call.function.name, "search")) {
                _ = handle_search_tool.run(allocator, db, logger, session_id, model, cwd, session_name, loop_counter, messages_list, tool_call, agent_temperature.*, isThinking.*) catch |err| {
                    logger.errFmt("Error handling search tool: {s}", .{@errorName(err)}) catch {};
                };
            }

            if (std.mem.eql(u8, tool_call.function.name, "write_file")) {
                _ = handle_write_file_tool.run(allocator, db, logger, session_id, model, cwd, session_name, loop_counter, messages_list, tool_call, agent_temperature.*, isThinking.*) catch |err| {
                    logger.errFmt("Error handling write_file tool: {s}", .{@errorName(err)}) catch {};
                };
            }

            if (std.mem.eql(u8, tool_call.function.name, "text_replace")) {
                _ = handle_text_replace_tool.run(allocator, db, logger, session_id, model, cwd, session_name, loop_counter, messages_list, tool_call, agent_temperature.*, isThinking.*) catch |err| {
                    logger.errFmt("Error handling text_replace tool: {s}", .{@errorName(err)}) catch {};
                };
            }

            if (std.mem.eql(u8, tool_call.function.name, "list_skills")) {
                handle_list_skills_tool.run(allocator, db, logger, session_id, model, cwd, session_name, loop_counter, messages_list, tool_call, agent_temperature.*, isThinking.*);
            }

            if (std.mem.eql(u8, tool_call.function.name, "get_skill")) {
                _ = try handle_get_skill_tool.run(allocator, db, logger, session_id, model, cwd, session_name, loop_counter, messages_list, tool_call, agent_temperature.*, isThinking.*);
            }

            if (std.mem.eql(u8, tool_call.function.name, "remove_skill")) {
                _ = try handle_remove_skill_tool.run(allocator, db, logger, session_id, model, cwd, session_name, loop_counter, messages_list, tool_call, agent_temperature.*, isThinking.*);
            }

            if (std.mem.eql(u8, tool_call.function.name, "spawn_sub_agent")) {
                try handle_spawn_sub_agent.run(allocator, db, logger, session_id, model, cwd, session_name, loop_counter, messages_list, tool_call, agent_temperature.*, isThinking.*, api_key, base_url);
            }

            // Check if tool has underscore (potential MCP tool)
            const has_underscore = std.mem.indexOf(u8, tool_call.function.name, "_") != null;
            logger.infoFmt("[HANDLE_TOOL] Tool '{s}' has_underscore: {}", .{ tool_call.function.name, has_underscore }) catch {};

            // Fallback: Check if this is an MCP tool (has underscore in name)
            // MCP tools are named like "context7_resolve-library-id"
            if (has_underscore) {
                // Check if it's not one of the built-in tools
                const is_builtin = std.mem.eql(u8, tool_call.function.name, "change_agent_tool") or
                    std.mem.eql(u8, tool_call.function.name, "bash") or
                    std.mem.eql(u8, tool_call.function.name, "read_file") or
                    std.mem.eql(u8, tool_call.function.name, "write_file") or
                    std.mem.eql(u8, tool_call.function.name, "search") or
                    std.mem.eql(u8, tool_call.function.name, "text_replace") or
                    std.mem.eql(u8, tool_call.function.name, "list_skills") or
                    std.mem.eql(u8, tool_call.function.name, "get_skill") or
                    std.mem.eql(u8, tool_call.function.name, "remove_skill") or
                    std.mem.eql(u8, tool_call.function.name, "spawn_sub_agent");

                if (!is_builtin) {
                    logger.infoFmt("Treating as MCP tool: {s}", .{tool_call.function.name}) catch {};
                    handle_mcp_tool.run(allocator, db, logger, session_id, model, cwd, session_name, loop_counter, messages_list, tool_call, agent_temperature.*, isThinking.*, config) catch |err| {
                        logger.errFmt("Error handling MCP tool: {s}", .{@errorName(err)}) catch {};
                    };
                }
            }
        }
        logger.debugFmt("All tools executed, continuing to next LLM call. Message count: {}", .{messages_list.items.len}) catch {};
    } else {
        logger.warnFmt("Tool function not found", .{}) catch {};
    }
    // Continue to next LLM call - no break, loop continues naturally
    logger.debugFmt("Tool calls processing complete, looping back for next API call...", .{}) catch {};
}

test {
    _ = @import("handle_tool_test.zig");
}
