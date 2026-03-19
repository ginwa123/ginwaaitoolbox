const std = @import("std");
const root_mod = @import("nalarcore");
const agent = root_mod.agent;
const tool_models = root_mod.tool_models;
const logger_mod = root_mod.logger;
const sqlite = root_mod.sqlite;
const prompt = root_mod.prompt;
const spawn_sub_agent_tool = @import("../../modules/agent/tools/spawn_sub_agent.zig");
const bash_tool = @import("../../modules/agent/tools/bash.zig");
const read_file_tool = @import("../../modules/agent/tools/read_file.zig");
const write_file_tool = @import("../../modules/agent/tools/write_file.zig");
const search_tool = @import("../../modules/agent/tools/search.zig");
const text_replace_tool = @import("../../modules/agent/tools/text_replace.zig");
const list_skills_tool = @import("../../modules/agent/tools/list_skills.zig");
const get_skill_tool = @import("../../modules/agent/tools/get_skill.zig");
const remove_skill_tool = @import("../../modules/agent/tools/remove_skill.zig");
const config_mod = @import("../../modules/config/config.zig");
const SaveMessage = @import("save_message.zig").SaveMessage;
const onEventSendNew = @import("on_event_sent.zig").onEventSendNew;
const get_current_agent_by_session_id = @import("get_current_agent_by_session_id.zig");
const handle_tool = @import("handle_tool.zig");
const handle_read_file_tool = @import("handle_read_file_tool.zig");
const handle_search_tool = @import("handle_search_tool.zig");
const handle_text_replace_tool = @import("handle_text_replace_tool.zig");
const handle_write_file_tool = @import("handle_write_file_tool.zig");
const handle_list_skills_tool = @import("handle_list_skills_tool.zig");
const handle_get_skill_tool = @import("handle_get_skill_tool.zig");
const handle_remove_skill_tool = @import("handle_remove_skill_tool.zig");
const loop_detector = root_mod.loop_detector;
const set_agent_properties = root_mod.set_agent_properties;
const AllAgentTools = @import("all_agent_tools.zig").AllAgentTools;
const GetMessages = @import("get_messages.zig").GetMessages;
const GetMessagesLatest = @import("get_messages.zig").GetMessageLatest;
const TransformLLMHistory = @import("transform_llm_history_to_agent_messages.zig");
const handle_bash_tool = @import("handle_bash_tool.zig");
const handle_list_agents_tool = @import("handle_list_agents_tool.zig");
const handle_get_agent_tool = @import("handle_get_agent_tool.zig");
const handle_lsp_definition_tool = @import("handle_lsp_definition_tool.zig");
// TODO: Restore these when lsp.zig is complete with all tools
// const handle_lsp_references_tool = @import("handle_lsp_references_tool.zig");
// const handle_lsp_workspace_symbol_tool = @import("handle_lsp_workspace_symbol_tool.zig");
// const handle_lsp_document_symbol_tool = @import("handle_lsp_document_symbol_tool.zig");
// const handle_lsp_hover_tool = @import("handle_lsp_hover_tool.zig");
const StreamingContext = @import("tui_workflow.zig").StreamingContext;
const BuildSkillContent = @import("build_skill_for_agent_prompt.zig").BuildSkillContent;
const SaveSkill = @import("save_skill.zig").SaveSkill;
const SaveAgent = @import("save_agent.zig").SaveAgent;

const MAX_SUB_AGENTS = 20;

// Import BashInput from models (not exported in bash.zig)
const BashInput = @import("../../modules/agent/tools/models.zig").BashInput;

/// Filter tools by allowed names. If allowed_tools is null, return all tools.
fn getAllowedTools(allocator: std.mem.Allocator, allowed_tools: ?[]const []const u8) ![]const tool_models.AgentTool {
    if (allowed_tools == null) {
        // Return all tools (copy the slice)
        return try allocator.dupe(tool_models.AgentTool, AllAgentTools);
    }

    var result = std.ArrayList(tool_models.AgentTool).empty;
    errdefer result.deinit(allocator);

    for (AllAgentTools) |tool| {
        for (allowed_tools.?) |allowed| {
            if (std.mem.eql(u8, tool.function.name, allowed)) {
                try result.append(allocator, tool);
                break;
            }
        }
    }

    return try result.toOwnedSlice(allocator);
}

pub fn stream_callback(ctx: ?*anyopaque, chunk: agent.StreamChunk) void {
    _ = ctx;
    _ = chunk;
}

/// Run a single sub-agent with basic tools (but no spawn_sub_agent or set_agent_properties)
fn runSubAgent(
    parentAllocator: std.mem.Allocator,
    logger: *logger_mod.Logger,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    cwd: []const u8,
    instruction: []const u8,
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
    config: *const config_mod.LlmConfig,
    allowed_tools: ?[]const []const u8,
    loop_index: u32,
    agent_temperature: f32,
    is_thinking: bool,
    agent_name: []const u8,
    parent_session_id: []const u8,
    parent_id: []const u8,
) ![]const u8 {
    _ = config; // reserved for future use (e.g., MCP tools)
    // session_id is now passed as parameter - use it for DB and SSE
    const sessionName = try std.fmt.allocPrint(parentAllocator, "{}", .{std.time.nanoTimestamp()});

    // Save user instruction message to DB
    _ = try SaveMessage(parentAllocator, db, .{
        .session_id = session_id,
        .model = model,
        .cwd = cwd,
        .content = instruction,
        .reasoning_content = null,
        .role = agent.Role.user.toStr(),
        .finish_reason = "null",
        .tool_calls = null,
        .tool_call_id = null,
        .agent_name = agent_name,
        .session_name = sessionName,
        .loop_index = loop_index,
        .temperature = agent_temperature,
        .is_thinking = is_thinking,
        .parent_session_id = parent_session_id,
        .parent_id = parent_id,
        .prompt_tokens = 0,
        .completion_tokens = 0,
        .total_tokens = 0,
        .is_input = true,
        .is_output = false,
        .tool_name = null,
    });

    // Send SSE event for user instruction
    {
        const latestMessage = try GetMessagesLatest(parentAllocator, db, session_id);
        try onEventSendNew(parentAllocator, .{
            .session_id = latestMessage.?.session_id,
            .model = latestMessage.?.model,
            .cwd = cwd,
            .content = latestMessage.?.response_content,
            .reasoning_content = latestMessage.?.reasoning_content,
            .role = latestMessage.?.role,
            .finish_reason = latestMessage.?.finish_reason,
            .tool_calls = null,
            .tool_call_id = latestMessage.?.id,
            .tool_name = latestMessage.?.tool_name,
            .agent_name = agent_name,
            .session_name = latestMessage.?.session_name,
            .loop_index = latestMessage.?.loop_index,
            .temperature = agent_temperature,
            .is_thinking = is_thinking,
            .is_input = true,
            .is_output = false,
            .parent_session_id = null,
            .parent_id = null,
        });
    }

    // Get tools based on allowed_tools (null = all tools)
    const sub_agent_tools = try getAllowedTools(parentAllocator, allowed_tools);

    var sub_agent = try agent.Agent.init(parentAllocator, logger);

    sub_agent.apiKey = api_key;
    sub_agent.model = model;
    sub_agent.baseUrl = base_url;
    sub_agent.httpOptions.read_timeout_ms = 300_000; // 10 minutes

    // Build tool names list from allowed tools
    var tool_names: std.ArrayList([]const u8) = .empty;
    defer tool_names.deinit(parentAllocator);
    for (sub_agent_tools) |tool| {
        try tool_names.append(parentAllocator, tool.function.name);
    }

    // Build system prompt with cwd context - sub-agents need this for path resolution

    // Save system prompt to DB so it can be fetched in the while loop
    // _ = try SaveMessage(parentAllocator, db, .{
    //     .session_id = session_id,
    //     .model = model,
    //     .cwd = cwd,
    //     .content = systemPrompt,
    //     .response_reasoning_content = null,
    //     .role = agent.Role.system.toStr(),
    //     .finish_reason = "null",
    //     .tool_calls = null,
    //     .tool_call_id = null,
    //     .agent_name = agent_name,
    //     .session_name = session_name,
    //     .loop_index = loop_index,
    //     .temperature = agent_temperature,
    //     .is_thinking = is_thinking,
    //     .parent_session_id = parent_session_id,
    //     .parent_id = parent_id,
    //     .prompt_tokens = 0,
    //     .completion_tokens = 0,
    //     .total_tokens = 0,
    // });
    //
    var tool_call_count: usize = 0;
    var last_response: ?agent.CallResponse = null;

    while (true) {
        var arenaAllocatorWhileLoop = std.heap.ArenaAllocator.init(parentAllocator);
        defer arenaAllocatorWhileLoop.deinit();
        const allocator = arenaAllocatorWhileLoop.allocator();

        const skillContents = try BuildSkillContent(allocator, db, session_id);
        const systemPrompt = try prompt.buildSubAgentPrompt(allocator, cwd, tool_names.items, skillContents);

        var messages: std.ArrayList(agent.AgentMessage) = .empty;
        try messages.append(allocator, .{
            .role = .system,
            .content = systemPrompt,
        });
        // Fetch existing messages from DB first
        const tui_histories = try GetMessages(allocator, db, session_id);
        for (tui_histories) |hist| {
            const agent_msgs = try TransformLLMHistory.run(allocator, hist);
            for (agent_msgs) |msg| {
                try messages.append(allocator, msg);
            }
        }

        const params = agent.AgentCall{
            .tools = sub_agent_tools,
            .messages = messages.items,
            .temperature = 0.5,
            .max_tokens = 4000,
        };

        var stream_ctx = StreamingContext{
            .allocator = allocator,
            .session_id = session_id,
            .chunk_index = 0,
        };

        last_response = try sub_agent.callStreaming(params, &stream_ctx, stream_callback);
        const response = last_response.?;

        // Save assistant response to DB
        const assistant_tool_calls = if (response.tool_calls) |tcs| tcs else null;
        _ = try SaveMessage(allocator, db, .{
            .session_id = session_id,
            .model = model,
            .cwd = cwd,
            .content = response.content,
            .reasoning_content = response.reasoning_content,
            .role = agent.Role.assistant.toStr(),
            .finish_reason = if (response.finish_reason) |fr| fr.toStr() else null,
            .tool_calls = assistant_tool_calls,
            .tool_call_id = null,
            .agent_name = agent_name,
            .session_name = sessionName,
            .loop_index = loop_index,
            .temperature = agent_temperature,
            .is_thinking = is_thinking,
            .parent_session_id = parent_session_id,
            .parent_id = parent_id,
            .prompt_tokens = response.usage.prompt_tokens,
            .completion_tokens = response.usage.completion_tokens,
            .total_tokens = response.usage.total_tokens,
            .is_input = true,
            .is_output = false,
        });

        // Send SSE event for assistant response
        {
            const latestMessage = try GetMessagesLatest(allocator, db, session_id);
            try onEventSendNew(allocator, .{
                .session_id = latestMessage.?.session_id,
                .model = latestMessage.?.model,
                .cwd = cwd,
                .content = latestMessage.?.response_content,
                .reasoning_content = latestMessage.?.reasoning_content,
                .role = latestMessage.?.role,
                .finish_reason = latestMessage.?.finish_reason,
                .tool_calls = null,
                .tool_call_id = latestMessage.?.id,
                .tool_name = latestMessage.?.tool_name,
                .agent_name = agent_name,
                .session_name = latestMessage.?.session_name,
                .loop_index = latestMessage.?.loop_index,
                .temperature = agent_temperature,
                .is_thinking = is_thinking,
                .is_input = true,
                .is_output = false,
                .parent_session_id = null,
                .parent_id = null,
            });
        }

        // Check finish_reason
        if (response.finish_reason) |fr| {
            if (fr == .stop) {
                // Agent finished with stop - return the content
                if (response.content) |content| {
                    return try allocator.dupe(u8, content);
                }
                return try allocator.dupe(u8, "(empty response)");
            } else if (fr == .tool_calls) {
                // Process tool calls
                tool_call_count += 1;

                if (response.tool_calls) |tcs| {
                    for (tcs) |tc| {
                        logger.infoFmt("[SUB_AGENT] Tool: '{s}'", .{tc.function.name}) catch {};

                        // Execute basic tools inline (no spawn_sub_agent or set_agent_properties)
                        var tool_result: []const u8 = undefined;

                        if (std.mem.eql(u8, tc.function.name, "bash")) {
                            tool_result = handle_bash_tool.runWithContext(allocator, tc, db, session_id) catch |err|
                                try std.fmt.allocPrint(allocator, "ERROR: bash failed: {s}", .{@errorName(err)});
                        } else if (std.mem.eql(u8, tc.function.name, "read_file")) {
                            tool_result = handle_read_file_tool.run(allocator, tc) catch |err|
                                try std.fmt.allocPrint(allocator, "ERROR: read_file failed: {s}", .{@errorName(err)});
                        } else if (std.mem.eql(u8, tc.function.name, "search")) {
                            tool_result = handle_search_tool.run(allocator, tc) catch |err|
                                try std.fmt.allocPrint(allocator, "ERROR: search failed: {s}", .{@errorName(err)});
                        } else if (std.mem.eql(u8, tc.function.name, "text_replace")) {
                            tool_result = handle_text_replace_tool.run(allocator, tc) catch |err|
                                try std.fmt.allocPrint(allocator, "ERROR: text_replace failed: {s}", .{@errorName(err)});
                        } else if (std.mem.eql(u8, tc.function.name, "write_file")) {
                            tool_result = handle_write_file_tool.run(allocator, tc) catch |err|
                                try std.fmt.allocPrint(allocator, "ERROR: write_file failed: {s}", .{@errorName(err)});
                        } else if (std.mem.eql(u8, tc.function.name, "list_skills")) {
                            tool_result = handle_list_skills_tool.run(allocator);
                        } else if (std.mem.eql(u8, tc.function.name, "get_skill")) {
                            tool_result = handle_get_skill_tool.run(allocator, tc) catch |err|
                                try std.fmt.allocPrint(allocator, "ERROR: get_skill failed: {s}", .{@errorName(err)});
                            if (std.mem.indexOf(u8, tool_result, "<loaded>true</loaded>") != null) {
                                if (std.mem.indexOf(u8, tool_result, "<skill_name>")) |name_start| {
                                    const name_begin = name_start + "<skill_name>".len;
                                    if (std.mem.indexOf(u8, tool_result[name_begin..], "</skill_name>")) |name_end| {
                                        const skill_name = tool_result[name_begin .. name_begin + name_end];
                                        // Parse content from result
                                        if (std.mem.indexOf(u8, tool_result, "<content>")) |content_start| {
                                            const content_begin = content_start + "<content>".len;
                                            if (std.mem.indexOf(u8, tool_result[content_begin..], "</content>")) |content_end| {
                                                const content = tool_result[content_begin .. content_begin + content_end];
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
                        } else if (std.mem.eql(u8, tc.function.name, "remove_skill")) {
                            tool_result = handle_remove_skill_tool.run(allocator, tc) catch |err|
                                try std.fmt.allocPrint(allocator, "ERROR: remove_skill failed: {s}", .{@errorName(err)});
                        } else if (std.mem.eql(u8, tc.function.name, "list_agents")) {
                            tool_result = handle_list_agents_tool.run(allocator) catch |err|
                                try std.fmt.allocPrint(allocator, "ERROR: list_agents failed: {s}", .{@errorName(err)});
                        } else if (std.mem.eql(u8, tc.function.name, "get_agent")) {
                            tool_result = handle_get_agent_tool.run(allocator, tc) catch |err|
                                try std.fmt.allocPrint(allocator, "ERROR: get_agent failed: {s}", .{@errorName(err)});
                            // Parse and save agent if loaded successfully
                            if (std.mem.indexOf(u8, tool_result, "<loaded>true</loaded>") != null) {
                                if (std.mem.indexOf(u8, tool_result, "<agent_name>")) |name_start| {
                                    const name_begin = name_start + "<agent_name>".len;
                                    if (std.mem.indexOf(u8, tool_result[name_begin..], "</agent_name>")) |name_end| {
                                        const loaded_agent_name = tool_result[name_begin .. name_begin + name_end];
                                        SaveAgent(allocator, db, logger, session_id, loaded_agent_name) catch |err| {
                                            logger.errFmt("Error saving agent to database: {s}", .{@errorName(err)}) catch {};
                                        };
                                    }
                                }
                            }
                        } else if (std.mem.eql(u8, tc.function.name, "lsp_definition")) {
                            tool_result = handle_lsp_definition_tool.run(allocator, tc) catch |err|
                                try std.fmt.allocPrint(allocator, "ERROR: lsp_definition failed: {s}", .{@errorName(err)});
                        }
                        // TODO: Restore these when lsp.zig is complete with all tools
                        // else if (std.mem.eql(u8, tc.function.name, "lsp_references")) {
                        //     tool_result = handle_lsp_references_tool.run(allocator, tc) catch |err|
                        //         try std.fmt.allocPrint(allocator, "ERROR: lsp_references failed: {s}", .{@errorName(err)});
                        //     SendToolResult(allocator, parent_session_id, logger, .tool_result, .{ .tool_call_id = tc.id, .tool_name = "lsp_references", .tool_result = tool_result });
                        // } else if (std.mem.eql(u8, tc.function.name, "lsp_workspace_symbol")) {
                        //     tool_result = handle_lsp_workspace_symbol_tool.run(allocator, tc) catch |err|
                        //         try std.fmt.allocPrint(allocator, "ERROR: lsp_workspace_symbol failed: {s}", .{@errorName(err)});
                        //     SendToolResult(allocator, parent_session_id, logger, .tool_result, .{ .tool_call_id = tc.id, .tool_name = "lsp_workspace_symbol", .tool_result = tool_result });
                        // } else if (std.mem.eql(u8, tc.function.name, "lsp_document_symbol")) {
                        //     tool_result = handle_lsp_document_symbol_tool.run(allocator, tc) catch |err|
                        //         try std.fmt.allocPrint(allocator, "ERROR: lsp_document_symbol failed: {s}", .{@errorName(err)});
                        //     SendToolResult(allocator, parent_session_id, logger, .tool_result, .{ .tool_call_id = tc.id, .tool_name = "lsp_document_symbol", .tool_result = tool_result });
                        // } else if (std.mem.eql(u8, tc.function.name, "lsp_hover")) {
                        //     tool_result = handle_lsp_hover_tool.run(allocator, tc) catch |err|
                        //         try std.fmt.allocPrint(allocator, "ERROR: lsp_hover failed: {s}", .{@errorName(err)});
                        //     SendToolResult(allocator, parent_session_id, logger, .tool_result, .{ .tool_call_id = tc.id, .tool_name = "lsp_hover", .tool_result = tool_result });
                        // }
                        else {
                            tool_result = try std.fmt.allocPrint(allocator, "ERROR: Unknown tool '{s}'", .{tc.function.name});
                        }

                        // Save tool result to DB
                        _ = try SaveMessage(allocator, db, .{
                            .session_id = session_id,
                            .model = model,
                            .cwd = cwd,
                            .content = tool_result,
                            .reasoning_content = null,
                            .role = agent.Role.tool.toStr(),
                            .finish_reason = agent.FinishReason.tool.toStr(),
                            .tool_calls = null,
                            .tool_call_id = tc.id,
                            .agent_name = agent_name,
                            .session_name = sessionName,
                            .loop_index = loop_index,
                            .temperature = agent_temperature,
                            .is_thinking = is_thinking,
                            .parent_session_id = parent_session_id,
                            .parent_id = parent_id,
                            .prompt_tokens = 0,
                            .completion_tokens = 0,
                            .total_tokens = 0,
                            .is_input = false,
                            .is_output = true,
                            .tool_name = tc.function.name,
                        });

                        // Send SSE event for tool result
                        {
                            const latestMessage = try GetMessagesLatest(allocator, db, session_id);
                            try onEventSendNew(allocator, .{
                                .session_id = latestMessage.?.parent_session_id orelse session_id,
                                .model = latestMessage.?.model,
                                .cwd = cwd,
                                .content = latestMessage.?.response_content,
                                .reasoning_content = latestMessage.?.reasoning_content,
                                .role = latestMessage.?.role,
                                .finish_reason = latestMessage.?.finish_reason,
                                .tool_calls = null,
                                .tool_call_id = latestMessage.?.id,
                                .tool_name = latestMessage.?.tool_name,
                                .agent_name = agent_name,
                                .session_name = latestMessage.?.session_name,
                                .loop_index = latestMessage.?.loop_index,
                                .temperature = agent_temperature,
                                .is_thinking = is_thinking,
                                .is_input = false,
                                .is_output = true,
                                .parent_session_id = null,
                                .parent_id = null,
                            });
                        }

                        // Add assistant message with tool_calls
                        const tc_slice = try allocator.alloc(agent.ToolCall, 1);
                        tc_slice[0] = .{
                            .id = try allocator.dupe(u8, tc.id),
                            .function = .{
                                .name = try allocator.dupe(u8, tc.function.name),
                                .arguments = try allocator.dupe(u8, tc.function.arguments),
                            },
                        };
                        try messages.append(allocator, .{
                            .role = .assistant,
                            .content = null,
                            .tool_calls = tc_slice,
                        });

                        // Add tool result message
                        try messages.append(allocator, .{
                            .role = .tool,
                            .content = tool_result,
                            .tool_call_id = try allocator.dupe(u8, tc.id),
                        });
                    }
                }
            } else {
                // Other finish reasons (length, etc.)
                if (response.content) |content| {
                    return try allocator.dupe(u8, content);
                }
                break;
            }
        } else {
            break;
        }
    }

    // Max tool calls reached
    if (last_response) |response| {
        if (response.content) |content| {
            return try parentAllocator.dupe(u8, content);
        }
    }
    return try parentAllocator.dupe(u8, "(max tool calls reached)");
}

/// Parse JSON input and run spawn_sub_agent handler
pub fn run(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    _session_name: ?[]const u8,
    loop_counter: u32,
    tool_call: agent.ToolCall,
    agent_temperature: f32,
    is_thinking: bool,
    api_key: []const u8,
    base_url: []const u8,
    config: *const config_mod.LlmConfig,
) ![]u8 {
    // Parse the JSON input from function.arguments
    logger.infoFmt("spawn_sub_agent: parsing JSON input", .{}) catch {};
    logger.debugFmt("spawn_sub_agent: JSON input: {s}", .{tool_call.function.arguments}) catch {};
    const parsed = try spawn_sub_agent_tool.parseSubAgents(allocator, tool_call.function.arguments, MAX_SUB_AGENTS);
    // defer parsed.deinit(allocator);
    _ = _session_name; // unused parameter

    logger.infoFmt("spawn_sub_agent: spawning {} parallel sub-agents", .{parsed.sub_agents.len}) catch {};

    // Fetch current agent from DB (before running sub-agents)
    const current_agent_state = try get_current_agent_by_session_id.run(
        allocator,
        db,
        session_id,
    );
    const current_agent = current_agent_state.agent;

    // Run each sub-agent and collect results
    var results: std.ArrayList([]const u8) = .empty;
    // defer {
    //     for (results.items) |r| allocator.free(r);
    //     results.deinit(allocator);
    // }

    // Run all sub-agents in parallel using threads
    const num_agents = parsed.sub_agents.len;

    // Allocate result slots for each sub-agent (thread-safe result storage)
    const ThreadResult = struct {
        result: ?[]const u8 = null,
        err_msg: ?[]const u8 = null,
        completed: bool = false,
        mutex: std.Thread.Mutex = .{},
    };

    // Use thread-safe result storage
    const thread_results = try allocator.alloc(ThreadResult, num_agents);
    @memset(thread_results, .{});

    // Spawn a thread for each sub-agent
    for (parsed.sub_agents, 0..) |sub_agent, index| {
        logger.infoFmt("spawn_sub_agent: spawning parallel agent '{s}' (index {})", .{ sub_agent.name, index }) catch {};

        // Create a local copy of the sub_agent data for the thread
        const sub_agent_name = try allocator.dupe(u8, sub_agent.name);
        const sub_agent_instruction = try allocator.dupe(u8, sub_agent.instruction);
        const sub_agent_tools_copy = if (sub_agent.tools) |tools| try allocator.dupe([]const u8, tools) else null;

        const thread = try std.Thread.spawn(.{}, struct {
            fn run(
                idx: usize,
                name: []const u8,
                instruction: []const u8,
                tools: ?[]const []const u8,
                alloc: std.mem.Allocator,
                log: *logger_mod.Logger,
                database: *sqlite.SqliteBackend,
                workdir: []const u8,
                llm_api_key: []const u8,
                llm_model: []const u8,
                url: []const u8,
                cfg: *const config_mod.LlmConfig,
                loop_idx: u32,
                temp: f32,
                think: bool,
                agent_nm: []const u8,
                parent_sess: []const u8,
                parent_id: []const u8,
                thread_res: []ThreadResult,
            ) void {
                // Each thread gets its own arena allocator to prevent memory corruption
                // when multiple sub-agents run in parallel
                var thread_arena = std.heap.ArenaAllocator.init(alloc);
                defer thread_arena.deinit();
                const thread_alloc = thread_arena.allocator();

                log.infoFmt("spawn_sub_agent[{}]: starting agent '{s}'", .{ idx, name }) catch {};

                const sessionId = std.fmt.allocPrint(thread_alloc, "{}", .{std.time.nanoTimestamp()}) catch |err| {
                    log.errFmt("spawn_sub_agent[{}]: failed to generate sessionId: {}", .{ idx, err }) catch {};
                    return;
                };

                const run_result = runSubAgent(
                    thread_alloc,
                    log,
                    database,
                    sessionId,
                    workdir,
                    instruction,
                    llm_api_key,
                    llm_model,
                    url,
                    cfg,
                    tools,
                    loop_idx,
                    temp,
                    think,
                    agent_nm,
                    parent_sess,
                    parent_id,
                );

                // Store result or error in thread-safe manner
                thread_res[idx].mutex.lock();
                defer thread_res[idx].mutex.unlock();
                thread_res[idx].completed = true;
                if (run_result) |res| {
                    // Duplicate to shared allocator since thread arena will be freed
                    thread_res[idx].result = alloc.dupe(u8, res) catch null;
                } else |err| {
                    thread_res[idx].err_msg = alloc.dupe(u8, @errorName(err)) catch null;
                }

                log.infoFmt("spawn_sub_agent[{}]: agent '{s}' completed", .{ idx, name }) catch {};
            }
        }.run, .{
            index,
            sub_agent_name,
            sub_agent_instruction,
            sub_agent_tools_copy,
            allocator, // shared allocator for results
            logger,
            db,
            cwd,
            api_key,
            model,
            base_url,
            config,
            loop_counter,
            agent_temperature,
            is_thinking,
            current_agent,
            session_id,
            session_id,
            thread_results,
        });

        thread.detach();
    }

    // Wait for all threads to finish by checking completion status
    logger.infoFmt("spawn_sub_agent: waiting for {} parallel agents to complete", .{num_agents}) catch {};
    var all_done = false;
    while (!all_done) {
        all_done = true;
        for (thread_results) |*r| {
            r.mutex.lock();
            const completed = r.completed;
            r.mutex.unlock();
            if (!completed) {
                all_done = false;
                break;
            }
        }
        if (!all_done) {
            std.Thread.sleep(10_000_000); // 10ms
        }
    }

    // Collect results from all agents
    for (thread_results, 0..) |*r, i| {
        const sub_agent = parsed.sub_agents[i];
        r.mutex.lock();
        const result = r.result;
        const err_msg = r.err_msg;
        r.mutex.unlock();

        if (err_msg) |em| {
            logger.errFmt("spawn_sub_agent: agent '{s}' failed: {s}", .{ sub_agent.name, em }) catch {};
            // CRITICAL FIX: Duplicate the string before thread_results is freed
            // Without this, the string would be freed below and we'd have a use-after-free
            try results.append(allocator, try allocator.dupe(u8, em));
        } else if (result) |res| {
            // CRITICAL FIX: Duplicate the string before thread_results is freed
            // Without this, the string would be freed below and we'd have a use-after-free
            try results.append(allocator, try allocator.dupe(u8, res));
        } else {
            // Shouldn't happen but handle gracefully
            try results.append(allocator, "ERROR: unknown result");
        }
    }

    // Free thread result slots
    for (thread_results) |*r| {
        if (r.result) |res| allocator.free(res);
        if (r.err_msg) |err| allocator.free(err);
    }
    allocator.free(thread_results);

    var combined_result = std.ArrayList(u8).empty;
    var w = combined_result.writer(allocator);

    for (parsed.sub_agents, 0..) |sub_agent, i| {
        try w.print("=== {s} ===\n", .{sub_agent.name});
        if (i < results.items.len) {
            try w.writeAll(results.items[i]);
        }
        try w.writeByte('\n');
    }

    const result_msg = try combined_result.toOwnedSlice(allocator);

    const copy_result_msg = try allocator.dupe(u8, result_msg);

    // CRITICAL FIX: Duplicate tool_call.id from arena to persistent allocator
    // The tool_call.id was allocated from the workflow's arena which gets reset
    // between loop iterations, causing garbage in the result
    // const tool_call_id_dup = try allocator.dupe(u8, tool_call.id);

    // Save to DB
    // _ = try SaveMessage(allocator, db, .{
    //     .session_id = session_id,
    //     .model = model,
    //     .cwd = cwd,
    //     .content = copy_result_msg,
    //     .reasoning_content = null,
    //     .role = "tool",
    //     .finish_reason = "tool",
    //     .tool_calls = null,
    //     .tool_call_id = tool_call_id_dup,
    //     .agent_name = current_agent,
    //     .session_name = session_name,
    //     .loop_index = loop_counter,
    //     .temperature = agent_temperature,
    //     .is_thinking = is_thinking,
    //     .prompt_tokens = 0,
    //     .completion_tokens = 0,
    //     .total_tokens = 0,
    // });
    //
    // SendToolResult(allocator, session_id, logger, .tool_result, .{ .tool_call_id = tool_call_id_dup, .tool_name = "spawn_sub_agent", .tool_result = copy_result_msg });

    return copy_result_msg;
}

test {
    _ = @import("handle_spawn_sub_agent_test.zig");
}
