const std = @import("std");
const root_mod = @import("nalarcore");
const agent = root_mod.agent;
const logger_mod = root_mod.logger;
const sqlite = root_mod.sqlite;
const config_mod = root_mod.config;
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
// TOOL REGISTRY - Single source of truth for all tool definitions
// ============================================================================

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

// ============================================================================
// TOOL DISPATCH TABLE - Single source of truth (replaces if-else chain)
// ============================================================================

/// Function signature for all tool dispatchers
const ToolDispatcherFn = *const fn (ctx: ToolContext, tool_call: agent.ToolCall) anyerror!ToolResult;

/// Entry in the tool registry
const ToolEntry = struct {
    name: []const u8,
    dispatch: ToolDispatcherFn,
};

/// The canonical tool registry - ONE place to add/remove/modify tools
/// Each entry maps a tool name to its dispatcher function.
/// To add a new tool:
///   1. Add its dispatch wrapper function below
///   2. Add an entry to this array
const TOOL_REGISTRY: []const ToolEntry = &.{
    // Agent control
    .{ .name = "set_agent_properties", .dispatch = dispatchSetAgentProperties },
    .{ .name = "spawn_sub_agent", .dispatch = dispatchSpawnSubAgent },
    .{ .name = "list_agents", .dispatch = dispatchListAgents },
    .{ .name = "get_agent", .dispatch = dispatchGetAgent },

    // Skill management
    .{ .name = "list_skills", .dispatch = dispatchListSkills },
    .{ .name = "get_skill", .dispatch = dispatchGetSkill },
    .{ .name = "remove_skill", .dispatch = dispatchRemoveSkill },

    // File operations
    .{ .name = "bash", .dispatch = dispatchBash },
    .{ .name = "read_file", .dispatch = dispatchReadFile },
    .{ .name = "write_file", .dispatch = dispatchWriteFile },
    .{ .name = "text_replace", .dispatch = dispatchTextReplace },
    .{ .name = "search", .dispatch = dispatchSearch },

    // LSP tools
    .{ .name = "lsp_definition", .dispatch = dispatchLspDefinition },
    .{ .name = "lsp_references", .dispatch = dispatchLspReferences },
    .{ .name = "lsp_workspace_symbol", .dispatch = dispatchLspWorkspaceSymbol },
    .{ .name = "lsp_document_symbol", .dispatch = dispatchLspDocumentSymbol },
    .{ .name = "lsp_hover", .dispatch = dispatchLspHover },
};

/// Lookup a tool by name and execute it
fn dispatchTool(ctx: ToolContext, tool_call: agent.ToolCall) !ToolResult {
    const tool_name = tool_call.function.name;

    // Linear search through registry (17 items = negligible overhead)
    inline for (TOOL_REGISTRY) |entry| {
        if (std.mem.eql(u8, tool_name, entry.name)) {
            return entry.dispatch(ctx, tool_call);
        }
    }

    // Check if it's an MCP tool (format: serverName_toolName)
    if (std.mem.indexOf(u8, tool_name, "_") != null) {
        if (isMCPTool(ctx.config, tool_name)) {
            return dispatchMCP(ctx, tool_call);
        }
    }

    return error.UnknownTool;
}

/// Check if a tool name is an MCP tool (format: serverName_toolName)
fn isMCPTool(config: *const config_mod.LlmConfig, tool_name: []const u8) bool {
    if (config.mcpServers == null) return false;
    const underscore_idx = std.mem.indexOf(u8, tool_name, "_") orelse return false;
    const server_name = tool_name[0..underscore_idx];
    const mcp_servers = switch (config.mcpServers.?) {
        .object => |obj| obj,
        else => return false,
    };
    return mcp_servers.get(server_name) != null;
}

/// Dispatch an MCP tool call
fn dispatchMCP(ctx: ToolContext, tool_call: agent.ToolCall) !ToolResult {
    const result = try handle_mcp_tool.run(
        ctx.allocator,
        ctx.logger,
        tool_call,
        ctx.config,
    );
    // Return success with tool output
    return ToolResult{ .output = result };
}

/// Check if a tool name is registered
pub fn isKnownTool(name: []const u8) bool {
    for (TOOL_REGISTRY) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return true;
    }
    return false;
}

/// Check if a tool name is registered or is an MCP tool
pub fn isKnownToolOrMCP(name: []const u8, config: *const config_mod.LlmConfig) bool {
    if (isKnownTool(name)) return true;
    return isMCPTool(config, name);
}

/// Get all tool names as a slice (for compatibility)
pub fn getToolNames(allocator: std.mem.Allocator) ![]const []const u8 {
    var names = try std.ArrayList([]const u8).init(allocator);
    errdefer names.deinit(allocator);
    for (TOOL_REGISTRY) |entry| {
        try names.append(allocator, entry.name);
    }
    return try names.toOwnedSlice(allocator);
}

// ============================================================================
// TOOL DISPATCHERS - Each calls the appropriate handler module
// ============================================================================

fn dispatchSetAgentProperties(ctx: ToolContext, tool_call: agent.ToolCall) !ToolResult {
    const handle_set_agent_properties = @import("handle_set_agent_properties.zig");
    const result = try handle_set_agent_properties.run(ctx.allocator, tool_call);

    return ToolResult{
        .output = result.arguments,
        .temperature = result.temperature,
        .is_thinking = result.is_thinking,
    };
}

fn dispatchBash(ctx: ToolContext, tool_call: agent.ToolCall) !ToolResult {
    const handle_bash_tool = @import("handle_bash_tool.zig");
    const result = try handle_bash_tool.runWithContext(ctx.allocator, tool_call, ctx.db, ctx.session_id);
    return ToolResult{ .output = result };
}

fn dispatchReadFile(ctx: ToolContext, tool_call: agent.ToolCall) !ToolResult {
    const handle_read_file_tool = @import("handle_read_file_tool.zig");
    const result = try handle_read_file_tool.run(ctx.allocator, tool_call);
    return ToolResult{ .output = result };
}

fn dispatchSearch(ctx: ToolContext, tool_call: agent.ToolCall) !ToolResult {
    const handle_search_tool = @import("handle_search_tool.zig");
    const result = try handle_search_tool.run(ctx.allocator, tool_call);
    return ToolResult{ .output = result };
}

fn dispatchWriteFile(ctx: ToolContext, tool_call: agent.ToolCall) !ToolResult {
    const handle_write_file_tool = @import("handle_write_file_tool.zig");
    const result = try handle_write_file_tool.run(ctx.allocator, tool_call);
    return ToolResult{ .output = result };
}

fn dispatchTextReplace(ctx: ToolContext, tool_call: agent.ToolCall) !ToolResult {
    const handle_text_replace_tool = @import("handle_text_replace_tool.zig");
    const result = try handle_text_replace_tool.run(ctx.allocator, tool_call);
    return ToolResult{ .output = result };
}

fn dispatchListSkills(ctx: ToolContext, tool_call: agent.ToolCall) !ToolResult {
    _ = tool_call;
    const handle_list_skills_tool = @import("handle_list_skills_tool.zig");
    const result = handle_list_skills_tool.run(ctx.allocator);
    return ToolResult{ .output = result };
}

fn dispatchGetSkill(ctx: ToolContext, tool_call: agent.ToolCall) !ToolResult {
    const handle_get_skill_tool = @import("handle_get_skill_tool.zig");
    const result = try handle_get_skill_tool.run(ctx.allocator, tool_call);

    var skill_save: ?SkillSaveInfo = null;
    if (parseSkillFromResult(result)) |info| {
        skill_save = SkillSaveInfo{ .name = info.name, .content = info.content };
    }

    return ToolResult{
        .output = result,
        .skill_saved = skill_save,
    };
}

fn dispatchRemoveSkill(ctx: ToolContext, tool_call: agent.ToolCall) !ToolResult {
    const handle_remove_skill_tool = @import("handle_remove_skill_tool.zig");
    const result = try handle_remove_skill_tool.run(ctx.allocator, tool_call);
    return ToolResult{ .output = result };
}

fn dispatchSpawnSubAgent(ctx: ToolContext, tool_call: agent.ToolCall) !ToolResult {
    const handle_spawn_sub_agent = @import("handle_spawn_sub_agent.zig");
    const result = try handle_spawn_sub_agent.run(
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

fn dispatchListAgents(ctx: ToolContext, tool_call: agent.ToolCall) !ToolResult {
    _ = tool_call;
    const handle_list_agents_tool = @import("handle_list_agents_tool.zig");
    const result = try handle_list_agents_tool.run(ctx.allocator);
    return ToolResult{ .output = result };
}

fn dispatchGetAgent(ctx: ToolContext, tool_call: agent.ToolCall) !ToolResult {
    const handle_get_agent_tool = @import("handle_get_agent_tool.zig");
    const result = try handle_get_agent_tool.run(ctx.allocator, tool_call);

    var agent_save: ?AgentSaveInfo = null;
    if (parseAgentFromResult(result)) |name| {
        agent_save = AgentSaveInfo{ .name = name };
    }

    return ToolResult{
        .output = result,
        .agent_saved = agent_save,
    };
}

fn dispatchLspDefinition(ctx: ToolContext, tool_call: agent.ToolCall) !ToolResult {
    const handle_lsp_definition_tool = @import("handle_lsp_definition_tool.zig");
    const result = try handle_lsp_definition_tool.run(ctx.allocator, tool_call);
    return ToolResult{ .output = result };
}

fn dispatchLspReferences(ctx: ToolContext, tool_call: agent.ToolCall) !ToolResult {
    const handle_lsp_references_tool = @import("handle_lsp_references_tool.zig");
    const result = try handle_lsp_references_tool.run(ctx.allocator, tool_call);
    return ToolResult{ .output = result };
}

fn dispatchLspWorkspaceSymbol(ctx: ToolContext, tool_call: agent.ToolCall) !ToolResult {
    const handle_lsp_workspace_symbol_tool = @import("handle_lsp_workspace_symbol_tool.zig");
    const result = try handle_lsp_workspace_symbol_tool.run(ctx.allocator, tool_call);
    return ToolResult{ .output = result };
}

fn dispatchLspDocumentSymbol(ctx: ToolContext, tool_call: agent.ToolCall) !ToolResult {
    const handle_lsp_document_symbol_tool = @import("handle_lsp_document_symbol_tool.zig");
    const result = try handle_lsp_document_symbol_tool.run(ctx.allocator, tool_call);
    return ToolResult{ .output = result };
}

fn dispatchLspHover(ctx: ToolContext, tool_call: agent.ToolCall) !ToolResult {
    const handle_lsp_hover_tool = @import("handle_lsp_hover_tool.zig");
    const result = try handle_lsp_hover_tool.run(ctx.allocator, tool_call);
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
            return;
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
                tool_result = handle_mcp_tool.run(
                    allocator,
                    logger,
                    tool_call,
                    config,
                ) catch |err| {
                    tool_result = try std.fmt.allocPrint(allocator, "ERROR: MCP tool {s} failed: {s}", .{
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
                tool_result = try std.fmt.allocPrint(allocator, "ERROR: {s} failed: {s}", .{
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

test {
    _ = @import("handle_tool_test.zig");
}
