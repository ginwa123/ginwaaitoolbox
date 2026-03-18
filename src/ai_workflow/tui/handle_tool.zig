const std = @import("std");
const root_mod = @import("nalarcore");
const agent = root_mod.agent;
const logger_mod = root_mod.logger;
const sqlite = root_mod.sqlite;
const config_mod = @import("../../modules/config/config.zig");
const SaveMessage = @import("save_message.zig").SaveMessage;
const on_event_sent = @import("on_event_sent.zig");
const SendToolResult = on_event_sent.SendToolResult;
const SendResponse = on_event_sent.SendResponse;
const handle_set_agent_properties = @import("handle_set_agent_properties.zig");
const handle_bash_tool = @import("handle_bash_tool.zig");
const handle_read_file_tool = @import("handle_read_file_tool.zig");
const handle_search_tool = @import("handle_search_tool.zig");
const handle_write_file_tool = @import("handle_write_file_tool.zig");
const handle_text_replace_tool = @import("handle_text_replace_tool.zig");
const handle_list_skills_tool = @import("handle_list_skills_tool.zig");
const handle_get_skill_tool = @import("handle_get_skill_tool.zig");
const handle_remove_skill_tool = @import("handle_remove_skill_tool.zig");
const handle_get_agent_tool = @import("handle_get_agent_tool.zig");
const handle_list_agents_tool = @import("handle_list_agents_tool.zig");
const handle_spawn_sub_agent = @import("handle_spawn_sub_agent.zig");
const handle_mcp_tool = @import("handle_mcp_tool.zig");
const SaveSkill = @import("save_skill.zig").SaveSkill;
const SaveAgent = @import("save_agent.zig").SaveAgent;
const loop_detector = root_mod.loop_detector;
const get_current_agent_by_session_id = @import("get_current_agent_by_session_id.zig");
const tool_models = root_mod.tool_models;

// Forward declaration for TUIWorkflow
const TUIWorkflow = @import("tui_workflow.zig").TUIWorkflow;

/// Context needed for tool handling - passed to helper functions
const ToolContext = struct {
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    session_name: ?[]const u8,
    loop_counter: u32,
    messages_list: *std.ArrayList(agent.AgentMessage),
    agent_temperature: f32,
    is_thinking: bool,
    current_agent_for_save: []const u8,
};

/// Helper to handle tool result: append to messages, save to DB, send to client
fn handleToolResult(ctx: ToolContext, tool_call: agent.ToolCall, content: []const u8) !void {
    const tool_result_msg = agent.AgentMessage{
        .role = .tool,
        .content = try ctx.allocator.dupe(u8, content),
        .tool_call_id = try ctx.allocator.dupe(u8, tool_call.id),
    };
    try ctx.messages_list.append(ctx.allocator, tool_result_msg);

    _ = try SaveMessage(ctx.allocator, ctx.db, .{
        .session_id = ctx.session_id,
        .model = ctx.model,
        .cwd = ctx.cwd,
        .content = content,
        .response_content = null,
        .response_finish_reason = null,
        .response_reasoning_content = null,
        .role = agent.Role.tool.toStr(),
        .finish_reason = agent.FinishReason.tool.toStr(),
        .tool_calls = null,
        .tool_call_id = tool_call.id,
        .agent_name = ctx.current_agent_for_save,
        .session_name = ctx.session_name,
        .loop_index = ctx.loop_counter,
        .temperature = ctx.agent_temperature,
        .is_thinking = ctx.is_thinking,
        .prompt_tokens = 0,
        .completion_tokens = 0,
        .total_tokens = 0,
        .is_output = true,
        .is_input = false,
        .tool_name = tool_call.function.name,
    });

    SendToolResult(ctx.allocator, ctx.session_id, ctx.logger, content, tool_call.id, tool_call.function.name, null);
}

/// Helper to handle error for tools that return owned strings
fn handleToolError(ctx: ToolContext, tool_call: agent.ToolCall, err: anytype, err_prefix: []const u8) !void {
    const err_name = @errorName(err);
    const err_str = try std.fmt.allocPrint(ctx.allocator, "{s}: {s}", .{ err_prefix, err_name });
    try handleToolResult(ctx, tool_call, err_str);
}

pub fn HandleTool(
    allocator: std.mem.Allocator,
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
    base_tools: []const tool_models.AgentTool,
) !void {
    _ = SendResponse(allocator, session_id, logger, res_dynamic_agent.content, res_dynamic_agent.finish_reason, res_dynamic_agent.reasoning_content, res_dynamic_agent.usage, null);
    if (res_dynamic_agent.tool_calls) |tc| {
        var assistant_tool_calls = try allocator.alloc(agent.ToolCall, tc.len);
        var toolNames = try std.ArrayList([]const u8).initCapacity(allocator, tc.len);
        for (tc, 0..) |tool_call, i| {
            assistant_tool_calls[i] = .{
                .id = try allocator.dupe(u8, tool_call.id),
                .function = .{
                    .name = try allocator.dupe(u8, tool_call.function.name),
                    .arguments = try allocator.dupe(u8, tool_call.function.arguments),
                },
            };
            _ = try toolNames.append(allocator, tool_call.function.name);
        }

        // Fetch current agent from DB for save_message
        const current_agent_state = try get_current_agent_by_session_id.run(
            allocator,
            db,
            session_id,
        );
        const current_agent_for_save = current_agent_state.agent;

        var isSaving = false;
        for (assistant_tool_calls) |tool_call| {
            for (base_tools) |base_tool| {
                if (std.mem.eql(u8, tool_call.function.name, base_tool.function.name)) {
                    isSaving = true;
                    break;
                }
            }
        }
        if (!isSaving) {
            logger.infoFmt("[HANDLE_TOOL] Skipping saving assistant message, no tools matched", .{}) catch {};
            return;
        }

        _ = try SaveMessage(allocator, db, .{
            .session_id = session_id,
            .model = model,
            .cwd = cwd,
            .content = null,
            .response_content = res_dynamic_agent.content,
            .response_finish_reason = if (res_dynamic_agent.finish_reason) |fr| fr.toStr() else null,
            .response_reasoning_content = res_dynamic_agent.reasoning_content,
            .role = agent.Role.assistant.toStr(),
            .finish_reason = null,
            .tool_calls = assistant_tool_calls,
            .tool_call_id = null,
            .agent_name = current_agent_for_save,
            .session_name = session_name,
            .loop_index = loop_counter,
            .temperature = agent_temperature.*,
            .is_thinking = isThinking.*,
            .prompt_tokens = res_dynamic_agent.usage.prompt_tokens,
            .completion_tokens = res_dynamic_agent.usage.completion_tokens,
            .total_tokens = res_dynamic_agent.usage.total_tokens,
            .is_input = true,
            .is_output = false,
            .tool_name = try std.mem.join(allocator, ",", toolNames.items),
        });

        if (res_dynamic_agent.content) |c| {
            _ = c;
            _ = SendResponse(allocator, session_id, logger, res_dynamic_agent.content, res_dynamic_agent.finish_reason, res_dynamic_agent.reasoning_content, res_dynamic_agent.usage, null);
        }

        // Build context for tool handling
        var ctx = ToolContext{
            .allocator = allocator,
            .db = db,
            .logger = logger,
            .session_id = session_id,
            .model = model,
            .cwd = cwd,
            .session_name = session_name,
            .loop_counter = loop_counter,
            .messages_list = messages_list,
            .agent_temperature = agent_temperature.*,
            .is_thinking = isThinking.*,
            .current_agent_for_save = current_agent_for_save,
        };

        // Execute each tool call and add tool result messages
        for (tc) |tool_call| {
            logger.infoFmt("[HANDLE_TOOL] Processing tool: '{s}' (id: '{s}')", .{ tool_call.function.name, tool_call.id }) catch {};

            if (std.mem.eql(u8, tool_call.function.name, "set_agent_properties")) {
                const change_result = handle_set_agent_properties.run(allocator, tool_call) catch |err| {
                    const err_name = @errorName(err);
                    logger.errFmt("Error handling set_agent_properties tool: {s}", .{err_name}) catch {};
                    continue;
                };
                // Apply temperature and is_thinking changes
                if (change_result.temperature) |temp| {
                    agent_temperature.* = temp;
                }
                if (change_result.is_thinking) |think| {
                    isThinking.* = think;
                }
                // Create tool result message and add to messages_list
                const tool_result_msg = agent.AgentMessage{
                    .role = .tool,
                    .content = change_result.arguments,
                    .tool_call_id = change_result.tool_call_id,
                };
                _ = try messages_list.append(allocator, tool_result_msg);

                _ = try SaveMessage(allocator, db, .{
                    .session_id = session_id,
                    .model = model,
                    .cwd = cwd,
                    .content = change_result.arguments,
                    .response_content = null,
                    .response_finish_reason = null,
                    .response_reasoning_content = null,
                    .role = agent.Role.tool.toStr(),
                    .finish_reason = agent.FinishReason.tool.toStr(),
                    .tool_calls = null,
                    .tool_call_id = change_result.tool_call_id,
                    .agent_name = null,
                    .session_name = session_name,
                    .loop_index = loop_counter,
                    .temperature = agent_temperature.*,
                    .is_thinking = isThinking.*,
                    .prompt_tokens = 0,
                    .completion_tokens = 0,
                    .total_tokens = 0,
                    .is_input = true,
                    .is_output = false,
                    .tool_name = tool_call.function.name,
                });

                ctx.is_thinking = isThinking.*;
                ctx.agent_temperature = agent_temperature.*;

                SendToolResult(allocator, session_id, logger, change_result.arguments, change_result.tool_call_id, tool_call.function.name, null);
                logger.infoFmt("Agent properties updated: temp={any}, is_thinking={any}", .{ change_result.temperature, change_result.is_thinking }) catch {};
                continue;
            }

            if (std.mem.eql(u8, tool_call.function.name, "bash")) {
                const content = handle_bash_tool.runWithContext(allocator, tool_call, ctx.db, ctx.session_id) catch |err|
                    try std.fmt.allocPrint(allocator, "ERROR: bash failed: {s}", .{@errorName(err)});
                try handleToolResult(ctx, tool_call, content);
                continue;
            }

            if (std.mem.eql(u8, tool_call.function.name, "read_file")) {
                const content = handle_read_file_tool.run(allocator, tool_call) catch |err|
                    try std.fmt.allocPrint(allocator, "ERROR: read_file failed: {s}", .{@errorName(err)});
                try handleToolResult(ctx, tool_call, content);
                continue;
            }

            if (std.mem.eql(u8, tool_call.function.name, "search")) {
                const content = handle_search_tool.run(allocator, tool_call) catch |err|
                    try std.fmt.allocPrint(allocator, "ERROR: search failed: {s}", .{@errorName(err)});
                try handleToolResult(ctx, tool_call, content);
                continue;
            }

            if (std.mem.eql(u8, tool_call.function.name, "write_file")) {
                const content = handle_write_file_tool.run(allocator, tool_call) catch |err|
                    try std.fmt.allocPrint(allocator, "ERROR: write_file failed: {s}", .{@errorName(err)});
                try handleToolResult(ctx, tool_call, content);
                continue;
            }

            if (std.mem.eql(u8, tool_call.function.name, "text_replace")) {
                const content = handle_text_replace_tool.run(allocator, tool_call) catch |err|
                    try std.fmt.allocPrint(allocator, "ERROR: text_replace failed: {s}", .{@errorName(err)});
                try handleToolResult(ctx, tool_call, content);
                continue;
            }

            if (std.mem.eql(u8, tool_call.function.name, "list_skills")) {
                const result = handle_list_skills_tool.run(allocator);
                logger.debugFmt("LIST_SKILLS RESULT: {s}", .{result}) catch {};
                try handleToolResult(ctx, tool_call, result);
                continue;
            }

            if (std.mem.eql(u8, tool_call.function.name, "get_skill")) {
                const result = handle_get_skill_tool.run(allocator, tool_call) catch |err|
                    try std.fmt.allocPrint(allocator, "ERROR: get_skill failed: {s}", .{@errorName(err)});

                if (std.mem.indexOf(u8, result, "<loaded>true</loaded>") != null) {
                    if (std.mem.indexOf(u8, result, "<skill_name>")) |name_start| {
                        const name_begin = name_start + "<skill_name>".len;
                        if (std.mem.indexOf(u8, result[name_begin..], "</skill_name>")) |name_end| {
                            const skill_name = result[name_begin .. name_begin + name_end];
                            if (std.mem.indexOf(u8, result, "<content>")) |content_start| {
                                const content_begin = content_start + "<content>".len;
                                if (std.mem.indexOf(u8, result[content_begin..], "</content>")) |content_end| {
                                    const content = result[content_begin .. content_begin + content_end];
                                    // Save to database
                                    SaveSkill(allocator, db, logger, session_id, skill_name, content) catch |err| {
                                        const err_name = @errorName(err);
                                        logger.errFmt("Error saving skill to database: {s}", .{err_name}) catch {};
                                    };
                                }
                            }
                        }
                    }
                }

                try handleToolResult(ctx, tool_call, result);
                continue;
            }

            if (std.mem.eql(u8, tool_call.function.name, "remove_skill")) {
                const result = handle_remove_skill_tool.run(allocator, tool_call) catch |err|
                    try std.fmt.allocPrint(allocator, "ERROR: remove_skill failed: {s}", .{@errorName(err)});
                try handleToolResult(ctx, tool_call, result);
                continue;
            }

            if (std.mem.eql(u8, tool_call.function.name, "spawn_sub_agent")) {
                try handle_spawn_sub_agent.run(allocator, db, logger, session_id, model, cwd, session_name, loop_counter, messages_list, tool_call, agent_temperature.*, isThinking.*, api_key, base_url, config);
                continue;
            }

            if (std.mem.eql(u8, tool_call.function.name, "list_agents")) {
                const result = handle_list_agents_tool.run(allocator) catch |err|
                    try std.fmt.allocPrint(allocator, "ERROR: list_agents failed: {s}", .{@errorName(err)});
                try handleToolResult(ctx, tool_call, result);
                continue;
            }

            if (std.mem.eql(u8, tool_call.function.name, "get_agent")) {
                const result = handle_get_agent_tool.run(allocator, tool_call) catch |err|
                    try std.fmt.allocPrint(allocator, "ERROR: get_agent failed: {s}", .{@errorName(err)});
                defer allocator.free(result);

                if (std.mem.indexOf(u8, result, "<loaded>true</loaded>") != null) {
                    if (std.mem.indexOf(u8, result, "<agent_name>")) |name_start| {
                        const name_begin = name_start + "<agent_name>".len;
                        if (std.mem.indexOf(u8, result[name_begin..], "</agent_name>")) |name_end| {
                            const agent_name = result[name_begin .. name_begin + name_end];
                            SaveAgent(allocator, db, logger, session_id, agent_name) catch |err| {
                                const err_name = @errorName(err);
                                logger.errFmt("Error saving agent to database: {s}", .{err_name}) catch {};
                            };
                        }
                    }
                }

                try handleToolResult(ctx, tool_call, result);
                continue;
            }

            // Check if tool has underscore (potential MCP tool)
            // const has_underscore = std.mem.indexOf(u8, tool_call.function.name, "_") != null;
            // logger.infoFmt("[HANDLE_TOOL] Tool '{s}' has_underscore: {}", .{ tool_call.function.name, has_underscore }) catch {};
            //
            // // Fallback: Check if this is an MCP tool (has underscore in name)
            // // MCP tools are named like "context7_resolve-library-id"
            // if (has_underscore) {
            //     // Check if it's not one of the built-in tools
            //     const is_builtin = std.mem.eql(u8, tool_call.function.name, "set_agent_properties") or
            //         std.mem.eql(u8, tool_call.function.name, "bash") or
            //         std.mem.eql(u8, tool_call.function.name, "read_file") or
            //         std.mem.eql(u8, tool_call.function.name, "write_file") or
            //         std.mem.eql(u8, tool_call.function.name, "search") or
            //         std.mem.eql(u8, tool_call.function.name, "text_replace") or
            //         std.mem.eql(u8, tool_call.function.name, "list_skills") or
            //         std.mem.eql(u8, tool_call.function.name, "get_skill") or
            //         std.mem.eql(u8, tool_call.function.name, "remove_skill") or
            //         std.mem.eql(u8, tool_call.function.name, "spawn_sub_agent");
            //
            //     if (!is_builtin) {
            //         logger.infoFmt("Treating as MCP tool: {s}", .{tool_call.function.name}) catch {};
            //         handle_mcp_tool.run(allocator, db, logger, session_id, model, cwd, session_name, loop_counter, messages_list, tool_call, agent_temperature.*, isThinking.*, config) catch |err| {
            //             const err_name = @errorName(err);
            //             logger.errFmt("Error handling MCP tool: {s}", .{err_name}) catch {};
            //         };
            //     }
            // }
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
