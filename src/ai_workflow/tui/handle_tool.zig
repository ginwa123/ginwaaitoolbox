const std = @import("std");
const root_mod = @import("nalarcore");
const agent = root_mod.agent;
const logger_mod = root_mod.logger;
const sqlite = root_mod.sqlite;
const config_mod = root_mod.config;
const tool_registry = @import("tool_registry.zig");
const save_message = @import("save_message.zig").save_message;
const on_event_sent = @import("on_event_sent.zig");
const on_event_send_new = on_event_sent.on_event_send_new;
const SaveSkill = @import("save_skill.zig").SaveSkill;
const SaveAgent = @import("save_agent.zig").SaveAgent;
const session_helpers = @import("session_helpers.zig");
const get_current_agent_by_session_id = session_helpers.get_current_agent_by_session_id;
const tool_models = root_mod.tool_models;
const get_messagesLatest = session_helpers.get_message_latest;
const handle_mcp_tool = @import("handle_mcp_tool.zig");

// ============================================================================
// TOOL REGISTRY - Uses unified tool_registry.zig
// ============================================================================

/// Re-export from unified registry for backwards compatibility
pub const TOOL_REGISTRY = tool_registry.MAIN_AGENT_TOOL_REGISTRY;

/// Context passed to all tool handlers
const ToolContext = struct {
    allocator: std.mem.Allocator,
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
            return dispatchFromRegistry(ctx, tool_call, entry);
        }
    }

    // Check if it's an MCP tool (format: mcp_serverName_toolName)
    if (isMCPTool(ctx.config, tool_name)) {
        return dispatchMCP(ctx, tool_call);
    }

    return error.UnknownTool;
}

/// Dispatch tool execution from registry entry
/// Calls entry.exec() directly and handles auto-save via registry flags
fn dispatchFromRegistry(ctx: ToolContext, tool_call: agent.ToolCall, entry: tool_registry.ToolInfo) !ToolResult {
    // Handle special tools that need extended context
    if (std.mem.eql(u8, entry.name, "set_agent_properties")) {
        return dispatchSetAgentProperties(ctx, tool_call);
    }
    if (std.mem.eql(u8, entry.name, "spawn_sub_agent")) {
        return dispatchSpawnSubAgent(ctx, tool_call);
    }

    // Standard tools: call exec directly and wrap result
    const result = try entry.exec(ctx.allocator, tool_call, ctx.db, ctx.session_id);

    var tool_result = MainAgentToolResult{ .output = result };

    // Auto-save skill if enabled in registry
    if (entry.auto_save_skill) {
        if (parseSkillFromResult(result)) |info| {
            tool_result.skill_saved = SkillSaveInfo{ .name = info.name, .content = info.content };
        }
    }

    // Auto-save agent if enabled in registry
    if (entry.auto_save_agent) {
        if (parseAgentFromResult(result)) |name| {
            tool_result.agent_saved = AgentSaveInfo{ .name = name };
        }
    }

    return ToolResult{
        .output = tool_result.output,
        .temperature = tool_result.temperature,
        .is_thinking = tool_result.is_thinking,
        .skill_saved = tool_result.skill_saved,
        .agent_saved = tool_result.agent_saved,
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
    const handle_set_agent_properties = @import("handle_set_agent_properties.zig");
    const result = try handle_set_agent_properties.handle_set_agent_properties_run(ctx.allocator, tool_call);

    return ToolResult{
        .output = result.arguments,
        .temperature = result.temperature,
        .is_thinking = result.is_thinking,
    };
}

/// spawn_sub_agent needs full context (logger, model, etc.)
fn dispatchSpawnSubAgent(ctx: ToolContext, tool_call: agent.ToolCall) !ToolResult {
    const handle_spawn_sub_agent = @import("handle_spawn_sub_agent.zig");
    const result = try handle_spawn_sub_agent.handle_spawn_sub_agent_run(
        ctx.allocator,
        ctx.db,
        ctx.logger,
        ctx.session_id,
        ctx.model,
        ctx.cwd,
        null,
        0,
        tool_call,
        ctx.agent_temperature.*,
        ctx.is_thinking.*,
        ctx.api_key,
        ctx.base_url,
        ctx.config,
    );
    return ToolResult{ .output = result };
}

// ============================================================================
// HELPER FUNCTIONS - XML Parsing
// ============================================================================

fn parseSkillFromResult(result: []const u8) ?struct { name: []const u8, content: []const u8 } {
    if (std.mem.indexOf(u8, result, "<loaded>true</loaded>") == null) return null;

    const name_start = std.mem.indexOf(u8, result, "<skill_name>") orelse return null;
    const name_begin = name_start + "<skill_name>".len;
    const name_end = std.mem.indexOf(u8, result[name_begin..], "</skill_name>") orelse return null;
    const skill_name = result[name_begin..name_begin + name_end];

    const content_start = std.mem.indexOf(u8, result, "<content>") orelse return null;
    const content_begin = content_start + "<content>".len;
    const content_end = std.mem.indexOf(u8, result[content_begin..], "</content>") orelse return null;
    const skill_content = result[content_begin..content_begin + content_end];

    return .{ .name = skill_name, .content = skill_content };
}

fn parseAgentFromResult(result: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, result, "<loaded>true</loaded>") == null) return null;

    const name_start = std.mem.indexOf(u8, result, "<agent_name>") orelse return null;
    const name_begin = name_start + "<agent_name>".len;
    const name_end = std.mem.indexOf(u8, result[name_begin..], "</agent_name>") orelse return null;
    return result[name_begin..name_begin + name_end];
}

// ============================================================================
// MAIN HANDLER - Clean dispatch using registry
// ============================================================================

pub fn handle_tool(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    session_name: ?[]const u8,
    loop_counter: u32,
    res_dynamic_agent: agent.CallResponse,
    agent_temperature: *f32,
    isThinking: *bool,
    api_key: []const u8,
    base_url: []const u8,
    config: *const config_mod.LlmConfig,
    base_tools: []const tool_models.AgentTool,
    messages_list: *std.ArrayList(agent.AgentMessage),
) !void {
    _ = base_tools; // Kept for API compatibility, tool validation is now via registry
    _ = messages_list; // Kept for API compatibility

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

        _ = try save_message(allocator, db, .{
            .session_id = session_id,
            .model = model,
            .cwd = cwd,
            .content = res_dynamic_agent.content,
            .reasoning_content = res_dynamic_agent.reasoning_content,
            .role = agent.Role.assistant.toStr(),
            .finish_reason = if (res_dynamic_agent.finish_reason) |fr| fr.toStr() else null,
            .tool_calls = tc,
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
            .parent_id = session_id,
            .parent_session_id = session_id,
        });

        // Send SSE for assistant message
        try sendSSEForLatestMessage(allocator, db, session_id, cwd, current_agent_for_save, session_id, agent_temperature.*, isThinking.*, true, false);

        // Build context for dispatch
        const ctx = ToolContext{
            .allocator = allocator,
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
                    logger,
                    tool_call,
                    config,
                ) catch |err| {
                    tool_result = try std.fmt.allocPrint(allocator, "<error> MCP tool {s} failed: {s}</error>", .{
                        tool_call.function.name,
                        @errorName(err),
                    });
                    try saveAndSendToolResult(allocator, db, session_id, model, cwd, session_name, loop_counter, tool_call, tool_result, toolAgentTemp, toolIsThinking, current_agent_for_save);
                    continue;
                };
                try saveAndSendToolResult(allocator, db, session_id, model, cwd, session_name, loop_counter, tool_call, tool_result, toolAgentTemp, toolIsThinking, current_agent_for_save);
                continue;
            }

            // Dispatch to the appropriate handler
            const exec_result = dispatchTool(ctx, tool_call) catch |err| {
                tool_result = try std.fmt.allocPrint(allocator, "<error> {s} failed: {s}</error>", .{
                    tool_call.function.name,
                    @errorName(err),
                });
                try saveAndSendToolResult(allocator, db, session_id, model, cwd, session_name, loop_counter, tool_call, tool_result, toolAgentTemp, toolIsThinking, current_agent_for_save);
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

            try saveAndSendToolResult(allocator, db, session_id, model, cwd, session_name, loop_counter, tool_call, tool_result, toolAgentTemp, toolIsThinking, current_agent_for_save);
        }
    }

    logger.debugFmt("Tool calls processing complete, looping back for next API call...", .{}) catch {};
}

fn saveAndSendToolResult(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    session_name: ?[]const u8,
    loop_counter: u32,
    tool_call: agent.ToolCall,
    result: []const u8,
    temperature: f32,
    is_thinking: bool,
    agent_name: []const u8,
) !void {
    _ = try save_message(allocator, db, .{
        .session_id = session_id,
        .model = model,
        .cwd = cwd,
        .content = result,
        .reasoning_content = null,
        .role = agent.Role.tool.toStr(),
        .finish_reason = agent.FinishReason.tool.toStr(),
        .tool_calls = null,
        .tool_call_id = tool_call.id,
        .agent_name = agent_name,
        .session_name = session_name,
        .loop_index = loop_counter,
        .temperature = temperature,
        .is_thinking = is_thinking,
        .prompt_tokens = 0,
        .completion_tokens = 0,
        .total_tokens = 0,
        .is_output = true,
        .is_input = false,
        .tool_name = tool_call.function.name,
        .parent_id = session_id,
        .parent_session_id = session_id,
    });

    try sendSSEForLatestMessage(allocator, db, session_id, cwd, agent_name, session_id, temperature, is_thinking, false, true);
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
    const latestMessage = get_messagesLatest(allocator, db, session_id) catch return;
    if (latestMessage) |msg| {
        on_event_send_new(allocator, .{
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
            .session_name = msg.session_name,
            .loop_index = msg.loop_index,
            .temperature = temperature,
            .is_thinking = is_thinking,
            .is_input = is_input,
            .is_output = is_output,
            .parent_session_id = parent_session_id,
            .parent_id = session_id,
        }) catch {};
    }
}
