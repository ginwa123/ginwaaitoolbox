const std = @import("std");
const json = std.json;
const nalarcore = @import("nalarcore");
const agent = nalarcore.agent;
const llm_history = @import("llm_history.zig");
const session_helpers = llm_history;
const sqlite = nalarcore.sqlite;
const prompt = nalarcore.prompt;
const TUIHistory = @import("models.zig").TUIHistory;
const tool_models = nalarcore.tool_models;
const config_mod = nalarcore.config;
const custom_http_client = @import("custom_http_client");
const background_process = @import("background_process.zig");
const ProcessInfo = background_process.ProcessInfo;
const inherited_context = @import("inherited_context.zig");
const kanban_model = @import("kanban_model.zig");
const design_model = @import("design_model.zig");
const buildDesignCanvasPrompt = @import("prompts_make_design_context.zig").buildDesignCanvasPrompt;

const AgentTool = tool_models.AgentTool;
const AgentToolFunction = tool_models.AgentToolFunction;
const ToolParameters = tool_models.ToolParameters;
const ToolProperty = tool_models.ToolProperty;
const agentic_loop = @import("workflow.zig");

const bash_tool_mod = nalarcore.bash_tool;
const read_file_mod = nalarcore.read_file;
const text_replace_mod = nalarcore.text_replace_tool;
const write_file_mod = nalarcore.write_file;
const list_skills_mod = nalarcore.list_skills_tool;
const memories_mod = nalarcore.memories;
const list_memory_mod = nalarcore.list_memory_tool;
const search_history_mod = nalarcore.search_history_tool;
const get_skill_mod = nalarcore.get_skill_tool;
const view_skill_mod = nalarcore.view_skill_tool;
const remove_skill_mod = nalarcore.remove_skill_tool;
const list_agents_mod = nalarcore.list_agents;
const add_skill_mod = nalarcore.add_skill;
const edit_skill_mod = nalarcore.edit_skill;
const set_git_worktree_mod = nalarcore.set_git_worktree;
const kanban_list_mod = nalarcore.kanban_list;
const kanban_move_task_mod = nalarcore.kanban_move_task;
const kanban_create_task_tool = nalarcore.create_kanban_task;
const set_design_page_mod = nalarcore.set_design_page;
const add_design_element_mod = nalarcore.add_design_element;
const update_design_element_mod = nalarcore.update_design_element;
const group_design_elements_mod = nalarcore.group_design_elements;
const set_element_parent_mod = nalarcore.set_element_parent;
const move_design_element_mod = nalarcore.move_design_element;
const move_element_to_page_mod = nalarcore.move_element_to_page;
const show_preview_mod = nalarcore.ai_mod.show_preview;
const remove_agent_mod = nalarcore.remove_agent;
const remove_file_mod = nalarcore.remove_file;
const change_agent_mod = nalarcore.change_agent;
const lsp_definition_mod = nalarcore.tools.lsp_definition;
const lsp_references_mod = nalarcore.tools.lsp_references;
const lsp_workspace_symbol_mod = nalarcore.tools.lsp_workspace_symbol;
const lsp_document_symbol_mod = nalarcore.tools.lsp_document_symbol;
const lsp_hover_mod = nalarcore.tools.lsp_hover;
const set_agent_properties_mod = nalarcore.set_agent_properties;
const web_search_mod = nalarcore.web_search;
const nalar_browser_mod = nalarcore.nalar_browser;
const update_activity_mod = nalarcore.update_activity;
const glob_tool_mod = nalarcore.glob_tool;
const search_tool_mod = nalarcore.search_tool;
const semantic_search_mod = nalarcore.semantic_search;
const spawn_sub_agent_tool = nalarcore.spawn_sub_agent;


pub fn buildMessages(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    cwd: []const u8,
    session_id: []const u8,
    parent_session_id: []const u8,
    historyMessages: []agentic_loop.LLMHistory,
    tools: []tool_models.AgentTool,
    inherited_context_mode: []const u8,
    activeAgentContent: []const u8,
) ![]agent.AgentMessage {
    // Build content strings internally
    const skills = try agentic_loop.prompts_mod.makeSkillsEquippedContext(allocator, db, session_id);
    defer allocator.free(skills);

    const memoryMd = try agentic_loop.prompts_mod.makeWorkingDirectoryContext(allocator, io, cwd);
    defer allocator.free(memoryMd);

    // const backgroundProcessmessage = try BuildBackgroundProcessPrompt(allocator, db, session_id);
    // defer allocator.free(backgroundProcessmessage);

    // If the caller supplied an explicit `activeAgentContent`
    // (sub-agent flow with a config-driven system_prompt), use it
    // verbatim and skip the `session_agents` lookup. Otherwise fall
    // back to `BuildDynamicAgentContent(db, session_id)` which is
    // the main-agent flow's source of truth.
    const caller_supplied_active = activeAgentContent.len > 0;
    const agentUsed = if (caller_supplied_active)
        try allocator.dupe(u8, activeAgentContent)
    else
        try BuildDynamicAgentContent(allocator, db, session_id);
    defer allocator.free(agentUsed);

    // disable dynamic system prompt for cache call llm
    // buildAgentPrompt now handles processMessages internally
    // const activity_info = try agentic_loop.prompts_mod.makeActivityInfo(allocator, io, db, session_id);
    // defer allocator.free(activity_info);
    const activity_info = "";

    // Resolve environment for the Global Knowledge loader. The singleton
    // is the single source of truth for the process-level environment map.
    const di = try nalarcore.getSingleton();
    const environment = di.environment;

    // Build the "Available Sub-Agents" listing from the current
    // session's `selected_profile_model` + the LlmConfig. Renders
    // an empty string when no sub-agents are configured (or when
    // the session is missing), so the section is naturally
    // omitted. See `prompt.appendSubAgentsListing` for the format.
    const sub_agents_listing = try BuildSubAgentsListing(allocator, db, session_id);
    defer allocator.free(sub_agents_listing);

    // Build the "Workspace Context" section listing the workspace items
    // and tasks in the same workspace as the current task. Returns `""`
    // when the session is not bound to any workspace_item_task (caller
    // omits the section silently — matches `appendSkillsListing` behavior).
    const workspaceContext = try agentic_loop.prompts_mod.makeWorkspaceContext(allocator, db, session_id);
    defer allocator.free(workspaceContext);

    // Agent Mode (plan 2026-08-15-agent-mode, task_1786962724740_0):
    // Build the "## Agent Knowledge" section. Reads the agent's
    // markdown knowledge files from disk. Empty for non-agent sessions
    // (helper silently returns "").
    const agentKnowledgeContent = try agentic_loop.prompts_mod.makeAgentKnowledge(allocator, io, db, session_id);
    defer allocator.free(agentKnowledgeContent);

    // Build the "Kanban Status Tracking" section. Only rendered when
    // the session's parent item has item_type === 'kanban' (the
    // helper silently returns "" otherwise). Rendered right after
    // the Workspace Context section so the agent sees the workflow
    // expectations before the tool listing. Pass `tools` so the
    // helper can append the optional "Follow-up Tasks" hint when
    // the create_kanban_task tool is equipped.

    const filtered_tools = try filteringTools(allocator, db, session_id, tools);

    const kanbanStatusContent = try agentic_loop.prompts_mod.makeKanbanContext(allocator, db, session_id, filtered_tools);
    defer allocator.free(kanbanStatusContent);

    // Build the "Design Canvas" status section (v6 — 3 LLM tools).
    // Only rendered when the session's parent item has
    // item_type === 'design' (the helper silently returns "" otherwise).
    // Mirrors the Kanban pattern above — same graceful-skip on
    // errors, same render-after-workspace-context ordering.
    const designStatusContent = try buildDesignCanvasPrompt(allocator, db, session_id);
    defer allocator.free(designStatusContent);

    const systemContent = try prompt.build_agent_prompt(allocator, io, cwd, skills, memoryMd, "", agentUsed, filtered_tools, activity_info, environment, sub_agents_listing, workspaceContext, kanbanStatusContent, designStatusContent);

    // Render inherited parent conversation history (if requested) and append
    // it to the system prompt as a labelled, read-only block. The formatter
    // itself detects whether this session is a sub-agent (session_id !=
    // parent_session_id); if the two are equal (or either is empty), it
    // short-circuits to "" without hitting the DB.
    const inherited_md = inherited_context.formatHistory(
        allocator,
        db,
        session_id, // the current agent's session_id (vs. parent's)
        parent_session_id, // the parent's session_id, NOT the sub-agent's
        inherited_context.parseMode(inherited_context_mode) catch .none,
    ) catch blk: {
        std.log.warn("buildMessages: failed to render inherited_context: mode={s}", .{inherited_context_mode});
        break :blk try allocator.dupe(u8, "");
    };
    defer allocator.free(inherited_md);

    // Build the "## Current Plan" section. Reads session_plan for the
    // current session_id. Returns "" when no plan exists (silently omitted).
    // Mirrors the kanban/design pattern (graceful-skip on empty, render
    // between context sections and the inherited context block).
    const planContent = try agentic_loop.prompts_mod.makePlanContext(allocator, db, session_id);
    defer allocator.free(planContent);

    var final_system: std.ArrayList(u8) = .empty;
    defer final_system.deinit(allocator);
    try final_system.appendSlice(allocator, systemContent);
    // Agent Mode: inject the '## Agent Knowledge' section right
    // after the workspace-context section emitted by build_agent_prompt.
    // Empty when item_type != 'agent' OR agent has no knowledge rows.
    if (agentKnowledgeContent.len > 0) {
        try final_system.appendSlice(allocator, agentKnowledgeContent);
    }
    if (inherited_md.len > 0) {
        try final_system.appendSlice(allocator, "\n\n");
        try final_system.appendSlice(allocator, inherited_md);
    }
    if (planContent.len > 0) {
        try final_system.appendSlice(allocator, "\n\n");
        try final_system.appendSlice(allocator, planContent);
    }
    const final_system_content = try final_system.toOwnedSlice(allocator);

    const systemMessage = agent.AgentMessage{
        .role = .system,
        .content = final_system_content,
    };

    std.debug.print("DEBUG_BUILD: systemContent size={d} bytes\n", .{final_system_content.len});

    var allMessages: std.ArrayList(agent.AgentMessage) = .empty;

    try allMessages.append(allocator, systemMessage);
    for (historyMessages) |hist| {
        const agentMsgs = try agentic_loop.parsing_mod.transformLLMHistoryToAgentMessage(allocator, hist);
        for (agentMsgs) |msg| {
            try allMessages.append(allocator, msg);
        }
    }

    return try allMessages.toOwnedSlice(allocator);
}

/// Build activity info string for the agent prompt
/// Uses worker table as the SOLE source of active workers info
/// Filters out current session to avoid self-reference
fn buildActivityInfo(allocator: std.mem.Allocator, io: std.Io, db: *sqlite.SqliteBackend, current_session_id: []const u8) ![]const u8 {
    const workers = try llm_history.getActiveWorker(allocator, db);
    defer {
        for (workers) |*worker| worker.deinit(allocator);
        allocator.free(workers);
    }

    // Filter out current session and count remaining
    var filtered = std.ArrayList(llm_history.WorkerInfo).empty;
    defer filtered.deinit(allocator);
    for (workers) |worker| {
        if (!std.mem.eql(u8, worker.session_id, current_session_id)) {
            try filtered.append(allocator, worker);
        }
    }
    if (filtered.items.len == 0) {
        return try allocator.dupe(u8, "");
    }

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, "The following workers are currently active:\n\n");

    for (filtered.items) |worker| {
        try result.appendSlice(allocator, "- **");
        try result.appendSlice(allocator, worker.session_id);
        try result.appendSlice(allocator, "**");
        if (worker.working_directory.len > 0) {
            try result.appendSlice(allocator, " @ ");
            try result.appendSlice(allocator, worker.working_directory);
        }

        if (worker.git_worktree_cwd.len > 0) {
            try result.appendSlice(allocator, " (git worktree: ");
            try result.appendSlice(allocator, worker.git_worktree_cwd);
            try result.appendSlice(allocator, ")");
        }

        if (worker.last_activity > 0) {
            const now: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
            const diff_secs = now - worker.last_activity;
            try result.appendSlice(allocator, " | last activity: ");
            try result.appendSlice(allocator, formatRelativeTime(diff_secs));
            if (worker.last_activity_description.len > 0) {
                try result.appendSlice(allocator, " (");
                try result.appendSlice(allocator, worker.last_activity_description);
                try result.appendSlice(allocator, ")");
            }
        }
        try result.appendSlice(allocator, "\n");
    }

    return try result.toOwnedSlice(allocator);
}

/// Format seconds into human-readable relative time
pub fn formatRelativeTime(seconds: i64) []const u8 {
    if (seconds < 60) {
        return "< 1m";
    } else if (seconds < 3600) {
        const mins = @divTrunc(seconds, 60);
        return if (mins == 1) "1m" else if (mins < 5) "2m" else "5m";
    } else if (seconds < 86400) {
        const hours = @divTrunc(seconds, 3600);
        return if (hours == 1) "1h" else if (hours < 12) "5h" else "12h+";
    } else {
        return "> 24h";
    }
}

/// Strip SSE "data:" prefix from response body if present
/// MCP servers may return responses in SSE format: "data: {...}\n\n"
fn stripSsePrefix(body: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "data:")) {
        const json_start = trimmed["data:".len..];
        const json_trimmed = std.mem.trim(u8, json_start, " \t");
        return json_trimmed;
    }
    return null;
}

/// Error types for MCP tool fetching
pub const McpToolError = error{
    ConfigLoadError,
    HttpRequestError,
    JsonParseError,
    InvalidResponse,
    OutOfMemory,
};

/// Header struct for MCP requests
const McpHeader = struct {
    key: []const u8,
    value: []const u8,
};

/// MCP Tool response from server
const McpToolResponse = struct {
    name: []const u8,
    description: []const u8,
    inputSchema: InputSchema,
};

const InputSchema = struct {
    type: []const u8,
    properties: json.Value,
    required: ?[]const []const u8 = null,
};

/// List tools response
const ListToolsResult = struct {
    tools: []const McpToolResponse,
};

/// Fetch MCP tools from all configured servers
pub fn buildMCPToolsRun(allocator: std.mem.Allocator, mcpServers: std.json.Value) !?[]tool_models.AgentTool {
    // Check if mcpServers is configured
    const mcp_servers = switch (mcpServers) {
        .object => |obj| obj,
        else => return null,
    };

    var all_tools: std.ArrayList(AgentTool) = .empty;
    defer all_tools.deinit(allocator);

    // Iterate over each MCP server
    var server_iter = mcp_servers.iterator();
    while (server_iter.next()) |entry| {
        const server_name = entry.key_ptr.*;
        const server_config = entry.value_ptr.*;

        const server_obj = switch (server_config) {
            .object => |obj| obj,
            else => continue,
        };

        // Get URL
        const url_value = server_obj.get("url") orelse continue;
        const url = url_value.string;

        // Build headers
        var headers: std.ArrayList(McpHeader) = .empty;
        defer headers.deinit(allocator);

        if (server_obj.get("headers")) |headers_value| {
            const headers_obj = switch (headers_value) {
                .object => |obj| obj,
                else => continue,
            };
            var header_iter = headers_obj.iterator();
            while (header_iter.next()) |h_entry| {
                const key = h_entry.key_ptr.*;
                const value = switch (h_entry.value_ptr.*) {
                    .string => |s| s,
                    else => continue,
                };
                try headers.append(allocator, .{ .key = key, .value = value });
            }
        }

        // Fetch tools from this server
        const tools = try fetchToolsFromServer(allocator, url, headers.items, server_name);

        try all_tools.appendSlice(allocator, tools);
    }

    return try all_tools.toOwnedSlice(allocator);
}

/// Fetch tools from a single MCP server
fn fetchToolsFromServer(
    allocator: std.mem.Allocator,
    url: []const u8,
    _headers: []const McpHeader,
    server_name: []const u8,
) ![]tool_models.AgentTool {
    const tools_url = url;

    var client = custom_http_client.Client.init(allocator);
    defer client.deinit();

    const request_body = try allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"tools/list\",\"params\":{}}");
    defer allocator.free(request_body);

    // Flatten the small bounded `_headers` slice + the Accept header into
    // a `[]const custom_http_client.Header` slice (the type the
    // custom_http_client.post() API takes). Stack-allocated; MCP headers
    // are bounded by the user's MCP server config so this never grows.
    var header_buf: [16]custom_http_client.Header = undefined;
    var header_count: usize = 0;
    header_buf[header_count] = .{ .name = "Accept", .value = "application/json, text/event-stream" };
    header_count += 1;
    for (_headers) |h| {
        if (header_count >= header_buf.len) return error.InvalidMCPHeaders;
        header_buf[header_count] = .{ .name = h.key, .value = h.value };
        header_count += 1;
    }
    const header_slice = header_buf[0..header_count];

    const result = custom_http_client.post(
        &client,
        tools_url,
        request_body,
        header_slice,
        .{ .timeout_ms = 30_000 },
    ) catch |err| {
        std.log.warn("Failed to fetch MCP tools from {s}: {s}", .{ server_name, @errorName(err) });
        return error.HttpRequestError;
    };
    defer result.deinit(allocator);

    if (result.status_code != 200) {
        std.log.warn("MCP server {s} returned status {d}", .{ server_name, result.status_code });
        return error.InvalidResponse;
    }

    const clean_body = stripSsePrefix(result.body);
    const body_to_parse = if (clean_body) |b| b else result.body;

    std.log.warn("MCP response from {s}: {d} bytes", .{ server_name, body_to_parse.len });

    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();

    const parsed = json.parseFromSlice(json.Value, parse_arena.allocator(), body_to_parse, .{
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .use_last,
    }) catch |err| {
        std.log.warn("Failed to parse MCP response from {s}: {s}", .{ server_name, @errorName(err) });
        return error.JsonParseError;
    };

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => {
            std.log.warn("Invalid MCP response from {s}: expected object", .{server_name});
            return error.InvalidResponse;
        },
    };

    const result_value = root.get("result") orelse {
        std.log.warn("Invalid MCP response from {s}: missing result", .{server_name});
        return error.InvalidResponse;
    };

    const result_obj = switch (result_value) {
        .object => |obj| obj,
        else => {
            std.log.warn("Invalid MCP response from {s}: result not an object", .{server_name});
            return error.InvalidResponse;
        },
    };

    const tools_value = result_obj.get("tools") orelse {
        std.log.warn("Invalid MCP response from {s}: missing tools", .{server_name});
        return error.InvalidResponse;
    };

    const tools_array = switch (tools_value) {
        .array => |arr| arr,
        else => {
            std.log.warn("Invalid MCP response from {s}: tools not an array", .{server_name});
            return error.InvalidResponse;
        },
    };

    var agent_tools: std.ArrayList(AgentTool) = .empty;
    defer agent_tools.deinit(allocator);

    for (tools_array.items) |tool_value| {
        const tool_obj: ?std.json.ObjectMap = switch (tool_value) {
            .object => |obj| obj,
            .null, .bool, .integer, .float, .string, .array, .number_string => null,
        };
        const tool_obj_inner = tool_obj orelse continue;

        const name_value = tool_obj_inner.get("name") orelse continue;
        const name: []const u8 = switch (name_value) {
            .string => |s| s,
            .null, .bool, .integer, .float, .array, .object, .number_string => continue,
        };

        const desc_value = tool_obj_inner.get("description") orelse continue;
        const description: []const u8 = switch (desc_value) {
            .string => |s| s,
            .null, .bool, .integer, .float, .array, .object, .number_string => continue,
        };

        const schema_value = tool_obj_inner.get("inputSchema") orelse continue;
        const schema_obj: ?std.json.ObjectMap = switch (schema_value) {
            .object => |obj| obj,
            .null, .bool, .integer, .float, .string, .array, .number_string => null,
        };
        const schema_obj_inner = schema_obj orelse continue;

        const props_value = schema_obj_inner.get("properties") orelse continue;
        const properties = try parseProperties(allocator, props_value, server_name);

        var required: []const []const u8 = &[_][]const u8{};
        if (schema_obj_inner.get("required")) |req_value| {
            const req_array: ?[]const json.Value = switch (req_value) {
                .array => |arr| arr.items,
                else => null,
            };
            if (req_array) |items| {
                var req_list: std.ArrayList([]const u8) = .empty;
                defer req_list.deinit(allocator);
                for (items) |req_item| {
                    const req_str: []const u8 = switch (req_item) {
                        .string => |s| s,
                        .null, .bool, .integer, .float, .array, .object, .number_string => continue,
                    };
                    try req_list.append(allocator, try allocator.dupe(u8, req_str));
                }
                required = try req_list.toOwnedSlice(allocator);
            }
        }

        const agent_tool = AgentTool{
            .type = "function",
            .function = AgentToolFunction{
                .name = try std.fmt.allocPrint(allocator, "mcp_{s}_{s}", .{ server_name, name }),
                .description = try allocator.dupe(u8, description),
                .parameters = ToolParameters{
                    .type = "object",
                    .properties = properties,
                    .required = required,
                },
            },
        };

        try agent_tools.append(allocator, agent_tool);
    }

    return try agent_tools.toOwnedSlice(allocator);
}

/// Parse JSON properties into ToolProperty array
pub fn parseProperties(
    allocator: std.mem.Allocator,
    props_value: json.Value,
    server_name: []const u8,
) ![]tool_models.ToolProperty {
    _ = server_name;
    const props_obj: ?std.json.ObjectMap = switch (props_value) {
        .object => |obj| obj,
        .null, .bool, .integer, .float, .string, .array, .number_string => null,
    };
    const props_obj_inner = props_obj orelse return &[_]ToolProperty{};

    var properties: std.ArrayList(ToolProperty) = .empty;
    defer properties.deinit(allocator);

    var prop_iter = props_obj_inner.iterator();
    while (prop_iter.next()) |entry| {
        const prop_name = entry.key_ptr.*;
        const prop_value = entry.value_ptr.*;

        const prop_obj: ?std.json.ObjectMap = switch (prop_value) {
            .object => |obj| obj,
            .null, .bool, .integer, .float, .string, .array, .number_string => null,
        };
        const prop_obj_inner = prop_obj orelse continue;

        const type_value = prop_obj_inner.get("type") orelse continue;
        const prop_type: []const u8 = switch (type_value) {
            .string => |s| s,
            .null, .bool, .integer, .float, .array, .object, .number_string => continue,
        };

        var prop_desc: []const u8 = "";
        if (prop_obj_inner.get("description")) |desc_value| {
            prop_desc = switch (desc_value) {
                .string => |s| s,
                .null, .bool, .integer, .float, .array, .object, .number_string => "",
            };
        }

        try properties.append(allocator, ToolProperty{
            .name = try allocator.dupe(u8, prop_name),
            .type = try allocator.dupe(u8, prop_type),
            .description = try allocator.dupe(u8, prop_desc),
        });
    }

    return try properties.toOwnedSlice(allocator);
}

/// Build background processes content string from database for system prompt
pub fn BuildBackgroundProcessPrompt(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]const u8 {
    if (session_id.len == 0) {
        return allocator.dupe(u8, "");
    }

    var processesBuilder: std.ArrayList(u8) = .empty;
    errdefer processesBuilder.deinit(allocator);

    // Get all background processes for this session
    const processes = try background_process.getBySession(db, allocator, session_id);
    defer {
        for (processes) |p| {
            allocator.free(p.command);
            allocator.free(p.log_path);
            allocator.free(p.status);
        }
        allocator.free(processes);
    }

    if (processes.len == 0) {
        return allocator.dupe(u8, "");
    }

    try processesBuilder.appendSlice(allocator, "## Running Background Processes\n\n");
    try processesBuilder.appendSlice(allocator, "The following background processes are running for this session:\n\n");

    for (processes) |p| {
        try processesBuilder.appendSlice(allocator, "- **PID: ");
        const pid_str = try std.fmt.allocPrint(allocator, "{}", .{p.pid});
        defer allocator.free(pid_str);
        try processesBuilder.appendSlice(allocator, pid_str);
        try processesBuilder.appendSlice(allocator, "** | Status: ");
        try processesBuilder.appendSlice(allocator, p.status);
        try processesBuilder.appendSlice(allocator, " | Command: `");
        try processesBuilder.appendSlice(allocator, p.command);
        try processesBuilder.appendSlice(allocator, "`\n");

        // Add log path info
        try processesBuilder.appendSlice(allocator, "  - Log: ");
        try processesBuilder.appendSlice(allocator, p.log_path);
        try processesBuilder.appendSlice(allocator, "\n");
    }

    try processesBuilder.appendSlice(allocator, "\nYou can check the status of these processes by reading their log files.\n");

    return processesBuilder.toOwnedSlice(allocator);
}

/// Build dynamic agents content string from database for persistence
pub fn BuildDynamicAgentContent(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]const u8 {
    if (session_id.len == 0) {
        return allocator.dupe(u8, "");
    }

    var agentsBuilder: std.ArrayList(u8) = .empty;
    errdefer agentsBuilder.deinit(allocator);

    const sql = "SELECT agent_name FROM session_agents WHERE session_id = ?";
    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    var hasAgents = false;
    while (try rows.next()) |row| {
        hasAgents = true;
        const agent_name = row.values[0];
        try agentsBuilder.appendSlice(allocator, "- ");
        try agentsBuilder.appendSlice(allocator, agent_name);
        try agentsBuilder.appendSlice(allocator, "\n");
        row.deinit(allocator);
    }

    if (!hasAgents) {
        return allocator.dupe(u8, "");
    }

    // Prepend the header to the existing content
    const header = "\n\n## Loaded Dynamic Agents\n\n";
    const result = try allocator.alloc(u8, header.len + agentsBuilder.items.len);
    @memcpy(result[0..header.len], header);
    @memcpy(result[header.len..], agentsBuilder.items);
    return result;
}

/// Maximum length (in chars) of the sub-agent's `system_prompt`
/// preview to embed in the listing. Truncated beyond this to
/// keep the prompt lean — the LLM doesn't need a 2KB persona to
/// decide which sub-agent to dispatch to.
const SUB_AGENT_DESCRIPTION_MAX: usize = 80;

/// Maximum number of kanban columns rendered in the `## Kanban Status
/// Tracking` section. Boards with more columns truncate to the first
/// N by `position ASC` and add an `… and M more` footer. 10 is well
/// above any realistic kanban (typical N ≤ 7).
const MAX_KANBAN_COLUMNS: u32 = 10;

/// Build the "Available Sub-Agents" listing for the current
/// session. Reads `selected_profile_model` from the `sessions`
/// table, then resolves the sub-agents list with the per-profile
/// overlay (active profile's `sub_agents` first, then top-level).
///
/// Returns an empty string when:
///   - the session doesn't exist or has empty profile / no profile
///   - the resolved config has no sub_agents (top-level + profile)
///   - the LlmConfig singleton is unreachable (graceful fallback)
///
/// The returned slice is freshly allocated on `allocator`; caller
/// owns it and must `defer allocator.free(...)`.
fn BuildSubAgentsListing(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]const u8 {
    if (session_id.len == 0) return allocator.dupe(u8, "");

    // 1. Look up the active session's `selected_profile_model`.
    //    `getSession` returns `!?SessionTableInfo` (error union of
    //    optional). Unwrap both: a hard error propagates; a null
    //    optional (row doesn't exist) is treated as "no profile
    //    selected" (no sub-agents listing).
    const maybe_session = llm_history.getSession(allocator, db, session_id) catch
        return allocator.dupe(u8, "");
    var session_info = maybe_session orelse return allocator.dupe(u8, "");
    defer session_info.deinit(allocator);

    // 2. Get the LlmConfig from the singleton. Graceful fallback
    // when the singleton is unreachable (e.g. tests that
    // don't initialize it).
    const di = nalarcore.getSingleton() catch return allocator.dupe(u8, "");
    const config = nalarcore.getLlmConfig(di);

    // 3. Resolve which list to render. Per-profile first (when a
    // profile is selected AND has sub_agents configured), else
    // top-level. Note: `config.getProfile(name)` returns null when
    // the profile is missing; we then fall through to the
    // top-level list. The user's review comment
    // "make sure it integrate with selected profile models or
    // the default one" is satisfied by this precedence chain.
    const profile_name: []const u8 = session_info.selected_profile_model;
    const use_profile: bool = profile_name.len > 0;
    const rows = if (use_profile) blk: {
        if (config.getProfile(profile_name)) |profile| {
            if (profile.sub_agents.len > 0) break :blk profile.sub_agents;
        }
        break :blk config.sub_agents;
    } else config.sub_agents;
    const source_label: []const u8 = if (use_profile) profile_name else "";

    if (rows.len == 0) return allocator.dupe(u8, "");

    // 4. Build the listing rows. Borrowed slices from the
    // SubAgentConfig (lives as long as the LlmConfig singleton).
    var row_buf = std.ArrayList(prompt.SubAgentListingRow).empty;
    errdefer row_buf.deinit(allocator);

    for (rows) |sa| {
        if (sa.name.len == 0) continue; // defensive

        // Truncate the system_prompt to SUB_AGENT_DESCRIPTION_MAX
        // chars (with an ellipsis if truncated) for a one-line
        // description in the listing. Use a local stack buffer
        // to avoid allocating per-row.
        const sp = sa.system_prompt;
        var desc_buf: [SUB_AGENT_DESCRIPTION_MAX + 3]u8 = undefined;
        const desc: []const u8 = if (sp.len <= SUB_AGENT_DESCRIPTION_MAX)
            sp
        else blk: {
            @memcpy(desc_buf[0..SUB_AGENT_DESCRIPTION_MAX], sp[0..SUB_AGENT_DESCRIPTION_MAX]);
            @memcpy(desc_buf[SUB_AGENT_DESCRIPTION_MAX..][0..3], "...");
            break :blk desc_buf[0 .. SUB_AGENT_DESCRIPTION_MAX + 3];
        };

        try row_buf.append(allocator, .{
            .name = sa.name,
            .model = sa.model,
            .description = desc,
            .source = source_label,
        });
    }

    if (row_buf.items.len == 0) return allocator.dupe(u8, "");

    // 5. Render the section. Match the `appendToolListing` /
    //    `appendSkillsListing` pattern: pass a `*ArrayList(u8)`
    //    directly (no writer needed — ArrayList owns its
    //    memory). Caller can toOwnedSlice to extract.
    var listing = std.ArrayList(u8).empty;
    defer listing.deinit(allocator);
    try prompt.appendSubAgentsListing(allocator, &listing, row_buf.items);
    return try listing.toOwnedSlice(allocator);
}

// Cap for how many design pages to enumerate in the Design Canvas status
// prompt. Pages beyond the cap are listed as a count footer. Mirrors
// `MAX_KANBAN_COLUMNS` (10) — small enough to keep the prompt compact,
// large enough to cover most multi-page designs.
const MAX_DESIGN_PAGES: u32 = 10;


fn removeTools(tools: []tool_models.AgentTool, names: []const []const u8) []tool_models.AgentTool {
    var count: usize = 0;
    for (tools) |tool| {
        var keep = true;
        for (names) |name| {
            if (std.mem.eql(u8, tool.function.name, name)) {
                keep = false;
                break;
            }
        }
        if (keep) {
            tools[count] = tool;
            count += 1;
        }
    }
    return tools[0..count];
}

pub fn filteringTools(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, session_id: []const u8, tools: []tool_models.AgentTool) ![]tool_models.AgentTool {
    const ctx = (llm_history.getWorkspaceContext(allocator, db, session_id) catch |err| {
        std.log.warn("BuildDesignCanvasPrompt: getWorkspaceContext failed: {}", .{err});
        return tools;
    }) orelse return tools;
    defer ctx.deinit(allocator);

    var result = tools;

    if (std.mem.eql(u8, ctx.self_item_type, "design")) {
        result = removeTools(result, &.{
            kanban_list_mod.kanban_list_tool.function.name,
            kanban_move_task_mod.kanban_move_task_tool.function.name,
            kanban_create_task_tool.create_kanban_task_tool.function.name,
        });
    }

    if (std.mem.eql(u8, ctx.self_item_type, "folder")) {
        result = removeTools(result, &.{
            kanban_list_mod.kanban_list_tool.function.name,
            kanban_move_task_mod.kanban_move_task_tool.function.name,
            kanban_create_task_tool.create_kanban_task_tool.function.name,
            set_design_page_mod.set_design_page_tool.function.name,
            add_design_element_mod.add_design_element_tool.function.name,
            update_design_element_mod.update_design_element_tool.function.name,
            group_design_elements_mod.group_design_element_tool.function.name,
            set_element_parent_mod.set_element_parent_tool.function.name,
            move_design_element_mod.move_design_element_tool.function.name,
            move_element_to_page_mod.move_element_to_page_tool.function.name,
        });
    }

    if (std.mem.eql(u8, ctx.self_item_type, "kanban")) {
        result = removeTools(result, &.{
            set_design_page_mod.set_design_page_tool.function.name,
            add_design_element_mod.add_design_element_tool.function.name,
            update_design_element_mod.update_design_element_tool.function.name,
            group_design_elements_mod.group_design_element_tool.function.name,
            set_element_parent_mod.set_element_parent_tool.function.name,
            move_design_element_mod.move_design_element_tool.function.name,
            move_element_to_page_mod.move_element_to_page_tool.function.name,
        });
    }

    return result;
}

