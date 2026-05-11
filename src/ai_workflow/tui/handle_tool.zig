const std = @import("std");
const nalar = @import("nalarcore");
const agent = nalar.agent;
const logger_mod = nalar.logger;
const sqlite = nalar.sqlite;
const config_mod = nalar.config;
const tool_registry = @import("tool_registry.zig");
const SubAgentToolExec = tool_registry.SubAgentToolExec;
const llm_history = @import("llm_history.zig");
const on_event_sent = @import("on_event_sent.zig");
const onEventSend = on_event_sent.onEventSend;
const SaveSkill = @import("session_skills.zig").SaveSkill;
const SaveAgent = @import("save_agent.zig").SaveAgent;
const session_helpers = llm_history;
const get_current_agent_by_session_id = llm_history.get_current_agent_by_session_id;
const tool_models = nalar.tool_models;
const getLatestMessage = llm_history.getLatestMessage;
const handle_mcp_tool = @import("handle_mcp_tool.zig");

// ============================================================================
// TOOL REGISTRY - Uses unified tool_registry.zig
// ============================================================================

/// Re-export from unified registry for backwards compatibility
pub const TOOL_REGISTRY = tool_registry.MAIN_AGENT_TOOL_REGISTRY;

/// Context passed to all tool handlers
const ToolContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    api_key: []const u8,
    base_url: []const u8,
    config: *const config_mod.LlmConfig,
    agent_temperature: *f32,
    is_thinking: *bool,
    environment: ?*const std.process.Environ.Map,
};

/// Result of executing a tool
const ToolResult = struct {
    output: []const u8,
    temperature: ?f32 = null,
    is_thinking: ?bool = null,
    skill_saved: ?SkillSaveInfo = null,
    agent_saved: ?AgentSaveInfo = null,
};

const SkillSaveInfo = struct {
    name: []const u8,
    content: []const u8,
};

const AgentSaveInfo = struct {
    name: []const u8,
};

/// Extended result type for main agent tool execution
/// Includes optional temperature/is_thinking for set_agent_properties
const MainAgentToolResult = struct {
    output: []const u8,
    temperature: ?f32 = null,
    is_thinking: ?bool = null,
    skill_saved: ?SkillSaveInfo = null,
    agent_saved: ?AgentSaveInfo = null,
};

/// Lookup a tool by name and execute it using unified registry
/// Refactored: Uses entry.exec() directly instead of double lookup
fn dispatchTool(ctx: ToolContext, tool_call: agent.ToolCall) !ToolResult {
    const tool_name = tool_call.function.name;

    inline for (tool_registry.MAIN_AGENT_TOOL_REGISTRY) |entry| {
        if (std.mem.eql(u8, tool_name, entry.name)) {
            return dispatchFromRegistry(ctx, tool_call, entry.exec);
        }
    }

    // Check if it's an MCP tool (format: mcp_serverName_toolName)
    if (isMCPTool(ctx.config, tool_name)) {
        return dispatchMCP(ctx, tool_call);
    }

    return error.UnknownTool;
}

/// Dispatch tool execution from registry entry
/// Calls exec directly and handles auto-save via registry flags
fn dispatchFromRegistry(ctx: ToolContext, tool_call: agent.ToolCall, exec: SubAgentToolExec) !ToolResult {
    std.debug.print("DEBUG dispatchFromRegistry: tool='{s}', args_len={}\n", .{ tool_call.function.name, tool_call.function.arguments.len });
    if (std.mem.eql(u8, tool_call.function.name, "spawn_sub_agent")) {
        std.debug.print("DEBUG: spawn_sub_agent detected!\n", .{});
    }
    // Standard tools: call exec directly and wrap result
    const ctx_local = tool_registry.ToolExecContext{
        .allocator = ctx.allocator,
        .io = ctx.io,
        .db = ctx.db,
        .logger = ctx.logger,
        .session_id = ctx.session_id,
        .model = ctx.model,
        .cwd = ctx.cwd,
        .api_key = ctx.api_key,
        .base_url = ctx.base_url,
        .config = ctx.config,
        .agent_temperature = ctx.agent_temperature,
        .is_thinking = ctx.is_thinking,
        .environment = ctx.environment,
    };
    const exec_result = try exec(ctx_local, tool_call);

    return ToolResult{
        .output = exec_result.output,
        .temperature = exec_result.temperature,
        .is_thinking = exec_result.is_thinking,
        .skill_saved = if (exec_result.skill_save) |sk| SkillSaveInfo{ .name = sk.name, .content = sk.content } else null,
        .agent_saved = if (exec_result.agent_save) |ag| AgentSaveInfo{ .name = ag.name } else null,
    };
}

/// Check if a tool name is an MCP tool (format: mcp_serverName_toolName)
fn isMCPTool(config: *const config_mod.LlmConfig, tool_name: []const u8) bool {
    if (config.mcpServers == null) return false;

    // MCP tool names have format: mcp_{serverName}_{toolName}
    // e.g., mcp_context7_query-docs
    if (!std.mem.startsWith(u8, tool_name, "mcp_")) return false;

    // Find second underscore (after "mcp_") to get server name
    const after_mcp = tool_name["mcp_".len..];
    const underscore_idx = std.mem.indexOf(u8, after_mcp, "_") orelse return false;
    const server_name = after_mcp[0..underscore_idx];

    const mcp_servers = switch (config.mcpServers.?) {
        .object => |obj| obj,
        else => return false,
    };
    return mcp_servers.get(server_name) != null;
}

/// Dispatch an MCP tool call
fn dispatchMCP(ctx: ToolContext, tool_call: agent.ToolCall) !ToolResult {
    const result = try handle_mcp_tool.handle_mcp_tool_run(
        ctx.allocator,
        ctx.io,
        ctx.logger,
        tool_call,
        ctx.config,
    );
    // Return success with tool output
    return ToolResult{ .output = result };
}

/// Check if a tool name is registered (uses unified registry)
pub fn isKnownTool(name: []const u8) bool {
    return tool_registry.isKnownTool(name);
}

/// Check if a tool name is registered or is an MCP tool
pub fn isKnownToolOrMCP(name: []const u8, config: *const config_mod.LlmConfig) bool {
    if (isKnownTool(name)) return true;
    return isMCPTool(config, name);
}

/// Get all tool names as a slice
pub fn getToolNames() []const []const u8 {
    return tool_registry.getToolNames();
}

// ============================================================================
// SPECIAL TOOL DISPATCHERS - Tools that need extended context
// ============================================================================

/// set_agent_properties returns temperature/is_thinking changes
fn dispatchSetAgentProperties(ctx: ToolContext, tool_call: agent.ToolCall) !ToolResult {
    const tool_registry_mod = @import("tool_registry.zig");
    const ctx_exec = tool_registry_mod.ToolExecContext{
        .allocator = ctx.allocator,
        .io = ctx.io,
        .db = ctx.db,
        .logger = ctx.logger,
        .session_id = ctx.session_id,
        .model = ctx.model,
        .cwd = ctx.cwd,
        .api_key = ctx.api_key,
        .base_url = ctx.base_url,
        .config = ctx.config,
        .agent_temperature = ctx.agent_temperature,
        .is_thinking = ctx.is_thinking,
        .environment = ctx.environment,
    };
    const result = try tool_registry_mod.execSetAgentProperties(ctx_exec, tool_call);

    return ToolResult{
        .output = result.output,
        .temperature = result.temperature,
        .is_thinking = result.is_thinking,
    };
}

// ============================================================================
// HELPER FUNCTIONS - XML Parsing
// ============================================================================

fn parseSkillFromResult(result: []const u8) ?struct { name: []const u8, content: []const u8 } {
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

fn parseAgentFromResult(result: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, result, "<loaded>true</loaded>") == null) return null;

    const name_start = std.mem.indexOf(u8, result, "<agent_name>") orelse return null;
    const name_begin = name_start + "<agent_name>".len;
    const name_end = std.mem.indexOf(u8, result[name_begin..], "</agent_name>") orelse return null;
    return result[name_begin .. name_begin + name_end];
}

// ============================================================================
// MAIN HANDLER - Clean dispatch using registry
// ============================================================================

pub fn handle_tool(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,
    session_id: []const u8,
    parent_session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    loop_counter: u32,
    res_dynamic_agent: agent.CallResponse,
    agent_temperature: *f32,
    isThinking: *bool,
    api_key: []const u8,
    base_url: []const u8,
    config: *const config_mod.LlmConfig,
    environment: ?*const std.process.Environ.Map,
) !void {

    if (res_dynamic_agent.tool_calls) |tc| {
        // Check if any tools match registered tools or MCP tools
        var has_known_tools = false;
        for (tc) |tool_call| {
            if (isKnownToolOrMCP(tool_call.function.name, config)) {
                has_known_tools = true;
                break;
            }
        }
        if (!has_known_tools) {
            logger.infoFmt("[HANDLE_TOOL] Skipping saving assistant message, no tools matched", .{}) catch {};
        }

        // Build tool names list and save assistant message
        var toolNames = try std.ArrayList([]const u8).initCapacity(allocator, tc.len);
        defer toolNames.deinit(allocator);
        for (tc) |tc_| {
            _ = try toolNames.append(allocator, tc_.function.name);
        }

        const current_agent_state = try get_current_agent_by_session_id(allocator, db, session_id);
        const current_agent_for_save = current_agent_state.agent;

        _ = try llm_history.saveMessage(allocator, io, db, .{
            .session_id = session_id,
            .model = model,
            .cwd = cwd,
            .content = res_dynamic_agent.content,
            .reasoning_content = res_dynamic_agent.reasoning_content,
            .role = agent.Role.assistant.to_str(),
            .finish_reason = if (res_dynamic_agent.finish_reason) |fr| fr.to_str() else null,
            .tool_calls = tc,
            .tool_call_id = null,
            .agent_name = current_agent_for_save,
            .loop_index = loop_counter,
            .temperature = agent_temperature.*,
            .is_thinking = isThinking.*,
            .prompt_tokens = res_dynamic_agent.usage.prompt_tokens,
            .completion_tokens = res_dynamic_agent.usage.completion_tokens,
            .total_tokens = res_dynamic_agent.usage.total_tokens,
            .is_input = true,
            .is_output = false,
            .tool_name = try std.mem.join(allocator, ",", toolNames.items),
            .parent_id = parent_session_id,
            .parent_session_id = parent_session_id,
        });

        // Send SSE for assistant message
        try sendSSEForLatestMessage(allocator, db, session_id, cwd, current_agent_for_save, parent_session_id, agent_temperature.*, isThinking.*, true, false);

        // Build context for dispatch
        const ctx = ToolContext{
            .allocator = allocator,
            .io = io,
            .db = db,
            .logger = logger,
            .session_id = session_id,
            .model = model,
            .cwd = cwd,
            .api_key = api_key,
            .base_url = base_url,
            .config = config,
            .agent_temperature = agent_temperature,
            .is_thinking = isThinking,
            .environment = environment,
        };

        // Execute each tool call using dispatch
        for (tc) |tool_call| {
            var tool_result: []const u8 = undefined;
            var toolAgentTemp: f32 = agent_temperature.*;
            var toolIsThinking: bool = isThinking.*;

            // Check if this is an MCP tool
            if (isMCPTool(config, tool_call.function.name)) {
                // Call MCP handler
                tool_result = handle_mcp_tool.handle_mcp_tool_run(
                    allocator,
                    io,
                    logger,
                    tool_call,
                    config,
                ) catch |err| {
                    tool_result = try std.fmt.allocPrint(allocator, "<error> MCP tool {s} failed: {s}</error>", .{
                        tool_call.function.name,
                        @errorName(err),
                    });
                    try saveAndSendToolResult(allocator, io, db, session_id, parent_session_id, model, cwd, loop_counter, tool_call, tool_result, toolAgentTemp, toolIsThinking, current_agent_for_save);
                    continue;
                };
                try saveAndSendToolResult(allocator, io, db, session_id, parent_session_id, model, cwd, loop_counter, tool_call, tool_result, toolAgentTemp, toolIsThinking, current_agent_for_save);
                continue;
            }

            // Dispatch to the appropriate handler
            const exec_result = dispatchTool(ctx, tool_call) catch |err| {
                std.debug.print("DEBUG: dispatchTool failed with error: {s}\n", .{@errorName(err)});
                tool_result = try std.fmt.allocPrint(allocator, "<error> {s} failed: {s}</error>", .{
                    tool_call.function.name,
                    @errorName(err),
                });
                try saveAndSendToolResult(allocator, io, db, session_id, parent_session_id, model, cwd, loop_counter, tool_call, tool_result, toolAgentTemp, toolIsThinking, current_agent_for_save);
                continue;
            };

            tool_result = exec_result.output;

            // Apply property changes from tool execution
            if (exec_result.temperature) |temp| toolAgentTemp = temp;
            if (exec_result.is_thinking) |think| toolIsThinking = think;

            // Auto-save skill if loaded
            if (exec_result.skill_saved) |skill_info| {
                SaveSkill(allocator, db, logger, session_id, skill_info.name, skill_info.content) catch |err| {
                    logger.errFmt("Failed to save skill '{s}': {s}", .{ skill_info.name, @errorName(err) }) catch {};
                };
            }

            // Auto-save agent if loaded
            if (exec_result.agent_saved) |agent_info| {
                SaveAgent(allocator, db, logger, session_id, agent_info.name) catch |err| {
                    logger.errFmt("Failed to save agent '{s}': {s}", .{ agent_info.name, @errorName(err) }) catch {};
                };
            }

            try saveAndSendToolResult(allocator, io, db, session_id, parent_session_id, model, cwd, loop_counter, tool_call, tool_result, toolAgentTemp, toolIsThinking, current_agent_for_save);
        }
    }

    logger.debugFmt("Tool calls processing complete, looping back for next API call...", .{}) catch {};
}

fn saveAndSendToolResult(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    parent_session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    loop_counter: u32,
    tool_call: agent.ToolCall,
    result: []const u8,
    temperature: f32,
    is_thinking: bool,
    agent_name: []const u8,
) !void {
    _ = try llm_history.saveMessage(allocator, io, db, .{
        .session_id = session_id,
        .model = model,
        .cwd = cwd,
        .content = result,
        .reasoning_content = null,
        .role = agent.Role.tool.to_str(),
        .finish_reason = agent.FinishReason.tool.to_str(),
        .tool_calls = null,
        .tool_call_id = tool_call.id,
        .agent_name = agent_name,
        .loop_index = loop_counter,
        .temperature = temperature,
        .is_thinking = is_thinking,
        .prompt_tokens = 0,
        .completion_tokens = 0,
        .total_tokens = 0,
        .is_output = true,
        .is_input = false,
        .tool_name = tool_call.function.name,
        .parent_id = parent_session_id,
        .parent_session_id = parent_session_id,
    });

    try sendSSEForLatestMessage(allocator, db, session_id, cwd, agent_name, parent_session_id, temperature, is_thinking, false, true);
}

fn sendSSEForLatestMessage(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    cwd: []const u8,
    agent_name: []const u8,
    parent_session_id: []const u8,
    temperature: f32,
    is_thinking: bool,
    is_input: bool,
    is_output: bool,
) !void {
    const latestMessage = getLatestMessage(allocator, db, session_id) catch |err| {
        std.debug.print("SSE_DEBUG: getLatestMessage failed for session {s}: {s}\n", .{ session_id, @errorName(err) });
        return;
    };
    if (latestMessage) |msg| {
        std.debug.print("SSE_DEBUG: sending SSE for session {s}, content='{s}'\n", .{ session_id, if (msg.response_content.len > 50) msg.response_content[0..50] else msg.response_content });
        onEventSend(allocator, .{
            .session_id = msg.session_id,
            .model = msg.model,
            .cwd = cwd,
            .content = msg.response_content,
            .reasoning_content = msg.reasoning_content,
            .role = msg.role,
            .finish_reason = msg.finish_reason,
            .tool_calls = null,
            .tool_call_id = msg.id,
            .tool_name = msg.tool_name,
            .agent_name = agent_name,
            .loop_index = msg.loop_index,
            .temperature = temperature,
            .is_thinking = is_thinking,
            .is_input = is_input,
            .is_output = is_output,
            .parent_session_id = parent_session_id,
            .parent_id = session_id,
        }) catch |err| {
            std.debug.print("SSE_DEBUG: on_event_send_new failed for session {s}: {s}\n", .{ session_id, @errorName(err) });
        };
    } else {
        std.debug.print("SSE_DEBUG: no latest message found for session {s}\n", .{session_id});
    }
}
