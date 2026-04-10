const std = @import("std");
const root_mod = @import("nalarcore");
const agent = root_mod.agent;
const tool_models = root_mod.tool_models;
const logger_mod = root_mod.logger;
const sqlite = root_mod.sqlite;
const prompt = root_mod.prompt;
const spawn_sub_agent_tool = root_mod.spawn_sub_agent;
const bash_tool = root_mod.bash_tool;
const read_file_tool = root_mod.read_file;
const write_file_tool = root_mod.write_file;
const search_tool = root_mod.search_tool;
const glob_tool = root_mod.glob_tool;
const text_replace_tool = root_mod.text_replace_tool;
const list_skills_tool = root_mod.list_skills_tool;
const get_skill_tool = root_mod.get_skill_tool;
const remove_skill_tool = root_mod.remove_skill_tool;
const config_mod = root_mod.config;
const save_message = @import("save_message.zig").save_message;
const session_helpers = @import("session_helpers.zig");
const getCurrentAgentBySessionId = session_helpers.get_current_agent_by_session_id;
const handle_tool = @import("handle_tool.zig");
const bash_tool_mod = root_mod.bash_tool;
const read_file_mod = root_mod.read_file;
const search_tool_mod = root_mod.search_tool;
const glob_tool_mod = root_mod.glob_tool;
const text_replace_mod = root_mod.text_replace_tool;
const write_file_mod = root_mod.write_file;
const list_skills_mod = root_mod.list_skills_tool;
const get_skill_mod = root_mod.get_skill_tool;
const remove_skill_mod = root_mod.remove_skill_tool;
const list_agents_mod = root_mod.list_agents;
const change_agent_mod = root_mod.change_agent;
const tools_mod = root_mod.tools;
const handle_read_file_tool = @import("handle_read_file_tool.zig");
const handle_search_tool = @import("handle_search_tool.zig");
const handle_glob_tool = @import("handle_glob_tool.zig");
const handle_text_replace_tool = @import("handle_text_replace_tool.zig");
const handle_write_file_tool = @import("handle_write_file_tool.zig");
const handle_list_skills_tool = @import("handle_list_skills_tool.zig");
const handle_get_skill_tool = @import("handle_get_skill_tool.zig");
const handle_remove_skill_tool = @import("handle_remove_skill_tool.zig");
const handle_list_agents_tool = @import("handle_list_agents_tool.zig");
const handle_change_agent_tool = @import("handle_change_agent_tool.zig");
const handle_lsp_definition_tool = @import("handle_lsp_definition_tool.zig");
const handle_bash_tool = @import("handle_bash_tool.zig");
const TransformLLMHistory = @import("transform_llm_history_to_agent_messages.zig");
const StreamingContext = @import("workflow.zig").StreamingContext;
const BuildSkillContent = @import("build_skill_for_agent_prompt.zig").BuildSkillContent;
const SaveSkill = @import("save_skill.zig").SaveSkill;
const SaveAgent = @import("save_agent.zig").SaveAgent;
const handle_mcp_tool = @import("handle_mcp_tool.zig");
const buildMcpTools = @import("build_messages_tools_mcp_for_agent_prompt.zig");

const MAX_SUB_AGENTS = 20;

// Import BashInput from schemas (not exported in bash.zig)
const BashInput = tool_models.BashInput;

// ============================================================================
// SUB-AGENT TOOL DISPATCH TABLE
// ============================================================================

/// Function signature for sub-agent tool executors
pub const SubAgentToolExec = *const fn (
    allocator: std.mem.Allocator,
    tc: agent.ToolCall,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) anyerror![]const u8;

/// Entry in the sub-agent tool registry
const SubAgentToolEntry = struct {
    name: []const u8,
    exec: SubAgentToolExec,
    auto_save_skill: bool = false,
    auto_save_agent: bool = false,
};

/// Tool execution result with optional auto-save metadata
const SubAgentToolResult = struct {
    output: []const u8,
    skill_save: ?SkillSaveInfo = null,
    agent_save: ?AgentSaveInfo = null,
};

const SkillSaveInfo = struct {
    name: []const u8,
    content: []const u8,
};

const AgentSaveInfo = struct {
    name: []const u8,
};

// Individual tool executors
pub fn execBash(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    return handle_bash_tool.runWithContext(allocator, tc, db, session_id);
}

pub fn execReadFile(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = db;
    _ = session_id;
    return handle_read_file_tool.handle_read_file_tool_run(allocator, tc);
}

pub fn execSearch(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = db;
    _ = session_id;
    return handle_search_tool.handle_search_tool_run(allocator, tc);
}

pub fn execGlob(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = db;
    _ = session_id;
    return handle_glob_tool.handle_glob_tool_run(allocator, tc);
}

pub fn execTextReplace(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = db;
    _ = session_id;
    return handle_text_replace_tool.handle_text_replace_tool_run(allocator, tc);
}

pub fn execWriteFile(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = db;
    _ = session_id;
    return handle_write_file_tool.handle_write_file_tool_run(allocator, tc);
}

pub fn execListSkills(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = tc;
    _ = db;
    _ = session_id;
    return handle_list_skills_tool.handle_list_skills_tool_run(allocator);
}

pub fn execGetSkill(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = db;
    _ = session_id;
    return handle_get_skill_tool.handle_get_skill_tool_run(allocator, tc);
}

pub fn execRemoveSkill(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = db;
    _ = session_id;
    return handle_remove_skill_tool.handle_remove_skill_tool_run(allocator, tc);
}

pub fn execListAgents(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = tc;
    _ = db;
    _ = session_id;
    return handle_list_agents_tool.handle_list_agents_tool_run(allocator);
}

pub fn execChangeAgent(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = db;
    _ = session_id;
    return handle_change_agent_tool.handle_change_agent_tool_run(allocator, tc);
}

pub fn execLspDefinition(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = db;
    _ = session_id;
    return handle_lsp_definition_tool.handle_lsp_definition_tool_run(allocator, tc);
}

/// MCP tool executor - placeholder for dynamic MCP tool handling
/// Note: MCP tools are actually handled dynamically in executeSubAgentTool
/// This function is kept for API completeness but is not used
pub fn execMCP(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = allocator;
    _ = tc;
    _ = db;
    _ = session_id;
    // MCP tools are handled dynamically in executeSubAgentTool
    return "MCP tools are handled dynamically";
}

/// Placeholder for spawn_sub_agent exec
pub fn execSpawnSubAgent(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = allocator;
    _ = tc;
    _ = db;
    _ = session_id;
    return "spawn_sub_agent should not be called from sub-agent context";
}

/// Placeholder for set_agent_properties exec
pub fn execSetAgentProperties(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = allocator;
    _ = tc;
    _ = db;
    _ = session_id;
    return "set_agent_properties should not be called from sub-agent context";
}

// Placeholder LSP exec functions (TODO: implement when lsp.zig is complete)
pub fn execLspReferences(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = allocator;
    _ = tc;
    _ = db;
    _ = session_id;
    return "lsp_references not implemented";
}

pub fn execLspWorkspaceSymbol(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = allocator;
    _ = tc;
    _ = db;
    _ = session_id;
    return "lsp_workspace_symbol not implemented";
}

pub fn execLspDocumentSymbol(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = allocator;
    _ = tc;
    _ = db;
    _ = session_id;
    return "lsp_document_symbol not implemented";
}

pub fn execLspHover(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = allocator;
    _ = tc;
    _ = db;
    _ = session_id;
    return "lsp_hover not implemented";
}

// Web search tool handlers
const handle_web_search_tool = @import("handle_web_search_tool.zig");
const handle_web_search_help_tool = @import("handle_web_search_help_tool.zig");

pub fn execWebSearch(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    return handle_web_search_tool.runWithContext(allocator, tc, db, session_id);
}

pub fn execWebSearchHelp(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    return handle_web_search_help_tool.runWithContext(allocator, tc, db, session_id);
}

// Import tool registry for unified tool definitions
const tool_registry = @import("tool_registry.zig");

/// Execute a tool by name, returning the result
pub fn execute_sub_agent_tool(
    allocator: std.mem.Allocator,
    tc: agent.ToolCall,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    config: *const config_mod.LlmConfig,
    logger: ?*logger_mod.Logger,
) !SubAgentToolResult {
    _ = model;
    _ = cwd;
    // Check if it's an MCP tool first (dynamic handling)
    if (is_mcp_tool(config, tc.function.name)) {
        if (logger) |log| {
            const mcp_result = try handle_mcp_tool.handle_mcp_tool_run(allocator, log, tc, config);
            return SubAgentToolResult{ .output = mcp_result };
        } else {
            // Create a minimal logger for MCP calls when no logger is available
            var minimal_logger = logger_mod.Logger.init(allocator, .{
                .min_level = .err, // Only errors
                .output_mode = .stdout,
            });
            defer minimal_logger.deinit();
            const mcp_result = try handle_mcp_tool.handle_mcp_tool_run(allocator, &minimal_logger, tc, config);
            return SubAgentToolResult{ .output = mcp_result };
        }
    }

    inline for (tool_registry.SUB_AGENT_TOOL_REGISTRY) |entry| {
        if (std.mem.eql(u8, tc.function.name, entry.name)) {
            const output = entry.exec(allocator, tc, db, session_id) catch |err| {
                return SubAgentToolResult{
                    .output = try std.fmt.allocPrint(allocator, "<error> {s} failed: {s}</error>", .{
                        tc.function.name,
                        @errorName(err),
                    }),
                };
            };

            var result = SubAgentToolResult{ .output = output };

            // Auto-save skill if this tool loaded one
            if (entry.auto_save_skill) {
                if (parseSkillFromResult(output)) |info| {
                    result.skill_save = SkillSaveInfo{ .name = info.name, .content = info.content };
                }
            }

            // Auto-save agent if this tool loaded one
            if (entry.auto_save_agent) {
                if (parseAgentFromResult(output)) |name| {
                    result.agent_save = AgentSaveInfo{ .name = name };
                }
            }

            return result;
        }
    }

    return error.UnknownTool;
}

/// Check if a tool name is an MCP tool (format: serverName_toolName)
fn is_mcp_tool(config: *const config_mod.LlmConfig, tool_name: []const u8) bool {
    if (config.mcpServers == null) return false;
    // Tool names must start with "mcp_"
    if (!std.mem.startsWith(u8, tool_name, "mcp_")) return false;
    // Find the second underscore to get server_name
    const after_mcp = tool_name["mcp_".len..];
    const underscore_idx = std.mem.indexOf(u8, after_mcp, "_") orelse return false;
    const server_name = after_mcp[0..underscore_idx];
    const mcp_servers = switch (config.mcpServers.?) {
        .object => |obj| obj,
        else => return false,
    };
    return mcp_servers.get(server_name) != null;
}

// ============================================================================
// HELPER FUNCTIONS - Skill/Agent Parsing
// ============================================================================

pub fn parseSkillFromResult(result: []const u8) ?struct { name: []const u8, content: []const u8 } {
    if (std.mem.indexOf(u8, result, "<loaded>true</loaded>") == null) return null;

    const name_start = std.mem.indexOf(u8, result, "<skill_name>") orelse return null;
    const name_begin = name_start + "<skill_name>".len;
    const name_end = std.mem.indexOf(u8, result[name_begin..], "</skill_name>") orelse return null;
    const skill_name = result[name_begin .. name_begin + name_end];

    const content_start = std.mem.indexOf(u8, result, "<content>") orelse return null;
    const content_begin = content_start + "<content>".len;
    const content_end = std.mem.indexOf(u8, result[content_begin..], "</content>") orelse return null;
    const skill_content = result[content_begin .. content_begin + content_end];

    return .{ .name = skill_name, .content = skill_content };
}

pub fn parseAgentFromResult(result: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, result, "<loaded>true</loaded>") == null) return null;

    const name_start = std.mem.indexOf(u8, result, "<agent_name>") orelse return null;
    const name_begin = name_start + "<agent_name>".len;
    const name_end = std.mem.indexOf(u8, result[name_begin..], "</agent_name>") orelse return null;
    return result[name_begin .. name_begin + name_end];
}

// ============================================================================
// FILTERED TOOLS FOR SUB-AGENTS
// ============================================================================

/// Get all sub-agent tools as a filtered list
/// If allowed_tools is null, returns all sub-agent tools
/// Always excludes spawn_sub_agent and set_agent_properties for security
pub fn get_allowed_tools(allocator: std.mem.Allocator, allowed_tools: ?[]const []const u8, mcp_tools: ?[]const tool_models.AgentTool) ![]const tool_models.AgentTool {
    var result = std.ArrayList(tool_models.AgentTool).empty;

    for (tool_registry.SUB_AGENT_TOOL_REGISTRY) |entry| {
        // If no filter specified, include all tools
        if (allowed_tools == null) {
            try result.append(allocator, entry.tool_def);
        } else {
            // Check if this tool is in the allowed list
            for (allowed_tools.?) |allowed| {
                if (std.mem.eql(u8, entry.name, allowed)) {
                    try result.append(allocator, entry.tool_def);
                    break;
                }
            }
        }
    }

    // Add MCP tools to the list
    if (allowed_tools == null) {
        // If no filter, include all MCP tools
        if (mcp_tools) |mcp_tools_arr| {
            try result.appendSlice(allocator, mcp_tools_arr);
        }
    } else {
        // If there's a filter, only include MCP tools that match
        if (mcp_tools) |mcp_tools_arr| {
            for (mcp_tools_arr) |mcp_tool| {
                for (allowed_tools.?) |allowed| {
                    if (std.mem.eql(u8, mcp_tool.function.name, allowed)) {
                        try result.append(allocator, mcp_tool);
                        break;
                    }
                }
            }
        }
    }

    return try result.toOwnedSlice(allocator);
}

// ============================================================================
// SUB-AGENT EXECUTION
// ============================================================================

pub fn stream_callback(ctx: ?*anyopaque, chunk: agent.StreamChunk) void {
    _ = ctx;
    _ = chunk;
}

/// Run a single sub-agent with basic tools (but no spawn_sub_agent or set_agent_properties)
fn run_sub_agent(
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
    // Fetch MCP tools for sub-agent
    const mcp_tools = try buildMcpTools.build_mcp_tools_run(parentAllocator, config);

    const sessionName = try std.fmt.allocPrint(parentAllocator, "{}", .{std.time.nanoTimestamp()});

    // Save user instruction message to DB
    _ = try save_message(parentAllocator, db, .{
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

    // Get tools based on allowed_tools (null = all tools except restricted)
    const sub_agent_tools = try get_allowed_tools(parentAllocator, allowed_tools, mcp_tools);

    var sub_agent = try agent.Agent.init(parentAllocator, logger);

    sub_agent.apiKey = api_key;
    sub_agent.model = model;
    sub_agent.baseUrl = base_url;
    sub_agent.httpOptions.read_timeout_ms = 300_000; // 10 minutes

    var last_response: ?agent.CallResponse = null;

    var max_tokens: usize = 4000;

    while (true) {
        var arena_allocator = std.heap.ArenaAllocator.init(parentAllocator);
        defer arena_allocator.deinit();
        const allocator = arena_allocator.allocator();

        const skillContents = try BuildSkillContent(allocator, db, session_id);
        const systemPrompt = try prompt.buildAgentPrompt(allocator, cwd, "", skillContents, "", "", "");

        var messages: std.ArrayList(agent.AgentMessage) = .empty;
        try messages.append(allocator, .{
            .role = .system,
            .content = systemPrompt,
        });

        // Fetch existing messages from DB
        const tui_histories = try session_helpers.get_messages(allocator, db, session_id);
        for (tui_histories) |hist| {
            const agent_msgs = try TransformLLMHistory.transform_llm_history_to_agent_message(allocator, hist);
            for (agent_msgs) |msg| {
                try messages.append(allocator, msg);
            }
        }

        const params = agent.AgentCall{
            .tools = sub_agent_tools,
            .messages = messages.items,
            .temperature = 0.2,
            .max_tokens = max_tokens,
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
        _ = try save_message(allocator, db, .{
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

        // Check finish_reason
        if (response.finish_reason) |fr| {
            if (fr == .stop) {
                // Agent finished with stop - return the content
                if (response.content) |content| {
                    return try allocator.dupe(u8, content);
                }
                return try allocator.dupe(u8, "(empty response)");
            } else if (fr == .tool_calls) {
                // Process tool calls using dispatch table
                if (response.tool_calls) |tcs| {
                    for (tcs) |tc| {
                        logger.infoFmt("[SUB_AGENT] Tool: '{s}'", .{tc.function.name}) catch {};

                        const tool_result = execute_sub_agent_tool(allocator, tc, db, session_id, model, cwd, config, logger) catch |err| blk: {
                            const msg = try std.fmt.allocPrint(allocator, "<error> {s} failed: {s}</error>", .{
                                tc.function.name,
                                @errorName(err),
                            });
                            break :blk SubAgentToolResult{ .output = msg };
                        };

                        // Auto-save skill if loaded
                        if (tool_result.skill_save) |info| {
                            SaveSkill(allocator, db, logger, session_id, info.name, info.content) catch |err| {
                                const err_name = @errorName(err);
                                logger.errFmt("<error> saving skill to database: {s}</error>", .{err_name}) catch {};
                            };
                        }

                        // Auto-save agent if loaded
                        if (tool_result.agent_save) |info| {
                            SaveAgent(allocator, db, logger, session_id, info.name) catch |err| {
                                logger.errFmt("<error> saving agent to database: {s}</error>", .{@errorName(err)}) catch {};
                            };
                        }

                        // Save tool result to DB
                        _ = try save_message(allocator, db, .{
                            .session_id = session_id,
                            .model = model,
                            .cwd = cwd,
                            .content = tool_result.output,
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
                            .content = tool_result.output,
                            .tool_call_id = try allocator.dupe(u8, tc.id),
                        });
                    }
                }
            } else if (response.finish_reason == .length) {
                max_tokens += 4096;
                continue;
            } else {
                if (response.content) |content| {
                    return try allocator.dupe(u8, content);
                }
                break;
            }
        } else {
            break;
        }
    }

    if (last_response) |response| {
        if (response.content) |content| {
            return try parentAllocator.dupe(u8, content);
        }
    }
    return try parentAllocator.dupe(u8, "<error>unknown error subagent result, please spawn sub-agent again or just do without sub-agent</error>");
}

// ============================================================================
// PARALLEL SUB-AGENT EXECUTION
// ============================================================================

/// Thread-safe result storage for parallel agents
const ThreadResult = struct {
    result: ?[]const u8 = null,
    err_msg: ?[]const u8 = null,
    completed: bool = false,
    mutex: std.Thread.Mutex = .{},
};

/// Named thread entry point for running a single sub-agent
fn runSubAgentThread(
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
    _ = name;
    // Each thread gets its own arena allocator to prevent memory corruption
    // when multiple sub-agents run in parallel
    var thread_arena = std.heap.ArenaAllocator.init(alloc);
    defer thread_arena.deinit();
    const thread_alloc = thread_arena.allocator();

    // Create thread-safe config using clone() which deep-clones mcpServers
    // The clone() method serializes to JSON and parses back for thread safety
    var thread_config = cfg.clone() catch |err| {
        log.errFmt("spawn_sub_agent[{}]: failed to clone config for thread: {}", .{ idx, err }) catch {};
        return;
    };
    // Update allocator to thread allocator
    thread_config.allocator = thread_alloc;

    const sessionId = std.fmt.allocPrint(thread_alloc, "{}", .{std.time.nanoTimestamp()}) catch |err| {
        log.errFmt("spawn_sub_agent[{}]: failed to generate sessionId: {}", .{ idx, err }) catch {};
        return;
    };

    const run_result = run_sub_agent(
        thread_alloc,
        log,
        database,
        sessionId,
        workdir,
        instruction,
        llm_api_key,
        llm_model,
        url,
        &thread_config,
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
}

/// Parse JSON input and run spawn_sub_agent handler
pub fn handle_spawn_sub_agent_run(
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
    const parsed = try spawn_sub_agent_tool.parseSubAgents(allocator, tool_call.function.arguments, MAX_SUB_AGENTS);
    _ = _session_name; // unused parameter

    // Reject single sub-agent - must spawn at least 2 for parallel work
    if (parsed.sub_agents.len == 1) {
        return try std.fmt.allocPrint(allocator,
            \\ERROR: spawn_sub_agent requires at least 2 sub-agents.
            \\Spawning only 1 sub-agent is FORBIDDEN.
            \\If you need to run a single task, either:
            \\1. Do it directly yourself (no sub-agent needed for single tasks)
            \\2. Spawn 2+ sub-agents for parallel work
        , .{});
    }

    logger.infoFmt("spawn_sub_agent: spawning {} parallel sub-agents", .{parsed.sub_agents.len}) catch {};

    // Fetch current agent from DB (before running sub-agents)
    const current_agent_state = try getCurrentAgentBySessionId(
        allocator,
        db,
        session_id,
    );
    const current_agent = current_agent_state.agent;

    // Run all sub-agents in parallel using threads
    const num_agents = parsed.sub_agents.len;

    // Allocate result slots for each sub-agent (thread-safe result storage)
    const thread_results = try allocator.alloc(ThreadResult, num_agents);
    @memset(thread_results, .{});

    // Spawn a thread for each sub-agent
    for (parsed.sub_agents, 0..) |sub_agent, index| {
        // Create a local copy of the sub_agent data for the thread
        const sub_agent_name = try allocator.dupe(u8, sub_agent.name);
        const sub_agent_instruction = try allocator.dupe(u8, sub_agent.instruction);
        const sub_agent_tools_copy = if (sub_agent.tools) |tools| try allocator.dupe([]const u8, tools) else null;

        const thread = try std.Thread.spawn(.{}, runSubAgentThread, .{
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
    var results = std.ArrayList([]const u8).empty;

    for (thread_results) |*r| {
        r.mutex.lock();
        const result = r.result;
        const err_msg = r.err_msg;
        r.mutex.unlock();

        if (err_msg) |em| {
            try results.append(allocator, try allocator.dupe(u8, em));
        } else if (result) |res| {
            try results.append(allocator, try allocator.dupe(u8, res));
        } else {
            try results.append(allocator, "<error> unknown result</error>");
        }
    }

    // Free thread result slots
    for (thread_results) |*r| {
        if (r.result) |res| allocator.free(res);
        if (r.err_msg) |err| allocator.free(err);
    }
    allocator.free(thread_results);

    // Format combined results
    var combined_result = std.ArrayList(u8).empty;
    const w = combined_result.writer(allocator);

    for (parsed.sub_agents, 0..) |sub_agent, i| {
        try w.print("<name>{s}</name>\n", .{sub_agent.name});
        try w.print("<result>{s}</result>\n", .{if (i < results.items.len) results.items[i] else ""});
    }

    return try combined_result.toOwnedSlice(allocator);
}

