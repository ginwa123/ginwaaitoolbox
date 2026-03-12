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

/// All available tools for sub-agents (no spawn_sub_agent, no change_agent_tool)
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

/// Run a single sub-agent with basic tools (but no spawn_sub_agent or change_agent_tool)
fn runSubAgent(
    allocator: std.mem.Allocator,
    logger: *logger_mod.Logger,
    // db kept for future use
    db: *sqlite.SqliteBackend,
    cwd: []const u8,
    instruction: []const u8,
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
    // config kept for future use (e.g., MCP tools)
    config: *const config_mod.LlmConfig,
    allowed_tools: ?[]const []const u8, // optional list of tool names to allow
) ![]const u8 {
    _ = db; // reserved for future use
    _ = cwd; // reserved for future use
    _ = config; // reserved for future use

    // Get tools based on allowed_tools (null = all tools)
    const sub_agent_tools = try getAllowedTools(allocator, allowed_tools);
    defer {
        for (sub_agent_tools) |t| {
            allocator.free(t.function.name);
            allocator.free(t.function.description);
            for (t.function.parameters.properties) |p| {
                allocator.free(p.name);
                allocator.free(p.type);
                allocator.free(p.description);
            }
            allocator.free(t.function.parameters.properties);
            allocator.free(t.function.parameters.required);
        }
        allocator.free(sub_agent_tools);
    }

    var sub_agent = try agent.Agent.init(allocator, logger);
    defer sub_agent.deinit();

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

                        // Execute basic tools inline (no spawn_sub_agent or change_agent_tool)
                        var tool_result: []const u8 = undefined;

                        if (std.mem.eql(u8, tc.function.name, "bash")) {
                            const result = try bash_tool.executeBash(allocator, try parseBashInput(allocator, tc.function.arguments));
                            tool_result = try bash_tool.bashResultToString(allocator, result);
                        } else if (std.mem.eql(u8, tc.function.name, "read_file")) {
                            tool_result = try handle_read_file_tool.run(allocator, tc);
                        } else if (std.mem.eql(u8, tc.function.name, "search")) {
                            tool_result = try handle_search_tool.run(allocator, tc);
                        } else if (std.mem.eql(u8, tc.function.name, "text_replace")) {
                            tool_result = try handle_text_replace_tool.run(allocator, tc);
                        } else if (std.mem.eql(u8, tc.function.name, "write_file")) {
                            tool_result = try handle_write_file_tool.run(allocator, tc);
                        } else if (std.mem.eql(u8, tc.function.name, "list_skills")) {
                            tool_result = handle_list_skills_tool.run(allocator);
                        } else if (std.mem.eql(u8, tc.function.name, "get_skill")) {
                            tool_result = try handle_get_skill_tool.run(allocator, tc);
                        } else if (std.mem.eql(u8, tc.function.name, "remove_skill")) {
                            tool_result = try handle_remove_skill_tool.run(allocator, tc);
                        } else {
                            tool_result = try std.fmt.allocPrint(allocator, "ERROR: Unknown tool '{s}'", .{tc.function.name});
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
    parent_session_id: []const u8,
    parent_id: []const u8,
) !void {
    // Parse the JSON input from function.arguments
    logger.infoFmt("spawn_sub_agent: parsing JSON input", .{}) catch {};
    logger.debugFmt("spawn_sub_agent: JSON input: {s}", .{tool_call.function.arguments}) catch {};
    const parsed = try spawn_sub_agent_tool.parseSubAgents(allocator, tool_call.function.arguments, MAX_SUB_AGENTS);
    defer parsed.deinit(allocator);

    logger.infoFmt("spawn_sub_agent: spawning {} parallel sub-agents", .{parsed.sub_agents.len}) catch {};

    // Run each sub-agent and collect results
    var results: std.ArrayList([]const u8) = .empty;
    defer {
        for (results.items) |r| allocator.free(r);
        results.deinit(allocator);
    }

    for (parsed.sub_agents) |sub_agent| {
        logger.infoFmt("spawn_sub_agent: running agent '{s}' with instruction: {s}", .{ sub_agent.name, sub_agent.instruction }) catch {};

        const result = runSubAgent(allocator, logger, db, cwd, sub_agent.instruction, api_key, model, base_url, config, sub_agent.tools) catch |err| {
            logger.errFmt("spawn_sub_agent: agent '{s}' failed: {s}", .{ sub_agent.name, @errorName(err) }) catch {};
            const err_msg = try std.fmt.allocPrint(allocator, "ERROR: {s}", .{@errorName(err)});
            defer allocator.free(err_msg);
            try results.append(allocator, err_msg);
            continue;
        };
        try results.append(allocator, result);
    }

    // Build combined result message
    var combined_result = std.ArrayList(u8).empty;
    defer combined_result.deinit(allocator);
    var w = combined_result.writer(allocator);

    try w.writeAll("<sub_agent_results>\n");
    for (parsed.sub_agents, 0..) |sub_agent, i| {
        try w.print("  <result name=\"{s}\">\n", .{sub_agent.name});
        if (i < results.items.len) {
            // Escape XML entities in result
            const result = results.items[i];
            for (result) |ch| {
                switch (ch) {
                    '&' => try w.writeAll("&amp;"),
                    '<' => try w.writeAll("&lt;"),
                    '>' => try w.writeAll("&gt;"),
                    '"' => try w.writeAll("&quot;"),
                    '\'' => try w.writeAll("&apos;"),
                    else => try w.writeByte(ch),
                }
            }
        }
        try w.writeAll("\n  </result>\n");
    }
    try w.writeAll("</sub_agent_results>");

    const result_msg = try combined_result.toOwnedSlice(allocator);

    // Fetch current agent from DB
    const current_agent_state = try get_current_agent_by_session_id.run(
        allocator,
        db,
        session_id,
    );
    const current_agent = current_agent_state.agent;

    const tool_result_msg = agent.AgentMessage{
        .role = .tool,
        .content = result_msg,
        .tool_call_id = try allocator.dupe(u8, tool_call.id),
    };
    try messages_list.append(allocator, tool_result_msg);

    // Save to DB
    _ = try save_message.run(allocator, db, .{
        .session_id = session_id,
        .model = model,
        .cwd = cwd,
        .content = result_msg,
        .response_content = null,
        .response_finish_reason = null,
        .response_reasoning_content = null,
        .role = "tool",
        .finish_reason = "tool",
        .tool_calls = null,
        .tool_call_id = tool_call.id,
        .agent_name = current_agent,
        .session_name = session_name,
        .loop_index = loop_counter,
        .temperature = agent_temperature,
        .is_thinking = is_thinking,
        .parent_session_id = parent_session_id,
        .parent_id = parent_id,
    });

    _ = send_tool_result.run(allocator, session_id, logger, result_msg, tool_call.id, "spawn_sub_agent", null);

    logger.infoFmt("spawn_sub_agent: completed {} sub-agents", .{parsed.sub_agents.len}) catch {};
}

test {
    _ = @import("handle_spawn_sub_agent_test.zig");
}
