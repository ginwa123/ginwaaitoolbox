const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const logger_mod = tree1_mod.logger;
const sqlite = tree1_mod.sqlite;
const config_mod = @import("../../modules/config/config.zig");
const save_message = @import("save_message.zig");
const send_tool_result = @import("send_tool_result.zig");
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

        _ = try save_message.run(allocator, db, .{
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
        });

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
                const change_result = handle_change_agent_tool.run(allocator, tool_call) catch |err| {
                    logger.errFmt("Error handling change_agent tool: {s}", .{@errorName(err)}) catch {};
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
                // Save to DB
                _ = try save_message.run(allocator, db, .{
                    .session_id = session_id,
                    .model = model,
                    .cwd = cwd,
                    .content = change_result.arguments,
                    .response_content = null,
                    .response_finish_reason = null,
                    .response_reasoning_content = null,
                    .role = "tool",
                    .finish_reason = "tool",
                    .tool_calls = null,
                    .tool_call_id = change_result.tool_call_id,
                    .agent_name = change_result.agent,
                    .session_name = session_name,
                    .loop_index = loop_counter,
                    .temperature = agent_temperature.*,
                    .is_thinking = isThinking.*,
                });
                send_tool_result.run(allocator, session_id, logger, change_result.arguments, change_result.tool_call_id, tool_call.function.name, null);
                logger.infoFmt("Switched to agent: {s}", .{change_result.agent}) catch {};
                continue;
            }

            if (std.mem.eql(u8, tool_call.function.name, "bash")) {
                const content = handle_bash_tool.run(allocator, tool_call) catch |err| {
                    logger.errFmt("Error executing bash: {s}", .{@errorName(err)}) catch {};
                    const err_str = "Error executing command";
                    const tool_result_msg = agent.AgentMessage{
                        .role = .tool,
                        .content = err_str,
                        .tool_call_id = try allocator.dupe(u8, tool_call.id),
                    };
                    _ = try messages_list.append(allocator, tool_result_msg);
                    _ = try save_message.run(allocator, db, .{
                        .session_id = session_id,
                        .model = model,
                        .cwd = cwd,
                        .content = err_str,
                        .response_content = null,
                        .response_finish_reason = null,
                        .response_reasoning_content = null,
                        .role = "tool",
                        .finish_reason = "tool",
                        .tool_calls = null,
                        .tool_call_id = tool_call.id,
                        .agent_name = current_agent_for_save,
                        .session_name = session_name,
                        .loop_index = loop_counter,
                        .temperature = agent_temperature.*,
                        .is_thinking = isThinking.*,
                    });
                    send_tool_result.run(allocator, session_id, logger, err_str, tool_call.id, tool_call.function.name, null);
                    continue;
                };
                defer allocator.free(content);

                try logger.debugFmt("RESPONSE TOOLS: {s}", .{content});

                const tool_result_msg = agent.AgentMessage{
                    .role = .tool,
                    .content = content,
                    .tool_call_id = try allocator.dupe(u8, tool_call.id),
                };
                _ = try messages_list.append(allocator, tool_result_msg);
                _ = try save_message.run(allocator, db, .{
                    .session_id = session_id,
                    .model = model,
                    .cwd = cwd,
                    .content = content,
                    .response_content = null,
                    .response_finish_reason = null,
                    .response_reasoning_content = null,
                    .role = "tool",
                    .finish_reason = "tool",
                    .tool_calls = null,
                    .tool_call_id = tool_call.id,
                    .agent_name = current_agent_for_save,
                    .session_name = session_name,
                    .loop_index = loop_counter,
                    .temperature = agent_temperature.*,
                    .is_thinking = isThinking.*,
                });
                send_tool_result.run(allocator, session_id, logger, content, tool_call.id, tool_call.function.name, null);
                logger.debugFmt("Tool result added to messages", .{}) catch {};
                continue;
            }

            if (std.mem.eql(u8, tool_call.function.name, "read_file")) {
                const content = handle_read_file_tool.run(allocator, tool_call) catch |err| {
                    logger.errFmt("Error reading file: {s}", .{@errorName(err)}) catch {};
                    const err_str = try std.fmt.allocPrint(allocator, "Error reading file: {s}", .{@errorName(err)});
                    const tool_result_msg = agent.AgentMessage{
                        .role = .tool,
                        .content = err_str,
                        .tool_call_id = try allocator.dupe(u8, tool_call.id),
                    };
                    _ = try messages_list.append(allocator, tool_result_msg);
                    _ = try save_message.run(allocator, db, .{
                        .session_id = session_id,
                        .model = model,
                        .cwd = cwd,
                        .content = err_str,
                        .response_content = null,
                        .response_finish_reason = null,
                        .response_reasoning_content = null,
                        .role = "tool",
                        .finish_reason = "tool",
                        .tool_calls = null,
                        .tool_call_id = tool_call.id,
                        .agent_name = current_agent_for_save,
                        .session_name = session_name,
                        .loop_index = loop_counter,
                        .temperature = agent_temperature.*,
                        .is_thinking = isThinking.*,
                    });
                    send_tool_result.run(allocator, session_id, logger, err_str, tool_call.id, tool_call.function.name, null);
                    continue;
                };
                defer allocator.free(content);

                try logger.debugFmt("RESPONSE TOOLS: {s}", .{content});

                const tool_result_msg = agent.AgentMessage{
                    .role = .tool,
                    .content = content,
                    .tool_call_id = try allocator.dupe(u8, tool_call.id),
                };
                _ = try messages_list.append(allocator, tool_result_msg);
                _ = try save_message.run(allocator, db, .{
                    .session_id = session_id,
                    .model = model,
                    .cwd = cwd,
                    .content = content,
                    .response_content = null,
                    .response_finish_reason = null,
                    .response_reasoning_content = null,
                    .role = "tool",
                    .finish_reason = "tool",
                    .tool_calls = null,
                    .tool_call_id = tool_call.id,
                    .agent_name = current_agent_for_save,
                    .session_name = session_name,
                    .loop_index = loop_counter,
                    .temperature = agent_temperature.*,
                    .is_thinking = isThinking.*,
                });
                send_tool_result.run(allocator, session_id, logger, content, tool_call.id, tool_call.function.name, null);
                logger.debugFmt("Tool result added to messages", .{}) catch {};
                continue;
            }

            if (std.mem.eql(u8, tool_call.function.name, "search")) {
                const content = handle_search_tool.run(allocator, tool_call) catch |err| {
                    logger.errFmt("Error executing search: {s}", .{@errorName(err)}) catch {};
                    const err_str = try std.fmt.allocPrint(allocator, "Error executing search: {s}", .{@errorName(err)});
                    defer allocator.free(err_str);
                    const tool_result_msg = agent.AgentMessage{
                        .role = .tool,
                        .content = err_str,
                        .tool_call_id = try allocator.dupe(u8, tool_call.id),
                    };
                    _ = try messages_list.append(allocator, tool_result_msg);
                    _ = try save_message.run(allocator, db, .{
                        .session_id = session_id,
                        .model = model,
                        .cwd = cwd,
                        .content = err_str,
                        .response_content = null,
                        .response_finish_reason = null,
                        .response_reasoning_content = null,
                        .role = "tool",
                        .finish_reason = "tool",
                        .tool_calls = null,
                        .tool_call_id = tool_call.id,
                        .agent_name = current_agent_for_save,
                        .session_name = session_name,
                        .loop_index = loop_counter,
                        .temperature = agent_temperature.*,
                        .is_thinking = isThinking.*,
                    });
                    send_tool_result.run(allocator, session_id, logger, err_str, tool_call.id, tool_call.function.name, null);
                    continue;
                };
                defer allocator.free(content);

                try logger.debugFmt("RESPONSE TOOLS (search): {s}", .{content});

                const tool_result_msg = agent.AgentMessage{
                    .role = .tool,
                    .content = content,
                    .tool_call_id = try allocator.dupe(u8, tool_call.id),
                };
                _ = try messages_list.append(allocator, tool_result_msg);
                _ = try save_message.run(allocator, db, .{
                    .session_id = session_id,
                    .model = model,
                    .cwd = cwd,
                    .content = content,
                    .response_content = null,
                    .response_finish_reason = null,
                    .response_reasoning_content = null,
                    .role = "tool",
                    .finish_reason = "tool",
                    .tool_calls = null,
                    .tool_call_id = tool_call.id,
                    .agent_name = current_agent_for_save,
                    .session_name = session_name,
                    .loop_index = loop_counter,
                    .temperature = agent_temperature.*,
                    .is_thinking = isThinking.*,
                });
                send_tool_result.run(allocator, session_id, logger, content, tool_call.id, tool_call.function.name, null);
                logger.debugFmt("Search tool result added to messages", .{}) catch {};
                continue;
            }

            if (std.mem.eql(u8, tool_call.function.name, "write_file")) {
                const content = handle_write_file_tool.run(allocator, tool_call) catch |err| {
                    logger.errFmt("Error executing write_file: {s}", .{@errorName(err)}) catch {};
                    const err_str = try std.fmt.allocPrint(allocator, "Error writing file: {s}", .{@errorName(err)});
                    defer allocator.free(err_str);
                    const tool_result_msg = agent.AgentMessage{
                        .role = .tool,
                        .content = err_str,
                        .tool_call_id = try allocator.dupe(u8, tool_call.id),
                    };
                    _ = try messages_list.append(allocator, tool_result_msg);
                    _ = try save_message.run(allocator, db, .{
                        .session_id = session_id,
                        .model = model,
                        .cwd = cwd,
                        .content = err_str,
                        .response_content = null,
                        .response_finish_reason = null,
                        .response_reasoning_content = null,
                        .role = "tool",
                        .finish_reason = "tool",
                        .tool_calls = null,
                        .tool_call_id = tool_call.id,
                        .agent_name = current_agent_for_save,
                        .session_name = session_name,
                        .loop_index = loop_counter,
                        .temperature = agent_temperature.*,
                        .is_thinking = isThinking.*,
                    });
                    send_tool_result.run(allocator, session_id, logger, err_str, tool_call.id, tool_call.function.name, null);
                    continue;
                };
                defer allocator.free(content);

                try logger.debugFmt("RESPONSE TOOLS (write_file): {s}", .{content});

                const tool_result_msg = agent.AgentMessage{
                    .role = .tool,
                    .content = content,
                    .tool_call_id = try allocator.dupe(u8, tool_call.id),
                };
                _ = try messages_list.append(allocator, tool_result_msg);
                _ = try save_message.run(allocator, db, .{
                    .session_id = session_id,
                    .model = model,
                    .cwd = cwd,
                    .content = content,
                    .response_content = null,
                    .response_finish_reason = null,
                    .response_reasoning_content = null,
                    .role = "tool",
                    .finish_reason = "tool",
                    .tool_calls = null,
                    .tool_call_id = tool_call.id,
                    .agent_name = current_agent_for_save,
                    .session_name = session_name,
                    .loop_index = loop_counter,
                    .temperature = agent_temperature.*,
                    .is_thinking = isThinking.*,
                });
                send_tool_result.run(allocator, session_id, logger, content, tool_call.id, tool_call.function.name, null);
                logger.debugFmt("Write file tool result added to messages", .{}) catch {};
                continue;
            }

            if (std.mem.eql(u8, tool_call.function.name, "text_replace")) {
                const content = handle_text_replace_tool.run(allocator, tool_call) catch |err| {
                    logger.errFmt("Error executing text_replace: {s}", .{@errorName(err)}) catch {};
                    const err_str = try std.fmt.allocPrint(allocator, "Error replacing text: {s}", .{@errorName(err)});
                    defer allocator.free(err_str);
                    const tool_result_msg = agent.AgentMessage{
                        .role = .tool,
                        .content = err_str,
                        .tool_call_id = try allocator.dupe(u8, tool_call.id),
                    };
                    _ = try messages_list.append(allocator, tool_result_msg);
                    _ = try save_message.run(allocator, db, .{
                        .session_id = session_id,
                        .model = model,
                        .cwd = cwd,
                        .content = err_str,
                        .response_content = null,
                        .response_finish_reason = null,
                        .response_reasoning_content = null,
                        .role = "tool",
                        .finish_reason = "tool",
                        .tool_calls = null,
                        .tool_call_id = tool_call.id,
                        .agent_name = current_agent_for_save,
                        .session_name = session_name,
                        .loop_index = loop_counter,
                        .temperature = agent_temperature.*,
                        .is_thinking = isThinking.*,
                    });
                    send_tool_result.run(allocator, session_id, logger, err_str, tool_call.id, tool_call.function.name, null);
                    continue;
                };
                defer allocator.free(content);

                try logger.debugFmt("RESPONSE TOOLS (text_replace): {s}", .{content});

                const tool_result_msg = agent.AgentMessage{
                    .role = .tool,
                    .content = content,
                    .tool_call_id = try allocator.dupe(u8, tool_call.id),
                };
                _ = try messages_list.append(allocator, tool_result_msg);
                _ = try save_message.run(allocator, db, .{
                    .session_id = session_id,
                    .model = model,
                    .cwd = cwd,
                    .content = content,
                    .response_content = null,
                    .response_finish_reason = null,
                    .response_reasoning_content = null,
                    .role = "tool",
                    .finish_reason = "tool",
                    .tool_calls = null,
                    .tool_call_id = tool_call.id,
                    .agent_name = current_agent_for_save,
                    .session_name = session_name,
                    .loop_index = loop_counter,
                    .temperature = agent_temperature.*,
                    .is_thinking = isThinking.*,
                });
                send_tool_result.run(allocator, session_id, logger, content, tool_call.id, tool_call.function.name, null);
                logger.debugFmt("Text replace tool result added to messages", .{}) catch {};
                continue;
            }

            if (std.mem.eql(u8, tool_call.function.name, "list_skills")) {
                const result = handle_list_skills_tool.run(allocator);
                logger.debugFmt("LIST_SKILLS RESULT: {s}", .{result}) catch {};

                const tool_result_msg = agent.AgentMessage{
                    .role = .tool,
                    .content = result,
                    .tool_call_id = try allocator.dupe(u8, tool_call.id),
                };
                messages_list.append(allocator, tool_result_msg) catch {};
                _ = try save_message.run(allocator, db, .{
                    .session_id = session_id,
                    .model = model,
                    .cwd = cwd,
                    .content = result,
                    .response_content = null,
                    .response_finish_reason = null,
                    .response_reasoning_content = null,
                    .role = "tool",
                    .finish_reason = "tool",
                    .tool_calls = null,
                    .tool_call_id = tool_call.id,
                    .agent_name = current_agent_for_save,
                    .session_name = session_name,
                    .loop_index = loop_counter,
                    .temperature = agent_temperature.*,
                    .is_thinking = isThinking.*,
                });
                send_tool_result.run(allocator, session_id, logger, result, tool_call.id, tool_call.function.name, null);
                continue;
            }

            if (std.mem.eql(u8, tool_call.function.name, "get_skill")) {
                const result = handle_get_skill_tool.run(allocator, tool_call) catch |err| {
                    logger.errFmt("Error executing get_skill: {s}", .{@errorName(err)}) catch {};
                    continue;
                };
                defer allocator.free(result);

                logger.debugFmt("GET_SKILL RESULT: {s}", .{result}) catch {};

                const tool_result_msg = agent.AgentMessage{
                    .role = .tool,
                    .content = result,
                    .tool_call_id = try allocator.dupe(u8, tool_call.id),
                };
                _ = try messages_list.append(allocator, tool_result_msg);
                _ = try save_message.run(allocator, db, .{
                    .session_id = session_id,
                    .model = model,
                    .cwd = cwd,
                    .content = result,
                    .response_content = null,
                    .response_finish_reason = null,
                    .response_reasoning_content = null,
                    .role = "tool",
                    .finish_reason = "tool",
                    .tool_calls = null,
                    .tool_call_id = tool_call.id,
                    .agent_name = current_agent_for_save,
                    .session_name = session_name,
                    .loop_index = loop_counter,
                    .temperature = agent_temperature.*,
                    .is_thinking = isThinking.*,
                });
                send_tool_result.run(allocator, session_id, logger, result, tool_call.id, tool_call.function.name, null);
                continue;
            }

            if (std.mem.eql(u8, tool_call.function.name, "remove_skill")) {
                const result = handle_remove_skill_tool.run(allocator, tool_call) catch |err| {
                    logger.errFmt("Error executing remove_skill: {s}", .{@errorName(err)}) catch {};
                    continue;
                };
                defer allocator.free(result);

                logger.debugFmt("REMOVE_SKILL RESULT: {s}", .{result}) catch {};

                const tool_result_msg = agent.AgentMessage{
                    .role = .tool,
                    .content = result,
                    .tool_call_id = try allocator.dupe(u8, tool_call.id),
                };
                _ = try messages_list.append(allocator, tool_result_msg);
                _ = try save_message.run(allocator, db, .{
                    .session_id = session_id,
                    .model = model,
                    .cwd = cwd,
                    .content = result,
                    .response_content = null,
                    .response_finish_reason = null,
                    .response_reasoning_content = null,
                    .role = "tool",
                    .finish_reason = "tool",
                    .tool_calls = null,
                    .tool_call_id = tool_call.id,
                    .agent_name = current_agent_for_save,
                    .session_name = session_name,
                    .loop_index = loop_counter,
                    .temperature = agent_temperature.*,
                    .is_thinking = isThinking.*,
                });
                send_tool_result.run(allocator, session_id, logger, result, tool_call.id, tool_call.function.name, null);
                continue;
            }

            if (std.mem.eql(u8, tool_call.function.name, "spawn_sub_agent")) {
                try handle_spawn_sub_agent.run(allocator, db, logger, session_id, model, cwd, session_name, loop_counter, messages_list, tool_call, agent_temperature.*, isThinking.*, api_key, base_url, config);
                continue;
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
