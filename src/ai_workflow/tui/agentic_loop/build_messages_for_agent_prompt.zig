const std = @import("std");
const json = std.json;
const nalarcore = @import("nalarcore");
const agent = nalarcore.agent;
const llm_history = @import("../llm_history.zig");
const session_helpers = llm_history;
const sqlite = nalarcore.sqlite;
const prompt = nalarcore.prompt;
const TUIHistory = @import("../models.zig").TUIHistory;
const tool_models = nalarcore.tool_models;
const config_mod = nalarcore.config;
const http_client = nalarcore.http_client;
const background_process = @import("../background_process.zig");
const ProcessInfo = background_process.ProcessInfo;
const inherited_context = @import("../inherited_context.zig");
const kanban_model = @import("../kanban_model.zig");
const design_model = @import("../design_model.zig");

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
const set_design_page_mod = nalarcore.set_design_page;
const add_design_element_mod = nalarcore.add_design_element;
const update_design_element_mod = nalarcore.update_design_element;
const group_design_elements_mod = nalarcore.group_design_elements;
const set_element_parent_mod = nalarcore.set_element_parent;
const move_design_element_mod = nalarcore.move_design_element;
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

    const backgroundProcessmessage = try BuildBackgroundProcessPrompt(allocator, db, session_id);
    defer allocator.free(backgroundProcessmessage);

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

    // buildAgentPrompt now handles processMessages internally
    const activity_info = try agentic_loop.prompts_mod.makeActivityInfo(allocator, io, db, session_id);
    defer allocator.free(activity_info);

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
    const designStatusContent = try BuildDesignCanvasPrompt(allocator, db, session_id);
    defer allocator.free(designStatusContent);

    const systemContent = try prompt.build_agent_prompt(allocator, io, cwd, skills, memoryMd, backgroundProcessmessage, agentUsed, filtered_tools, activity_info, environment, sub_agents_listing, workspaceContext, kanbanStatusContent, designStatusContent);

    // Render inherited parent conversation history (if requested) and append
    // it to the system prompt as a labelled, read-only block.
    const inherited_md = inherited_context.formatHistory(
        allocator,
        db,
        parent_session_id, // the parent's session_id, NOT the sub-agent's
        inherited_context.parseMode(inherited_context_mode) catch .none,
    ) catch blk: {
        std.log.warn("buildMessages: failed to render inherited_context: mode={s}", .{inherited_context_mode});
        break :blk try allocator.dupe(u8, "");
    };
    defer allocator.free(inherited_md);

    var final_system: std.ArrayList(u8) = .empty;
    defer final_system.deinit(allocator);
    try final_system.appendSlice(allocator, systemContent);
    if (inherited_md.len > 0) {
        try final_system.appendSlice(allocator, "\n\n");
        try final_system.appendSlice(allocator, inherited_md);
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
pub fn buildMCPToolsRun(allocator: std.mem.Allocator, io: std.Io, mcpServers: std.json.Value) !?[]tool_models.AgentTool {
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
        const tools = try fetchToolsFromServer(allocator, io, url, headers.items, server_name);

        try all_tools.appendSlice(allocator, tools);
    }

    return try all_tools.toOwnedSlice(allocator);
}

/// Fetch tools from a single MCP server
fn fetchToolsFromServer(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    _headers: []const McpHeader,
    server_name: []const u8,
) ![]tool_models.AgentTool {
    const tools_url = url;

    var client = http_client.HttpClient.init(allocator, io);
    defer client.deinit();

    const request_body = try allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"tools/list\",\"params\":{}}");
    defer allocator.free(request_body);

    var headers_hash = std.StringHashMap([]const u8).init(allocator);
    defer headers_hash.deinit();

    try headers_hash.put("Accept", "application/json, text/event-stream");

    for (_headers) |header| {
        try headers_hash.put(header.key, header.value);
    }

    const result = client.post(tools_url, request_body, headers_hash) catch |err| {
        std.log.warn("Failed to fetch MCP tools from {s}: {s}", .{ server_name, @errorName(err) });
        return error.HttpRequestError;
    };
    defer allocator.free(result.body);

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
        });
    }

    if (std.mem.eql(u8, ctx.self_item_type, "folder")) {
        result = removeTools(result, &.{
            kanban_list_mod.kanban_list_tool.function.name,
            kanban_move_task_mod.kanban_move_task_tool.function.name,
            set_design_page_mod.set_design_page_tool.function.name,
            add_design_element_mod.add_design_element_tool.function.name,
            update_design_element_mod.update_design_element_tool.function.name,
            group_design_elements_mod.group_design_element_tool.function.name,
            set_element_parent_mod.set_element_parent_tool.function.name,
            move_design_element_mod.move_design_element_tool.function.name,
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
        });
    }

    return result;
}

/// Render the "Design Canvas" markdown block — workflow expectations
/// for the LLM when the session's parent item is a design canvas
/// (`item_type === 'design'`). Mirrors `BuildKanbanStatusPrompt`:
/// silently returns `""` (a 0-byte heap-owned slice) when the session
/// is not bound to a design item, when the DB lookups fail, or when
/// the session_id is empty.
///
/// The block teaches the LLM about the 3 design tools
/// (`set_design_page`, `add_element`, `update_element`) and the 6
/// element types (`rectangle`, `ellipse`, `text`, `image`, `frame`,
/// `group`) so it can pick the right shape on first call without
/// re-reading the tool schemas. It also lists the current pages (with
/// their visible elements) so the agent has spatial context before
/// deciding what to add/modify.
pub fn BuildDesignCanvasPrompt(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]const u8 {
    if (session_id.len == 0) return allocator.dupe(u8, "");

    // 1. Re-use the workspace-context anchor to read the parent's
    //    item_type without a second JOIN. Bail out when the parent
    //    isn't a design canvas.
    const ctx = (llm_history.getWorkspaceContext(allocator, db, session_id) catch |err| {
        std.log.warn("BuildDesignCanvasPrompt: getWorkspaceContext failed: {}", .{err});
        return allocator.dupe(u8, "");
    }) orelse return allocator.dupe(u8, "");
    defer ctx.deinit(allocator);

    if (!std.mem.eql(u8, ctx.self_item_type, "design")) {
        return allocator.dupe(u8, "");
    }

    // 2. Read the pages (in flow order). Same graceful-skip pattern as
    //    BuildKanbanStatusPrompt — any DB failure returns "".
    const pages = design_model.listPages(allocator, db, ctx.self_item_id) catch |err| {
        std.log.warn("BuildDesignCanvasPrompt: listPages failed: {}", .{err});
        return allocator.dupe(u8, "");
    };
    defer design_model.freePages(allocator, pages);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "\n\n## Design Canvas\n\n");
    try out.appendSlice(allocator,
        \\This task is on a design canvas (parent item_type: `design`).
        \\**You interact with the canvas via 5 LLM tools** (full schemas
        \\in the tool listing below — pass `workspace_id` + `item_id` from
        \\the `## Workspace Context` section above, and `page_id` is the
        \\page's id from the listing below):
        \\
        \\- `set_design_page(item_id, page_name, width?, height?)` — create
        \\  or look up a page by name. Idempotent: calling with an existing
        \\  name returns the same `page_id`. Defaults: width=1920,
        \\  height=1080.
        \\
        \\**No fixed page bounds.** The canvas-background feature has been
        \\removed (plan docs/superpowers/plans/2026-07-29-remove-canvas-background.md).
        \\Pages are purely logical containers; elements can be placed at
        \\ANY coordinates (positive, negative, or values larger than the
        \\page width / height). The `width` / `height` values on a page
        \\are informational only — a "preferred export size" hint, not
        \\an enforced boundary. Do NOT try to keep elements inside any
        \\specific rectangle; let the user place them wherever the design
        \\needs.
        \\- `add_element(page_id, name, type, html, x?, y?, width?, height?, fill?, rotation?, corner_radius?, opacity?, text_content?, text_style?, image_url?, parent_id?)`
        \\  — add one element to a page. The `html` is the rendered DOM
        \\  fragment (e.g. `<div class="card">...</div>`) that the
        \\  frontend mounts in the canvas at the given (x, y) with the
        \\  given width/height. Geometry defaults to 0/0/100/100; `fill`
        \\  is a CSS color string (`#ffffff`, `rgb(...)`, etc.).
        \\  Pass `parent_id="elem_..."` to nest the new element under
        \\  an existing `group` or `frame` on the same page. Omit
        \\  `parent_id` (or pass `null`) for top-level — same as the
        \\  pre-2026-07-29 behaviour.
        \\- `update_element(element_id, ...)` — patch any subset of the
        \\  element's fields (name, type, html, x/y/width/height/rotation,
        \\  fill, stroke, stroke_width, corner_radius, opacity,
        \\  text_content, text_style, image_url). All fields nullable;
        \\  pass only what changes. **`update_element` does NOT change
        \\  the parent/group hierarchy** — see `set_element_parent` for
        \\  that.
        \\- `set_element_parent(element_id, new_parent_id?)` — re-parent
        \\  an EXISTING element. Pass `new_parent_id="elem_..."` to
        \\  nest it under an existing `group`/`frame`; pass
        \\  `new_parent_id=null` (or omit) to detach back to top-level.
        \\  Use this to fix an element that was created at the wrong
        \\  nesting level — there is no need to delete + re-add.
        \\- `group_elements(page_id, child_ids, name?, type?)` — wrap
        \\  2+ existing top-level elements in a NEW `group` or `frame`
        \\  (unioned bounding box). The new parent is a sibling of the
        \\  children; the children get a new `parent_id` pointing to
        \\  the new group. Use this when you want to group EXISTING
        \\  siblings that you didn't create with a parent.
        \\
        \\**Element types** (pass the string in `add_element`/`update_element`):
        \\
        \\- `rectangle` — filled rect with optional corner_radius + fill.
        \\  Use for backgrounds, cards, buttons, badges.
        \\- `ellipse` — filled ellipse, same geometry as rectangle.
        \\- `text` — text element. The `text_content` field is the
        \\  visible string; `text_style` is a CSS snippet (e.g.
        \\  `"font-size:24px;color:#111;"`).
        \\- `image` — raster image element. The `image_url` field is the
        \\  URL (https:// or data: or relative); `html` is the `<img>`
        \\  fragment the canvas mounts.
        \\- `frame` — a CONTAINER that holds children. Create the frame
        \\  FIRST (via `add_element` with `type='frame'`), then nest
        \\  children inside it with a SECOND `add_element` call passing
        \\  `parent_id=<frame.id>`. Children appear indented under the
        \\  frame in the Layers panel.
        \\- `group` — same as `frame` for nesting (`parent_id` works
        \\  identically), but groups do not visually clip their
        \\  children. Use `frame` for spatial containment (e.g. an app
        \\  window containing panels); use `group` for logical grouping
        \\  (e.g. an icon-button set you want to operate as one unit).
        \\
        \\**Designing INTERACTIVE HTML — the html field is a live
        \\mini-browser, not a flat mockup.**
        \\
        \\Every element's `html` body is rendered inside a sandboxed
        \\`<iframe>` in the user's canvas. The user can switch the
        \\canvas into **Preview mode** (toolbar button or Cmd/Ctrl+P;
        \\Esc exits) and INTERACT with the rendered HTML — type into
        \\inputs, click buttons, toggle switches, scroll, select text,
        \\fill forms end-to-end. The `html` field accepts ANY valid
        \\HTML, not just visual shapes.
        \\
        \\You SHOULD write real interactive elements when the design
        \\is a UI flow the user will exercise:
        \\
        \\- `<input type="text">`, `<input type="email">`, `<input
        \\  type="checkbox">`, `<input type="radio">`, `<textarea>`,
        \\  `<select>` — for forms.
        \\- `<button>` with `onclick="..."` handlers — scripts run in
        \\  the iframe sandbox (`allow-scripts`, no `allow-same-origin`).
        \\  They can manipulate the iframe's own DOM (toggle visibility,
        \\  update text, validate forms) but cannot reach the parent
        \\  document. Cross-iframe state (click X in iframe A → open Y
        \\  in iframe B) is NOT supported — keep state local to one
        \\  element.
        \\- `<a href="...">` links — they navigate inside the iframe,
        \\  not the host app. Useful for tabs / in-iframe "pages".
        \\- `<details>`/`<summary>`, `<dialog>`, native form validation
        \\  (`required`, `pattern`, `min`/`max`) — all work in Preview.
        \\
        \\**Don't** render inputs as `<div>` styled to look like them.
        \\Write the actual `<input>` / `<button>` / `<select>` so the
        \\user can interact in Preview and verify the design works.
        \\Quick comparison:
        \\
        \\  BAD (visual mockup, no interactivity):
        \\    <div style="border:1px solid #ccc;padding:8px;">Email</div>
        \\    <div style="background:#3b82f6;color:#fff;padding:8px 16px;
        \\              border-radius:6px;">Submit</div>
        \\  GOOD (interactive in Preview):
        \\    <form>
        \\      <label>Email <input type="email" required></label>
        \\      <button type="submit">Submit</button>
        \\    </form>
        \\
        \\**Nesting / parent_id rules:**
        \\  1. The parent must exist BEFORE the child. Two `add_element`
        \\     calls: first the parent (frame/group), THEN the child with
        \\     `parent_id=<parent.id>`.
        \\  2. The target parent must have `type='frame'` or `type='group'`
        \\     and be on the SAME page. Leaf types (rectangle, ellipse,
        \\     text, image) cannot contain children — reject with
        \\     `<error>parent_id points to a leaf-type element...</error>`.
        \\  3. To re-parent an EXISTING element (e.g. you created
        \\     `tags-label` at top-level but want it inside `dialog-card`),
        \\     call `set_element_parent(element_id, new_parent_id)`. Do
        \\     NOT pass `parent_id` to `update_element` — that field is
        \\     not in `update_element`'s schema and the call will be
        \\     rejected or silently ignored.
        \\  4. To un-parent (make top-level), call
        \\     `set_element_parent(element_id, null)` or with
        \\     `new_parent_id=""`.
        \\  5. Self-parenting and creating a cycle (target is the element
        \\     itself or any descendant) are rejected with
        \\     `CycleDetected` (the element's `parent_id` is unchanged).
        \\  6. To wrap multiple EXISTING top-level siblings in a new
        \\     group, use `group_elements(page_id, [...child_ids])` —
        \\     creates a new parent + reparents the children atomically.
        \\  7. **Decide your nesting strategy BEFORE you start adding
        \\     elements.** Adding siblings at top-level and then trying
        \\     to bulk-nest them works (via `group_elements` for new
        \\     groups, or `set_element_parent` for an existing one),
        \\     but it's strictly more work than nesting during creation.
        \\     The design viewer shows the Layers panel on the right
        \\     edge — always visually confirm each element is under the
        \\     correct parent after the call.
        \\
        \\**No cross-iframe persistence.** State inside one element's
        \\iframe does NOT survive Preview-mode toggle (the iframe
        \\reloads from the saved `html` on every Preview entry).
        \\Anything the user types or toggles is ephemeral. If a flow
        \\requires real persistence, surface it as an explicit ask
        \\(e.g. "save to backend") — don't promise it works in Preview.
        \\
        \\**Styling scrollbars inside the iframe** — the design preview
        \\renders each element inside a sandboxed `<iframe
        \\sandbox="allow-scripts">` (no `allow-same-origin`). That makes
        \\the iframe a **separate document**: parent-page CSS does NOT
        \\propagate in, so the host's `::-webkit-scrollbar` rules in
        \\`style.css` are ignored inside the preview. If your element
        \\uses `overflow-x: auto`, `overflow-y: auto`, `overflow: auto`,
        \\or `overflow: scroll` on any container, the user will see a
        \\**default light-gray webkit scrollbar** that looks out of
        \\place against the dark nalar theme.
        \\
        \\To keep designs on-brand, embed a `<style>` block at the top
        \\of the element's `html` body that styles scrollbars using the
        \\nalar color tokens. Template (paste at the very top of the
        \\`html` string you pass to `add_element` / `update_element`):
        \\
        \\```html
        \\<style>
        \\  ::-webkit-scrollbar { width: 6px; height: 6px; }
        \\  ::-webkit-scrollbar-track { background: transparent; }
        \\  ::-webkit-scrollbar-thumb {
        \\    background: #393836;
        \\    border-radius: 3px;
        \\  }
        \\  ::-webkit-scrollbar-thumb:hover { background: #625e5a; }
        \\  /* Firefox */
        \\  * { scrollbar-width: thin;
        \\        scrollbar-color: #393836 transparent; }
        \\</style>
        \\```
        \\
        \\Use the same template for both `overflow-x` and `overflow-y`
        \\(the `::-webkit-scrollbar` rule covers both axes). Drop it in
        \\unconditionally for any element with a scrolling container —
        \\the cost is ~6 CSS rules and it prevents the "ugly default
        \\scrollbar" regression users hit when they don't see scrollbar
        \\styling in the host app.
        \\
    );

    // 3. Page listing (cap: MAX_DESIGN_PAGES, with footer).
    try out.appendSlice(allocator, "\n**Pages on this canvas** (in flow order):\n");
    if (pages.len == 0) {
        try out.appendSlice(allocator,
            \\_No pages yet._ Call `set_design_page(item_id, "<descriptive name>")`
            \\to create the first one before adding any elements.
            \\
        );
    } else {
        const shown = @min(pages.len, MAX_DESIGN_PAGES);
        for (pages[0..shown]) |p| {
            const pos_str = try std.fmt.allocPrint(allocator, "`, position {d})\n", .{p.position});
            defer allocator.free(pos_str);
            try out.appendSlice(allocator, "- `");
            try out.appendSlice(allocator, p.name);
            try out.appendSlice(allocator, "` (`");
            try out.appendSlice(allocator, p.id);
            try out.appendSlice(allocator, ", width ");
            const w_str = try std.fmt.allocPrint(allocator, "{d}", .{p.width});
            defer allocator.free(w_str);
            try out.appendSlice(allocator, w_str);
            try out.appendSlice(allocator, ", height ");
            const h_str = try std.fmt.allocPrint(allocator, "{d}", .{p.height});
            defer allocator.free(h_str);
            try out.appendSlice(allocator, h_str);
            try out.appendSlice(allocator, pos_str);

            // List visible elements on this page (cap: 8) so the LLM
            // has spatial context without re-querying. Errors degrade
            // gracefully — skip the element list when the DB read fails.
            const elements = design_model.listElements(allocator, db, p.id) catch |err| {
                std.log.warn("BuildDesignCanvasPrompt: listElements failed for page {s}: {}", .{ p.id, err });
                continue;
            };
            defer design_model.freeElements(allocator, elements);

            if (elements.len > 0) {
                try out.appendSlice(allocator, "  Elements:\n");
                const el_shown = @min(elements.len, @as(usize, 8));
                for (elements[0..el_shown]) |e| {
                    try out.appendSlice(allocator, "  - `");
                    try out.appendSlice(allocator, e.name);
                    try out.appendSlice(allocator, "` (");
                    try out.appendSlice(allocator, e.elem_type);
                    try out.appendSlice(allocator, ", id ");
                    try out.appendSlice(allocator, e.id);
                    // Include parent_id so the LLM can see the existing
                    // hierarchy at a glance ("top-level" vs nested under
                    // which container). Empty parent_id = "(top-level)".
                    if (e.parent_id.len > 0) {
                        try out.appendSlice(allocator, ", parent=");
                        try out.appendSlice(allocator, e.parent_id);
                    } else {
                        try out.appendSlice(allocator, ", parent=(top-level)");
                    }
                    const xywh = try std.fmt.allocPrint(allocator, ", x={d} y={d} w={d} h={d}", .{ e.x, e.y, e.width, e.height });
                    defer allocator.free(xywh);
                    try out.appendSlice(allocator, xywh);
                    try out.appendSlice(allocator, ")\n");
                }
                if (elements.len > 8) {
                    const footer = try std.fmt.allocPrint(
                        allocator,
                        "    … and {d} more elements on this page.\n",
                        .{elements.len - 8},
                    );
                    defer allocator.free(footer);
                    try out.appendSlice(allocator, footer);
                }
            }
        }
        if (pages.len > MAX_DESIGN_PAGES) {
            const footer = try std.fmt.allocPrint(
                allocator,
                "… and {d} more pages (cap: {d} shown).\n",
                .{ pages.len - MAX_DESIGN_PAGES, MAX_DESIGN_PAGES },
            );
            defer allocator.free(footer);
            try out.appendSlice(allocator, footer);
        }
    }

    // 4. Workflow expectations.
    try out.appendSlice(allocator,
        \\
        \\**Workflow expectations** (these apply every time you touch the canvas):
        \\
        \\- **start** — on first action, call `set_design_page(item_id, "<page>")`
        \\  to create the page (or look up the existing one). Skip if the
        \\  page listing above already shows the page you need.
        \\- **add** — call `add_element(page_id, name, type, html, ...)` for each
        \\  new shape. Pick `type` from the 6 above; pass `html` as the
        \\  rendered fragment (the canvas mounts it inside a positioned
        \\  wrapper). Coordinates (x, y) are top-left in canvas pixels.
        \\- **modify** — call `update_element(element_id, ...)` with the
        \\  changed fields only. The tool re-fetches and returns the full
        \\  element, so you can verify the patch landed.
        \\- **complete** — before your final reply, summarize which
        \\  pages/elements you created and any geometry you set. The user
        \\  sees the canvas update live; a recap keeps the chat history
        \\  aligned with the visual state.
        \\
    );

    return out.toOwnedSlice(allocator);
}
