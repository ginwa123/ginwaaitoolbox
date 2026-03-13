const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const tool_models = tree1_mod.tool_models;
const logger_mod = tree1_mod.logger;
const sqlite = tree1_mod.sqlite;
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
const save_message = @import("save_message.zig");
const send_tool_result = @import("send_tool_result.zig");
const get_current_agent_by_session_id = @import("get_current_agent_by_session_id.zig");
const handle_tool = @import("handle_tool.zig");
const handle_read_file_tool = @import("handle_read_file_tool.zig");
const handle_search_tool = @import("handle_search_tool.zig");
const handle_text_replace_tool = @import("handle_text_replace_tool.zig");
const handle_write_file_tool = @import("handle_write_file_tool.zig");
const handle_list_skills_tool = @import("handle_list_skills_tool.zig");
const handle_get_skill_tool = @import("handle_get_skill_tool.zig");
const handle_remove_skill_tool = @import("handle_remove_skill_tool.zig");
const loop_detector = tree1_mod.loop_detector;

const MAX_SUB_AGENTS = 20;
const MAX_TOOL_CALLS = 100; // Max tool calls per sub-agent to prevent infinite loops

// Import BashInput from models (not exported in bash.zig)
const BashInput = @import("../../modules/agent/tools/models.zig").BashInput;

/// All available tools for sub-agents (no spawn_sub_agent, no set_agent_properties)
const all_sub_agent_tools: []const tool_models.AgentTool = &.{
    bash_tool.bashTool,
    read_file_tool.readFileTool,
    write_file_tool.writeFileTool,
    text_replace_tool.textReplaceTool,
    search_tool.searchTool,
    list_skills_tool.listSkillsTool,
    get_skill_tool.getSkillTool,
    remove_skill_tool.removeSkillTool,
};

/// Filter tools by allowed names. If allowed_tools is null, return all tools.
fn getAllowedTools(allocator: std.mem.Allocator, allowed_tools: ?[]const []const u8) ![]const tool_models.AgentTool {
    if (allowed_tools == null) {
        // Return all tools (copy the slice)
        return try allocator.dupe(tool_models.AgentTool, all_sub_agent_tools);
    }

    var result = std.ArrayList(tool_models.AgentTool).empty;
    errdefer result.deinit(allocator);

    for (all_sub_agent_tools) |tool| {
        for (allowed_tools.?) |allowed| {
            if (std.mem.eql(u8, tool.function.name, allowed)) {
                try result.append(allocator, tool);
                break;
            }
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Run a single sub-agent with basic tools (but no spawn_sub_agent or set_agent_properties)
fn runSubAgent(
    allocator: std.mem.Allocator,
    logger: *logger_mod.Logger,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    cwd: []const u8,
    instruction: []const u8,
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
    config: *const config_mod.LlmConfig,
    allowed_tools: ?[]const []const u8, // optional list of tool names to allow
    // New parameters for saving messages to DB
    // session_id: []const u8,
    // session_name: ?[]const u8,
    loop_index: u32,
    agent_temperature: f32,
    is_thinking: bool,
    agent_name: []const u8,
    parent_session_id: []const u8,
    parent_id: []const u8,
) ![]const u8 {
    _ = config; // reserved for future use (e.g., MCP tools)
    // session_id is now passed as parameter - use it for DB and SSE
    const session_name = try std.fmt.allocPrint(allocator, "{}", .{std.time.nanoTimestamp()});

    // Save user instruction message to DB
    _ = try save_message.run(allocator, db, .{
        .session_id = session_id,
        .model = model,
        .cwd = cwd,
        .content = instruction,
        .response_content = null,
        .response_finish_reason = null,
        .response_reasoning_content = null,
        .role = "user",
        .finish_reason = "null",
        .tool_calls = null,
        .tool_call_id = null,
        .agent_name = agent_name,
        .session_name = session_name,
        .loop_index = loop_index,
        .temperature = agent_temperature,
        .is_thinking = is_thinking,
        .parent_session_id = parent_session_id,
        .parent_id = parent_id,
        // User messages have no LLM token usage
        .prompt_tokens = 0,
        .completion_tokens = 0,
        .total_tokens = 0,
    });

    // Get tools based on allowed_tools (null = all tools)
    const sub_agent_tools = try getAllowedTools(allocator, allowed_tools);
    // defer {
    //     for (sub_agent_tools) |t| {
    //         allocator.free(t.function.name);
    //         allocator.free(t.function.description);
    //         for (t.function.parameters.properties) |p| {
    //             allocator.free(p.name);
    //             allocator.free(p.type);
    //             allocator.free(p.description);
    //         }
    //         allocator.free(t.function.parameters.properties);
    //         allocator.free(t.function.parameters.required);
    //     }
    //     allocator.free(sub_agent_tools);
    // }

    var sub_agent = try agent.Agent.init(allocator, logger);
    // defer sub_agent.deinit(); // disable this temporary because free corrupts the memory

    sub_agent.apiKey = api_key;
    sub_agent.model = model;
    sub_agent.baseUrl = base_url;
    sub_agent.httpOptions.read_timeout_ms = 300_000; // 10 minutes

    // Build messages: empty system + user instruction
    var messages: std.ArrayList(agent.AgentMessage) = .empty;
    defer messages.deinit(allocator);

    try messages.append(allocator, .{
        .role = .user,
        .content = instruction,
    });

    var tool_call_count: usize = 0;
    var last_response: ?agent.CallResponse = null;

    while (tool_call_count < MAX_TOOL_CALLS) {
        const params = agent.AgentCall{
            .tools = sub_agent_tools,
            .messages = messages.items,
            .temperature = 0.3,
            .max_tokens = 4000,
        };

        last_response = try sub_agent.call(params);
        const response = last_response.?;

        // Save assistant response to DB
        const assistant_tool_calls = if (response.tool_calls) |tcs| tcs else null;
        _ = try save_message.run(allocator, db, .{
            .session_id = session_id,
            .model = model,
            .cwd = cwd,
            .content = null,
            .response_content = response.content,
            .response_finish_reason = if (response.finish_reason) |fr| fr.toStr() else null,
            .response_reasoning_content = response.reasoning_content,
            .role = "assistant",
            .finish_reason = null,
            .tool_calls = assistant_tool_calls,
            .tool_call_id = null,
            .agent_name = agent_name,
            .session_name = session_name,
            .loop_index = loop_index,
            .temperature = agent_temperature,
            .is_thinking = is_thinking,
            .parent_session_id = parent_session_id,
            .parent_id = parent_id,
            .prompt_tokens = response.usage.prompt_tokens,
            .completion_tokens = response.usage.completion_tokens,
            .total_tokens = response.usage.total_tokens,
        });

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
                            const bash_input_opt = parseBashInput(allocator, tc.function.arguments) catch |err| blk: {
                                const err_str = try std.fmt.allocPrint(allocator, "ERROR: bash failed: {s}", .{@errorName(err)});
                                send_tool_result.run(allocator, parent_session_id, logger, err_str, tc.id, "bash", null);
                                allocator.free(err_str);
                                break :blk null;
                            };
                            if (bash_input_opt) |bash_input| {
                                const result = bash_tool.executeBash(allocator, bash_input) catch |err| blk: {
                                    const err_str = try std.fmt.allocPrint(allocator, "ERROR: bash failed: {s}", .{@errorName(err)});
                                    send_tool_result.run(allocator, parent_session_id, logger, err_str, tc.id, "bash", null);
                                    allocator.free(err_str);
                                    break :blk null;
                                };
                                if (result) |r| {
                                    tool_result = try bash_tool.bashResultToString(allocator, r);
                                } else {
                                    tool_result = "Error: bash execution failed";
                                }
                            } else {
                                tool_result = "Error: bash input parsing failed";
                            }
                            // Send tool result immediately after execution
                            send_tool_result.run(allocator, parent_session_id, logger, tool_result, tc.id, "bash", null);
                        } else if (std.mem.eql(u8, tc.function.name, "read_file")) {
                            tool_result = handle_read_file_tool.run(allocator, tc) catch |err| blk: {
                                const err_str = try std.fmt.allocPrint(allocator, "ERROR: read_file failed: {s}", .{@errorName(err)});
                                send_tool_result.run(allocator, parent_session_id, logger, err_str, tc.id, "read_file", null);
                                allocator.free(err_str);
                                break :blk try std.fmt.allocPrint(allocator, "Error: {s}", .{@errorName(err)});
                            };
                            // Send tool result immediately after execution
                            send_tool_result.run(allocator, parent_session_id, logger, tool_result, tc.id, "read_file", null);
                        } else if (std.mem.eql(u8, tc.function.name, "search")) {
                            tool_result = handle_search_tool.run(allocator, tc) catch |err| blk: {
                                const err_str = try std.fmt.allocPrint(allocator, "ERROR: search failed: {s}", .{@errorName(err)});
                                send_tool_result.run(allocator, parent_session_id, logger, err_str, tc.id, "search", null);
                                allocator.free(err_str);
                                break :blk try std.fmt.allocPrint(allocator, "Error: {s}", .{@errorName(err)});
                            };
                            // Send tool result immediately after execution
                            send_tool_result.run(allocator, parent_session_id, logger, tool_result, tc.id, "search", null);
                        } else if (std.mem.eql(u8, tc.function.name, "text_replace")) {
                            tool_result = handle_text_replace_tool.run(allocator, tc) catch |err| blk: {
                                const err_str = try std.fmt.allocPrint(allocator, "ERROR: text_replace failed: {s}", .{@errorName(err)});
                                send_tool_result.run(allocator, parent_session_id, logger, err_str, tc.id, "text_replace", null);
                                allocator.free(err_str);
                                break :blk try std.fmt.allocPrint(allocator, "Error: {s}", .{@errorName(err)});
                            };
                            // Send tool result immediately after execution
                            send_tool_result.run(allocator, parent_session_id, logger, tool_result, tc.id, "text_replace", null);
                        } else if (std.mem.eql(u8, tc.function.name, "write_file")) {
                            tool_result = handle_write_file_tool.run(allocator, tc) catch |err| blk: {
                                const err_str = try std.fmt.allocPrint(allocator, "ERROR: write_file failed: {s}", .{@errorName(err)});
                                send_tool_result.run(allocator, parent_session_id, logger, err_str, tc.id, "write_file", null);
                                allocator.free(err_str);
                                break :blk try std.fmt.allocPrint(allocator, "Error: {s}", .{@errorName(err)});
                            };
                            // Send tool result immediately after execution
                            send_tool_result.run(allocator, parent_session_id, logger, tool_result, tc.id, "write_file", null);
                        } else if (std.mem.eql(u8, tc.function.name, "list_skills")) {
                            tool_result = handle_list_skills_tool.run(allocator);
                            // Send tool result immediately after execution
                            send_tool_result.run(allocator, parent_session_id, logger, tool_result, tc.id, "list_skills", null);
                        } else if (std.mem.eql(u8, tc.function.name, "get_skill")) {
                            tool_result = handle_get_skill_tool.run(allocator, tc) catch |err| blk: {
                                const err_str = try std.fmt.allocPrint(allocator, "ERROR: get_skill failed: {s}", .{@errorName(err)});
                                send_tool_result.run(allocator, parent_session_id, logger, err_str, tc.id, "get_skill", null);
                                allocator.free(err_str);
                                break :blk try std.fmt.allocPrint(allocator, "Error: {s}", .{@errorName(err)});
                            };
                            // Send tool result immediately after execution
                            send_tool_result.run(allocator, parent_session_id, logger, tool_result, tc.id, "get_skill", null);
                        } else if (std.mem.eql(u8, tc.function.name, "remove_skill")) {
                            tool_result = handle_remove_skill_tool.run(allocator, tc) catch |err| blk: {
                                const err_str = try std.fmt.allocPrint(allocator, "ERROR: remove_skill failed: {s}", .{@errorName(err)});
                                send_tool_result.run(allocator, parent_session_id, logger, err_str, tc.id, "remove_skill", null);
                                allocator.free(err_str);
                                break :blk try std.fmt.allocPrint(allocator, "Error: {s}", .{@errorName(err)});
                            };
                            // Send tool result immediately after execution
                            send_tool_result.run(allocator, parent_session_id, logger, tool_result, tc.id, "remove_skill", null);
                        } else {
                            tool_result = try std.fmt.allocPrint(allocator, "ERROR: Unknown tool '{s}'", .{tc.function.name});
                            // Send tool result for unknown tool
                            send_tool_result.run(allocator, parent_session_id, logger, tool_result, tc.id, tc.function.name, null);
                        }

                        // Save tool result to DB
                        _ = try save_message.run(allocator, db, .{
                            .session_id = session_id,
                            .model = model,
                            .cwd = cwd,
                            .content = tool_result,
                            .response_content = null,
                            .response_finish_reason = null,
                            .response_reasoning_content = null,
                            .role = "tool",
                            .finish_reason = "tool",
                            .tool_calls = null,
                            .tool_call_id = tc.id,
                            .agent_name = agent_name,
                            .session_name = session_name,
                            .loop_index = loop_index,
                            .temperature = agent_temperature,
                            .is_thinking = is_thinking,
                            .parent_session_id = parent_session_id,
                            .parent_id = parent_id,
                            // Tool results have no LLM token usage
                            .prompt_tokens = 0,
                            .completion_tokens = 0,
                            .total_tokens = 0,
                        });

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
            return try allocator.dupe(u8, content);
        }
    }
    return try allocator.dupe(u8, "(max tool calls reached)");
}

/// Parse bash input from JSON arguments
fn parseBashInput(allocator: std.mem.Allocator, args: []const u8) !BashInput {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, args, .{});
    defer parsed.deinit();

    const root = parsed.value;
    const obj = root.object;

    const command = obj.get("command") orelse return error.MissingCommand;
    const cwd = obj.get("cwd");
    const timeout = obj.get("timeout");
    const max_output = obj.get("max_output");
    const stdin_data = obj.get("stdin_data");
    const background = obj.get("background");

    return .{
        .command = try allocator.dupe(u8, command.string),
        .cwd = if (cwd) |v| try allocator.dupe(u8, v.string) else null,
        .timeout = if (timeout) |v| @as(u32, @intCast(v.integer)) else null,
        .max_output = if (max_output) |v| @as(usize, @intCast(v.integer)) else null,
        .stdin_data = if (stdin_data) |v| try allocator.dupe(u8, v.string) else null,
        .background = if (background) |v| v.bool else false,
    };
}

/// Parse JSON input and run spawn_sub_agent handler
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
    api_key: []const u8,
    base_url: []const u8,
    config: *const config_mod.LlmConfig,
) !void {
    // Parse the JSON input from function.arguments
    logger.infoFmt("spawn_sub_agent: parsing JSON input", .{}) catch {};
    logger.debugFmt("spawn_sub_agent: JSON input: {s}", .{tool_call.function.arguments}) catch {};
    const parsed = try spawn_sub_agent_tool.parseSubAgents(allocator, tool_call.function.arguments, MAX_SUB_AGENTS);
    // defer parsed.deinit(allocator);

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

                const sessionId = std.fmt.allocPrint(thread_alloc, "{}_{}", .{ idx, std.time.nanoTimestamp() }) catch |err| {
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
    const tool_call_id_dup = try allocator.dupe(u8, tool_call.id);

    const tool_result_msg = agent.AgentMessage{
        .role = .tool,
        .content = result_msg,
        .tool_call_id = tool_call_id_dup,
    };
    try messages_list.append(allocator, tool_result_msg);

    // Save to DB
    _ = try save_message.run(allocator, db, .{
        .session_id = session_id,
        .model = model,
        .cwd = cwd,
        .content = copy_result_msg,
        .response_content = null,
        .response_finish_reason = null,
        .response_reasoning_content = null,
        .role = "tool",
        .finish_reason = "tool",
        .tool_calls = null,
        .tool_call_id = tool_call_id_dup,
        .agent_name = current_agent,
        .session_name = session_name,
        .loop_index = loop_counter,
        .temperature = agent_temperature,
        .is_thinking = is_thinking,
        // .parent_session_id = parent_session_id,
        // .parent_id = parent_id,
        // Tool results have no LLM token usage
        .prompt_tokens = 0,
        .completion_tokens = 0,
        .total_tokens = 0,
    });

    _ = send_tool_result.run(allocator, session_id, logger, copy_result_msg, tool_call_id_dup, "spawn_sub_agent", null);

    logger.infoFmt("spawn_sub_agent: completed {} sub-agents", .{parsed.sub_agents.len}) catch {};
}

test {
    _ = @import("handle_spawn_sub_agent_test.zig");
}
