const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const nalarcore = @import("nalarcore");
const mcp_stdio = nalarcore.mcp_stdio;
const mcp_http = nalarcore.mcp_http;
const mcp_types = nalarcore.mcp_types;
const agent = nalarcore.agent;
const llm_history = @import("llm_history.zig");
const session_helpers = llm_history;
const sqlite = nalarcore.sqlite;
const TUIHistory = @import("models.zig").TUIHistory;
const tool_models = nalarcore.tool_models;

// Inner prompt-template modules. Imported directly (not via
// `nalarcore.prompt`) because the orchestrator-side file owns the
// `build_agent_prompt` rendering assembly as of the 2026-08-23 move.
const prompts_const = @import("../../../modules/agent/prompts/prompts.zig");
const memory_prompts = @import("../../../modules/agent/prompts/memory.zig");
const tool_list_skills_mod = @import("../../../modules/agent/tools/list_skills.zig");
const tool_memories_mod = @import("../../../modules/agent/tools/memories.zig");

// Per-file tool system prompts are now stored directly in each tool's
// `AgentTool.function.system_prompt` field (see schemas.zig). The aggregator
// below reads `tool.function.system_prompt` dynamically from `filtered_tools`
// without hardcoding names — the tool's own `.name` is the key.
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
    const di = try nalarcore.getSingleton();
    const environment = di.environment;

    var final_system: std.ArrayList(u8) = .empty;
    defer final_system.deinit(allocator);

    const filtered_tools = try filteringTools(allocator, db, session_id, tools);

    // 1. Static prompts — inlined (no PROMPT_SECTIONS constant), gated on hasTool where needed
    try final_system.appendSlice(allocator, prompts_const.UniversalRules);
    try final_system.appendSlice(allocator, prompts_const.SearchToolRule);
    try final_system.appendSlice(allocator, prompts_const.Agent);
    try final_system.appendSlice(allocator, prompts_const.GitPrompt);
    try final_system.appendSlice(allocator, prompts_const.ResponseFormatting);
    if (hasTool(filtered_tools, "update_plan")) {
        try final_system.appendSlice(allocator,
            \\## Task Planning
            \\
            \\For multi-step work, lay out a structured plan early with the `update_plan` tool, then
            \\keep it in sync by calling `update_plan` after completing each checklist item (flip
            \\`- [ ]` → `- [x]`). The plan is automatically re-injected into your system prompt on
            \\every iteration, so you always see the current state. Use `get_plan` to verify the
            \\current state explicitly.
            \\
        );
    }
    try final_system.appendSlice(allocator, prompts_const.UpdateActivityRule);
    try final_system.appendSlice(allocator, prompts_const.memory.skills_system_prompt);
    _ = activeAgentContent;

    // 2. WorkingDirectoryContext — NALAR.md / CLAUDE.md / AGENTS.md (right after static sections)
    const memoryMd = try agentic_loop.prompts_mod.makeWorkingDirectoryContext(allocator, io, cwd);
    defer allocator.free(memoryMd);
    if (memoryMd.len > 0) {
        try final_system.appendSlice(allocator, "\n\n");
        try final_system.appendSlice(allocator, memoryMd);
    }

    // 3. Local Knowledge → Global Knowledge ("most specific first")
    const local_knowledge = try loadLocalKnowledge(allocator, io, cwd);
    defer allocator.free(local_knowledge);
    if (local_knowledge.len > 0) {
        try final_system.appendSlice(allocator, "\n\n## Local Knowledge\n\n");
        try final_system.appendSlice(allocator,
            \\The following markdown files are this project's local memory,
            \\auto-loaded from `<cwd>/.nalar/memories/`. Use `read_file` to
            \\load a specific memory on demand. To update, use `write_file`
            \\or `text_replace`; to delete, use `remove_file`.
            \\
        );
        try final_system.appendSlice(allocator, local_knowledge);
    }

    const knowledge = try loadGlobalKnowledge(allocator, io, environment);
    defer allocator.free(knowledge);
    if (knowledge.len > 0) {
        try final_system.appendSlice(allocator, "\n\n## Global Knowledge\n\n");
        try final_system.appendSlice(allocator,
            \\The following markdown files are your persistent global memory,
            \\auto-loaded from `~/.config/nalar/memories/`. Use `list_memory` to
            \\see metadata (and any files truncated below the budget).
        );
        try final_system.appendSlice(allocator, knowledge);
    }

    // 4. cwd + OS — consistent with build_agent_prompt (cwd after knowledge, OS at end of static block)
    if (cwd.len > 0) {
        try final_system.appendSlice(allocator, "\n\n**Current working directory:** ");
        try final_system.appendSlice(allocator, cwd);
    }

    const os_name = getCurrentOs();
    try final_system.appendSlice(allocator, "\n\n**Operating System:** ");
    try final_system.appendSlice(allocator, os_name);
    try final_system.appendSlice(allocator,
        \\**Important:** Always use OS-specific commands. Check the current OS
        \\before running system commands or shell scripts.
    );

    // 5. workspaceContext → agentSystemPrompt → agentKnowledge → agentKanbanSystemPrompt → agentKanbanKnowledge
    const workspaceContext = try agentic_loop.prompts_mod.makeWorkspaceContext(allocator, db, session_id);
    defer allocator.free(workspaceContext);
    if (workspaceContext.len > 0) {
        try final_system.appendSlice(allocator, workspaceContext);
    }

    const agentSystemPromptContent = try agentic_loop.prompts_mod.makeAgentSystemPrompt(allocator, io, db, session_id);
    defer allocator.free(agentSystemPromptContent);
    if (agentSystemPromptContent.len > 0) {
        try final_system.appendSlice(allocator, agentSystemPromptContent);
    }

    const agentKnowledgeContent = try agentic_loop.prompts_mod.makeAgentKnowledge(allocator, io, db, session_id);
    defer allocator.free(agentKnowledgeContent);
    if (agentKnowledgeContent.len > 0) {
        try final_system.appendSlice(allocator, agentKnowledgeContent);
    }

    const agentKanbanSystemPromptContent = try agentic_loop.prompts_mod.makeAgentKanbanSystemPrompt(allocator, io, db, session_id);
    defer allocator.free(agentKanbanSystemPromptContent);
    if (agentKanbanSystemPromptContent.len > 0) {
        try final_system.appendSlice(allocator, agentKanbanSystemPromptContent);
    }

    const agentKanbanKnowledgeContent = try agentic_loop.prompts_mod.makeAgentKanbanKnowledge(allocator, io, db, session_id);
    defer allocator.free(agentKanbanKnowledgeContent);
    if (agentKanbanKnowledgeContent.len > 0) {
        try final_system.appendSlice(allocator, agentKanbanKnowledgeContent);
    }

    // 6. kanbanStatus → designStatus
    const kanbanStatusContent = try agentic_loop.prompts_mod.makeKanbanContext(allocator, db, session_id, filtered_tools);
    defer allocator.free(kanbanStatusContent);
    if (kanbanStatusContent.len > 0) {
        try final_system.appendSlice(allocator, kanbanStatusContent);
    }

    const designStatusContent = try buildDesignCanvasPrompt(allocator, db, session_id);
    defer allocator.free(designStatusContent);
    if (designStatusContent.len > 0) {
        try final_system.appendSlice(allocator, designStatusContent);
    }

    // 7. Tool Behaviors + Available Skills + Available Sub-Agents
    try appendToolBehaviorSection(allocator, &final_system, filtered_tools);

    // Available Skills listing — gated on list_skills tool, best-effort
    try appendSkillsListing(allocator, &final_system, filtered_tools, cwd, io, environment);

    // Available Sub-Agents listing — from LlmConfig (profile-aware)
    const sub_agents_listing = try BuildSubAgentsListing(allocator, db, session_id);
    defer allocator.free(sub_agents_listing);
    if (sub_agents_listing.len > 0) {
        try final_system.appendSlice(allocator, "\n\n");
        try final_system.appendSlice(allocator, sub_agents_listing);
    }

    // 8. inherited_context → Current Plan
    const inherited_md = inherited_context.formatHistory(
        allocator,
        db,
        session_id,
        parent_session_id,
        inherited_context.parseMode(inherited_context_mode) catch .none,
    ) catch blk: {
        std.log.warn("buildMessages: failed to render inherited_context: mode={s}", .{inherited_context_mode});
        break :blk try allocator.dupe(u8, "");
    };
    defer allocator.free(inherited_md);
    if (inherited_md.len > 0) {
        try final_system.appendSlice(allocator, "\n\n");
        try final_system.appendSlice(allocator, inherited_md);
    }

    const planContent = try agentic_loop.prompts_mod.makePlanContext(allocator, db, session_id);
    defer allocator.free(planContent);
    if (planContent.len > 0) {
        try final_system.appendSlice(allocator, planContent);
    }

    const final_system_content = try final_system.toOwnedSlice(allocator);

    const systemMessage = agent.AgentMessage{
        .role = .system,
        .content = final_system_content,
    };

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
    /// MCP server config declares more than 16 custom headers; we
    /// stack-allocate the request header slice so there's a hard cap.
    TooManyHeaders,
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
///
/// `cancel_fn` (default null) — when set, polled between bytes read
/// from each MCP stdio child. The workflow's `isWorkerCancelled`
/// predicate is the canonical caller (see workflow.zig's
/// `mcp_cancel_thunk` helper that adapts it). When null, the
/// deadline becomes the only termination signal.
pub fn buildMCPToolsRun(
    allocator: std.mem.Allocator,
    mcpServers: std.json.Value,
    cancel_fn: ?*const fn () bool,
) !?[]tool_models.AgentTool {
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

        // Transport dispatch: stdio (command) takes precedence over
        // HTTP (url). If the entry has a `command`, route to the stdio
        // helper; otherwise fall through to the existing HTTP path.
        if (server_obj.get("command")) |_| {
            // 30s default for tools/list — see mcp_stdio.zig's plan
            // for the per-call timeouts. We forward the workflow's
            // cancel-callback so the Stop button propagates within
            // one syscall of the cancel.
            const deadline_ns: u64 = 30 * std.time.ns_per_s;
            const stdio_tools = fetchToolsFromServerStdio(allocator, server_name, server_obj, deadline_ns, cancel_fn) catch |err| {
                std.log.warn("Failed to fetch MCP tools from stdio server '{s}': {s}", .{ server_name, @errorName(err) });
                continue;
            };
            try all_tools.appendSlice(allocator, stdio_tools);
            continue;
        }

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

        // Fetch tools from this server via the new mcp_http client.
        // The HttpRegistry caches one HttpClient per server name; we
        // get a fresh list of tools for each buildMCPToolsRun call.
        const std_header_slice = blk: {
            var buf: [16]custom_http_client.Header = undefined;
            var count: usize = 0;
            for (headers.items) |h| {
                if (count >= buf.len) return error.TooManyHeaders;
                buf[count] = .{ .name = h.key, .value = h.value };
                count += 1;
            }
            break :blk buf[0..count];
        };
        const http_registry = mcp_http.HttpRegistry.global(allocator);
        const http_client = http_registry.getOrConnect(
            server_name,
            url,
            std_header_slice,
        ) catch |err| {
            std.log.warn("Failed to get HTTP client for MCP server {s}: {s}", .{ server_name, @errorName(err) });
            continue;
        };
        const mcp_tools = mcp_http.listTools(allocator, http_client) catch |err| {
            std.log.warn("Failed to fetch tools from MCP server {s}: {s}", .{ server_name, @errorName(err) });
            continue;
        };
        const tools = try convertMcpToolsToAgentTools(allocator, mcp_tools, server_name);
        try all_tools.appendSlice(allocator, tools);
    }

    return try all_tools.toOwnedSlice(allocator);
}

/// Convert []mcp_types.McpTool to []tool_models.AgentTool. Each tool's
/// inputSchema.properties JSON object is walked: each property's name,
/// type, and description are extracted into a `ToolProperty`. The
/// `required` field is mirrored from the JSON Schema's `required`
/// array. All allocations come from `allocator`; the caller owns
/// the returned slice.
fn convertMcpToolsToAgentTools(
    allocator: std.mem.Allocator,
    mcp_tools: []const mcp_types.McpTool,
    server_name: []const u8,
) ![]tool_models.AgentTool {
    var out: std.ArrayList(tool_models.AgentTool) = .empty;
    defer out.deinit(allocator);
    for (mcp_tools) |t| {
        // Build the AgentTool name as "mcp_<server>_<tool>" — matches
        // the stdio path so dispatch in handle_mcp_tool.zig can parse
        // it back out.
        const full_name = try std.fmt.allocPrint(allocator, "mcp_{s}_{s}", .{ server_name, t.name });

        // Walk the inputSchema.properties (a std.json.Value object)
        // and build a []ToolProperty. The JSON schema looks like:
        //   { "type": "object", "properties": { "name": { "type": "string", "description": "..." } } }
        var properties: std.ArrayList(tool_models.ToolProperty) = .empty;
        defer properties.deinit(allocator);
        var required: std.ArrayList([]const u8) = .empty;
        defer required.deinit(allocator);

        if (t.inputSchema.properties == .object) {
            var prop_it = t.inputSchema.properties.object.iterator();
            while (prop_it.next()) |kv| {
                const prop_name = kv.key_ptr.*;
                const prop_val = kv.value_ptr.*;
                const type_str: []const u8 = if (prop_val == .object)
                    if (prop_val.object.get("type")) |tv|
                        switch (tv) {
                            .string => |s| s,
                            else => "string",
                        }
                    else
                        "string"
                else
                    "string";
                const desc_str: []const u8 = if (prop_val == .object)
                    if (prop_val.object.get("description")) |dv|
                        switch (dv) {
                            .string => |s| s,
                            else => "",
                        }
                    else
                        ""
                else
                    "";
                try properties.append(allocator, .{
                    .name = try allocator.dupe(u8, prop_name),
                    .type = try allocator.dupe(u8, type_str),
                    .description = try allocator.dupe(u8, desc_str),
                });
            }
        }

        // The mcp_types.McpTool.inputSchema struct has a `required`
        // field — pull it if present. (We stored it as null in
        // mcp_http.zig's parseToolsList; the SDK doesn't always send
        // it. We look at the raw JSON via a re-parse for the
        // required field, but in v1 we just default to empty.)
        // TODO: parse required from the raw JSON in mcp_http.zig.

        out.append(allocator, .{
            .type = "function",
            .function = .{
                .name = full_name,
                .description = try allocator.dupe(u8, t.description),
                .parameters = .{
                    .type = "object",
                    .properties = try properties.toOwnedSlice(allocator),
                    .required = try required.toOwnedSlice(allocator),
                },
            },
        }) catch continue;
    }
    return out.toOwnedSlice(allocator);
}

/// Fetch tools from a single MCP server over the stdio transport.
/// Builds argv from `server_name`'s `command` + `args` config fields,
/// spawns (or reuses) a child via `mcp_stdio.StdioRegistry`, sends
/// `tools/list` JSON-RPC, parses `result.tools[]` into AgentTool
/// records (same wire shape as the HTTP branch).
///
/// `deadline_ns` is forwarded to both the send and the recv — a
/// hung child (pipe-buffer deadlock, awaits-init forever) returns
/// `MCPServerSendFailed` / `MCPServerRecvFailed` instead of blocking
/// the workflow start indefinitely. `cancel_fn` (optional) is
/// forwarded to the recv cancel-callback so the workflow's Stop
/// button propagates within one syscall.
fn fetchToolsFromServerStdio(
    allocator: std.mem.Allocator,
    server_name: []const u8,
    server_obj: std.json.ObjectMap,
    deadline_ns: u64,
    cancel_fn: ?*const fn () bool,
) ![]tool_models.AgentTool {
    // Build argv from the config.
    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(allocator);
    if (server_obj.get("command")) |cmd_field| {
        if (cmd_field == .string) {
            try argv_list.append(allocator, try allocator.dupe(u8, cmd_field.string));
        }
    }
    if (server_obj.get("args")) |args_v| {
        if (args_v == .array) {
            for (args_v.array.items) |item| {
                if (item == .string) {
                    try argv_list.append(allocator, try allocator.dupe(u8, item.string));
                }
            }
        }
    }
    if (argv_list.items.len == 0) return error.MCPServerCommandNotFound;
    const argv = try argv_list.toOwnedSlice(allocator);
    defer {
        for (argv) |a| allocator.free(a);
        allocator.free(argv);
    }

    const reg = mcp_stdio.StdioRegistry.global(allocator);
    const client = reg.getOrSpawn(server_name, argv) catch return error.MCPServerSpawnFailed;
    // No defer — the registry owns the client's lifecycle. Each call
    // reuses the same child; killing it on every fetch would be wasteful.
    // markStale on timeout: a hung child must NOT be returned to the
    // next caller. Self-healing happens at the registry boundary
    // (getOrSpawn checks the dirty flag on entry).
    errdefer reg.markStale(server_name);

    // Send tools/list and read the response.
    const req = try allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"tools/list\",\"params\":{}}");
    defer allocator.free(req);
    client.send(req, deadline_ns) catch return error.MCPServerSendFailed;
    const resp = client.recv(deadline_ns, cancel_fn) catch return error.MCPServerRecvFailed;
    defer allocator.free(resp);

    // Parse result.tools[] into AgentTool records (same parser the HTTP
    // branch uses after `body_to_parse` is read).
    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();
    const parsed = json.parseFromSlice(json.Value, parse_arena.allocator(), resp, .{
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .use_last,
    }) catch return error.MCPJSONParseError;

    const root = parsed.value;
    const result_value = root.object.get("result") orelse return error.MCPInvalidResponse;
    const tools_value = result_value.object.get("tools") orelse return error.MCPInvalidResponse;
    const tools_array = switch (tools_value) {
        .array => |a| a,
        else => return error.MCPInvalidResponse,
    };

    var agent_tools: std.ArrayList(tool_models.AgentTool) = .empty;
    defer agent_tools.deinit(allocator);
    for (tools_array.items) |tool_value| {
        const tool_obj: ?std.json.ObjectMap = switch (tool_value) {
            .object => |o| o,
            else => null,
        };
        const tool_obj_inner = tool_obj orelse continue;
        const name_value = tool_obj_inner.get("name") orelse continue;
        const name: []const u8 = switch (name_value) {
            .string => |s| s,
            else => continue,
        };
        const desc_value = tool_obj_inner.get("description") orelse continue;
        const description: []const u8 = switch (desc_value) {
            .string => |s| s,
            else => continue,
        };
        const schema_value = tool_obj_inner.get("inputSchema") orelse continue;
        const schema_obj: ?std.json.ObjectMap = switch (schema_value) {
            .object => |o| o,
            else => null,
        };
        const schema_obj_inner = schema_obj orelse continue;
        const props_value = schema_obj_inner.get("properties") orelse continue;
        const properties = try parseProperties(allocator, props_value, server_name);
        var required: []const []const u8 = &[_][]const u8{};
        if (schema_obj_inner.get("required")) |req_value| {
            const req_array: ?[]const json.Value = switch (req_value) {
                .array => |a| a.items,
                else => null,
            };
            if (req_array) |items| {
                var req_list: std.ArrayList([]const u8) = .empty;
                defer req_list.deinit(allocator);
                for (items) |req_item| {
                    const req_str: []const u8 = switch (req_item) {
                        .string => |x| x,
                        else => continue,
                    };
                    try req_list.append(allocator, try allocator.dupe(u8, req_str));
                }
                required = try req_list.toOwnedSlice(allocator);
            }
        }
        const agent_tool = tool_models.AgentTool{
            .type = "function",
            .function = tool_models.AgentToolFunction{
                .name = try std.fmt.allocPrint(allocator, "mcp_{s}_{s}", .{ server_name, name }),
                .description = try allocator.dupe(u8, description),
                .parameters = tool_models.ToolParameters{
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
        if (header_count >= header_buf.len) return error.TooManyHeaders;
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
    var row_buf = std.ArrayList(SubAgentListingRow).empty;
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
    try appendSubAgentsListing(allocator, &listing, row_buf.items);
    return try listing.toOwnedSlice(allocator);
}

// Cap for how many design pages to enumerate in the Design Canvas status
// prompt. Pages beyond the cap are listed as a count footer. Small enough
// to keep the prompt compact, large enough to cover most multi-page designs.
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

// =============================================================================
// Moved from src/modules/agent/prompts.zig on 2026-08-23
// (plan: docs/superpowers/plans/2026-08-23-move-build-agent-prompt-body.md).
// The orchestrator-side prompt-assembly file now owns `build_agent_prompt`
// and every helper it depends on; `prompts.zig` shrinks to a thin re-export
// of static template constants only. See the plan §4.2 for rationale.
// =============================================================================

/// Get the current operating system as a human-readable string
fn getCurrentOs() []const u8 {
    return switch (builtin.os.tag) {
        .linux => "Linux",
        .macos => "macOS",
        .windows => "Windows",
        .freebsd => "FreeBSD",
        .netbsd => "NetBSD",
        .openbsd => "OpenBSD",
        .dragonfly => "DragonFly",
        .ios => "iOS",
        else => @tagName(builtin.os.tag),
    };
}

// =============================================================================
// PROMPT BUILDERS
// =============================================================================

/// Append a section to the result with a leading "\n\n" separator.
/// Skips empty sections.
const appendSection = struct {
    fn func(a: std.mem.Allocator, r: *std.ArrayList(u8), section: []const u8) !void {
        if (section.len > 0) {
            try r.appendSlice(a, "\n\n");
            try r.appendSlice(a, section);
        }
    }
}.func;

/// A single prompt section in the main agent's system prompt.
///
/// `requires_tool` is an optional gate: if set, the section is only rendered
/// when a tool with that exact name is present in the runtime tool list.
/// This lets us ship section content (e.g. `set_agent_properties` guide)
/// without making it visible to agents that lack the tool.
const PromptSection = struct {
    name: []const u8,
    content: []const u8,
    requires_tool: ?[]const u8 = null,
};

/// Single source of truth for which prompt sections the main agent receives.
///
/// Order is meaningful: prompts earlier in the array are read first by the
/// model. The narrative is intentionally structured as:
///   1. LEAD — Orchestrator narrative (Philosophy B: spawn, delegate, orchestrate)
///   2. Skills system (so the agent knows about skills before being told workflows)
///   3. Tooling & research (how to use the tools)
///   4. Workflow (classify → plan → execute → escalate)
///   5. SECONDARY — "When you do work yourself" (Philosophy A: careful, surgical)
///   6. Memory & docs (project state)
///   7. Response formatting (applies to everything above)
///
/// To add/remove/reorder a section, edit this list — that's the only place
/// that needs to change. (For "I want the DynamicProperties section back
/// unconditionally" → just remove the `requires_tool` field.)
const PROMPT_SECTIONS: []const PromptSection = &.{
    .{ .name = "universal_rules", .content = prompts_const.UniversalRules },
    .{ .name = "search_tool_rule", .content = prompts_const.SearchToolRule },
    .{ .name = "memory_tool_rule", .content = prompts_const.MemoryToolRule, .requires_tool = "load_memory" },
    .{ .name = "agent_directive", .content = prompts_const.Agent },
    .{ .name = "git_prompt", .content = prompts_const.GitPrompt },
    .{ .name = "response_formatting", .content = prompts_const.ResponseFormatting },
    .{
        .name = "task_planning",
        .content =
        \\## Task Planning
        \\
        \\For multi-step work, lay out a structured plan early with the `update_plan` tool, then
        \\keep it in sync by calling `update_plan` after completing each checklist item (flip
        \\`- [ ]` → `- [x]`). The plan is automatically re-injected into your system prompt on
        \\every iteration, so you always see the current state. Use `get_plan` to verify the
        \\current state explicitly.
        \\
        ,
        .requires_tool = "update_plan",
    },
    .{ .name = "update_activity", .content = prompts_const.UpdateActivityRule },
};

/// Check if a tool with the given name is present in the runtime tool list.
fn hasTool(tools: []const tool_models.AgentTool, name: []const u8) bool {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.function.name, name)) return true;
    }
    return false;
}

/// Load the contents of all memory files in `~/.config/nalar/memories/` and
/// concatenate them as a single markdown blob. Each file is prefixed with a
/// `### <title>` heading derived from `MemoryInfo.title`.
///
/// Returns an empty string (allocated) when:
///   - environment is null
///   - the memories folder does not exist
///   - no `.md` files exist
///
/// **No cap — neither aggregate nor per-file.** Every memory that the
/// `listAllMemories` walk discovers is loaded in full. The de facto limit
/// is the LLM's context window (e.g. 200K tokens for the default model) —
/// if total memory content exceeds that, the LLM call will fail and the
/// user must trim. We trust users to keep their memories reasonable in
/// size.
// `pub` so the unit test in `prompts_test.zig` can call it directly. The
// function is still internal to the codebase — no external caller in
// the codebase imports it. Visibility widening is the standard Zig
// testability pattern for private helpers.
pub fn loadGlobalKnowledge(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: ?*const std.process.Environ.Map,
) ![]u8 {
    const env = environment orelse return allocator.dupe(u8, "");

    const list = tool_memories_mod.listAllMemories(allocator, io, env);
    defer tool_memories_mod.freeMemoriesList(allocator, list);

    if (list.len == 0) return allocator.dupe(u8, "");

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    for (list) |mem| {
        // Read the full file — no per-file cap. Pattern matches read_file.zig
        // and get_skill.zig which also use maxInt(usize) to mean "read all".
        const content = std.Io.Dir.cwd().readFileAlloc(
            io,
            mem.path,
            allocator,
            std.Io.Limit.limited(std.math.maxInt(usize)),
        ) catch continue;
        defer allocator.free(content);

        try result.appendSlice(allocator, "### ");
        try result.appendSlice(allocator, mem.title);
        try result.appendSlice(allocator, " (`");
        try result.appendSlice(allocator, mem.name);
        try result.appendSlice(allocator, "`)\n\n");
        // Emit the absolute path as a separate code-span line right below
        // the heading so the agent can copy it verbatim into `read_file`,
        // `write_file`, `text_replace`, or `remove_file` without
        // reconstructing it from the basename. Mirrors how
        // `appendSkillsListing` emits `s.path` for each skill.
        try result.appendSlice(allocator, "`");
        try result.appendSlice(allocator, mem.path);
        try result.appendSlice(allocator, "`\n\n");
        try result.appendSlice(allocator, content);
        try result.appendSlice(allocator, "\n\n");
    }

    return result.toOwnedSlice(allocator);
}

/// Load the contents of all memory files in `<cwd>/.nalar/memories/` and
/// concatenate them as a single markdown blob. Mirrors `loadGlobalKnowledge`
/// in shape, error handling, and output format (`### <title> (\`<name>\`)`)
/// so the rendered prompt has visual consistency across both knowledge
/// tiers.
///
/// Returns an empty string (allocated) when:
///   - `cwd` is empty
///   - `<cwd>/.nalar/memories/` does not exist (first-run case)
///   - the directory exists but contains no `.md` files
///
/// Per-file errors (open, read, title extraction) skip the file and
/// continue — never break the prompt. **No cap** on aggregate or per-file
/// size; mirrors `loadGlobalKnowledge`'s trust-the-user policy.
// `pub` so the unit test in `prompts_test.zig` can call it directly.
// Mirrors the `pub` decision on `loadGlobalKnowledge` above.
pub fn loadLocalKnowledge(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
) ![]u8 {
    if (cwd.len == 0) return allocator.dupe(u8, "");

    const dir_path = tool_memories_mod.get_local_memories_path_for_dir(allocator, cwd) orelse return allocator.dupe(u8, "");
    defer allocator.free(dir_path);

    const list = tool_memories_mod.listMemoriesInDir(allocator, io, dir_path);
    defer tool_memories_mod.freeMemoriesList(allocator, list);

    if (list.len == 0) return allocator.dupe(u8, "");

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    for (list) |mem| {
        const content = std.Io.Dir.cwd().readFileAlloc(
            io,
            mem.path,
            allocator,
            std.Io.Limit.limited(std.math.maxInt(usize)),
        ) catch continue;
        defer allocator.free(content);

        try result.appendSlice(allocator, "### ");
        try result.appendSlice(allocator, mem.title);
        try result.appendSlice(allocator, " (`");
        try result.appendSlice(allocator, mem.name);
        try result.appendSlice(allocator, "`)\n\n");
        // Emit the absolute path as a separate code-span line right below
        // the heading so the agent can copy it verbatim into `read_file`,
        // `write_file`, `text_replace`, or `remove_file` without
        // reconstructing it from the basename. Mirrors how
        // `appendSkillsListing` emits `s.path` for each skill and how
        // `loadGlobalKnowledge` does it above.
        try result.appendSlice(allocator, "`");
        try result.appendSlice(allocator, mem.path);
        try result.appendSlice(allocator, "`\n\n");
        try result.appendSlice(allocator, content);
        try result.appendSlice(allocator, "\n\n");
    }

    return result.toOwnedSlice(allocator);
}

/// Build main agent prompt with all components combined.
///
/// Prompt construction is data-driven via `PROMPT_SECTIONS`. To change
/// what the agent sees, edit that list — don't touch this function.
///
/// Sections are rendered in declaration order. Each section may be
/// conditionally gated on a tool being present (`requires_tool`).
///
/// After the static sections, the function appends dynamic session state:
/// loaded skills, project memory, global knowledge (memories from
/// `~/.config/nalar/memories/`), tool listing, active agent configuration,
/// working directory, workspace context, OS info, background processes,
/// and active workers.
///
/// **Removed parameters (vs. previous version):**
///   - `io: std.Io` — never used; callers no longer need to thread an `io` instance.
///   - `treeDir: []const u8` — was a dead parameter (caller always passed `""`).
/// **Renamed parameters:**
///   - `agent` → `activeAgentContent` (avoids shadowing the `agents` namespace).
/// **New parameters:**
///   - `io: std.Io` — required to read memory files for the auto-loaded
///     "Global Knowledge" section.
///   - `environment: ?*const std.process.Environ.Map` — required to resolve
///     the global memories path (XDG-aware: $XDG_CONFIG_HOME or $HOME).
///     When null, the Global Knowledge section is omitted.
///   - `workspaceContext: []const u8` — pre-rendered "Workspace Context"
///     block (built by `BuildWorkspaceContext` in this file).
///     Empty string means "session not bound to any workspace task" (section
///     is silently omitted). Rendered between the cwd line and the OS info.
pub fn build_agent_prompt(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    usedSkills: []const u8,
    memoryMd: []const u8,
    backgroundProcessContent: []const u8,
    activeAgentContent: []const u8,
    tools: []const tool_models.AgentTool,
    activity_info: []const u8,
    environment: ?*const std.process.Environ.Map,
    sub_agents_listing: []const u8,
    workspaceContext: []const u8,
    kanbanStatusContent: []const u8,
    designStatusContent: []const u8,
) ![]const u8 {
    _ = usedSkills;
    _ = backgroundProcessContent;
    _ = activeAgentContent;
    _ = activity_info;
    _ = sub_agents_listing;

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    for (PROMPT_SECTIONS) |section| {
        if (section.requires_tool) |tool_name| {
            if (!hasTool(tools, tool_name)) continue;
        }
        try appendSection(allocator, &result, section.content);
    }

    // Project memory (NALAR.md / CLAUDE.md from cwd).
    if (memoryMd.len > 0) {
        try appendSection(allocator, &result, memoryMd);
    }

    // Local Knowledge — auto-loaded from <cwd>/.nalar/memories/*.md.
    // Project-specific memories that ship with the codebase. Renders
    // BEFORE Global Knowledge so project context precedes cross-project
    // context ("most specific first" ordering).
    const local_knowledge = try loadLocalKnowledge(allocator, io, cwd);
    defer allocator.free(local_knowledge);
    if (local_knowledge.len > 0) {
        try result.appendSlice(allocator, "\n\n## Local Knowledge\n\n");
        try result.appendSlice(allocator,
            \\The following markdown files are this project's local memory,
            \\auto-loaded from `<cwd>/.nalar/memories/`. Use `read_file` to
            \\load a specific memory on demand. To update, use `write_file`
            \\or `text_replace`; to delete, use `remove_file`.
            \\
        );
        try result.appendSlice(allocator, local_knowledge);
    }

    const knowledge = try loadGlobalKnowledge(allocator, io, environment);
    defer allocator.free(knowledge);
    if (knowledge.len > 0) {
        try result.appendSlice(allocator, "\n\n## Global Knowledge\n\n");
        try result.appendSlice(allocator,
            \\The following markdown files are your persistent global memory,
            \\auto-loaded from `~/.config/nalar/memories/`. Use `list_memory` to
            \\see metadata (and any files truncated below the budget).
        );
        try result.appendSlice(allocator, knowledge);
    }

    // Working directory.
    if (cwd.len > 0) {
        try result.appendSlice(allocator, "\n\n**Current working directory:** ");
        try result.appendSlice(allocator, cwd);
    }

    if (workspaceContext.len > 0) {
        try result.appendSlice(allocator, workspaceContext);
    }

    if (kanbanStatusContent.len > 0) {
        try result.appendSlice(allocator, kanbanStatusContent);
    }

    if (designStatusContent.len > 0) {
        try result.appendSlice(allocator, designStatusContent);
    }

    // OS info.
    const os_name = getCurrentOs();
    try result.appendSlice(allocator, "\n\n**Operating System:** ");
    try result.appendSlice(allocator, os_name);
    try result.appendSlice(allocator,
        \\**Important:** Always use OS-specific commands. Check the current OS
        \\before running system commands or shell scripts.
    );

    return result.toOwnedSlice(allocator);
}

/// Append a tool listing to the result ArrayList.
///
/// Renders each tool's name and description so the model has semantic
/// context for tool selection — not just the JSON schema that the API
/// already sends in the request body. This is the single highest-leverage
/// piece of prompt content for tool-use accuracy: without it, the model
/// picks tools based on name-embedding similarity alone, which is unreliable
/// when tool names are short or ambiguous (e.g. `read_file` vs `text_replace`).
fn appendToolListing(allocator: std.mem.Allocator, result: *std.ArrayList(u8), tools: []const tool_models.AgentTool) !void {
    if (tools.len == 0) return;

    const header = "\n\n## Available Tools\n\nUse these exact tool names in your tool_calls:\n\n";
    try result.appendSlice(allocator, header);

    for (tools) |tool| {
        const name = tool.function.name;
        const desc = tool.function.description;

        // Guard against corrupted/uninitialized slices.
        if (name.len == 0) continue;
        if (desc.len == 0) continue;

        try result.appendSlice(allocator, "- **");
        try result.appendSlice(allocator, name);
        try result.appendSlice(allocator, "**: ");
        try result.appendSlice(allocator, desc);
        try result.appendSlice(allocator, "\n");
    }
}

/// Get the behavioral prompt for a tool directly from its own
/// `AgentTool.function.system_prompt` field — no hardcoded name mapping.
/// Each tool file sets `.system_prompt = <tool>_system_prompt` in its
/// `AgentTool` definition, so the prompt travels with `filtered_tools`
/// and is read here via `tool.function.system_prompt`.
fn toolBehaviorFromTool(tool: tool_models.AgentTool) ?[]const u8 {
    const prompt = tool.function.system_prompt;
    if (prompt.len > 0) return prompt;
    // Dynamic MCP tools are named mcp_<server>_<tool> — they are not in the
    // static registry but are still callable. Provide a generic behavior.
    if (std.mem.startsWith(u8, tool.function.name, "mcp_")) return "MCP tool from an external server. Call it with the parameters defined in its JSON schema. The server is already connected; just invoke the tool.";
    return null;
}

/// Append a behavioral tool section to the result ArrayList.
///
/// Unlike appendToolListing (which copies tool.description), this renders
/// *how to behave* with each tool. The LLM already receives the JSON schema
/// via the API; this prompt tells it when and how to use each tool.
fn appendToolBehaviorSection(allocator: std.mem.Allocator, result: *std.ArrayList(u8), tools: []const tool_models.AgentTool) !void {
    if (tools.len == 0) return;

    // Count how many tools have a known behavior — skip the section if none.
    var known_count: usize = 0;
    for (tools) |tool| {
        if (toolBehaviorFromTool(tool) != null) known_count += 1;
    }
    if (known_count == 0) return;

    try result.appendSlice(allocator, "\n\n## Tool Behaviors\n\n");
    try result.appendSlice(allocator, "You have access to the following tools. Use them according to these behaviors:\n\n");

    for (tools) |tool| {
        const name = tool.function.name;
        if (name.len == 0) continue;
        const behavior = toolBehaviorFromTool(tool) orelse continue;
        try result.appendSlice(allocator, "- **");
        try result.appendSlice(allocator, name);
        try result.appendSlice(allocator, "**: ");
        try result.appendSlice(allocator, behavior);
        try result.appendSlice(allocator, "\n");
    }
}

/// Append a "## Available Skills" section listing every installed skill
/// (global + local) by name and description. Mirrors `appendToolListing`'s
/// bullet-list style for visual consistency.
///
/// Behavior:
///   - **Gated on `list_skills` tool** — if the tool isn't in the runtime
///     tool list, the model has no way to refresh the list anyway, so we
///     skip the section. Matches the `requires_tool` pattern used by the
///     static `SkillsUsage` / `SkillsTriggers` sections.
///   - **Best-effort** — any failure inside `listAllSkills` (missing env,
///     IO error, alloc failure) silently omits the section, matching the
///     graceful-degradation spirit of `loadGlobalKnowledge` above.
///   - **Empty case omitted** — if both lists are empty, the section header
///     is not emitted at all (avoids an empty `## Available Skills` block).
///   - **Empty `cwd`** is mapped to `null` so the local lookup falls back to
///     `io`'s cwd instead of resolving a path for the filesystem root.
fn appendSkillsListing(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    tools: []const tool_models.AgentTool,
    cwd: []const u8,
    io: std.Io,
    environment: ?*const std.process.Environ.Map,
) !void {
    if (!hasTool(tools, "list_skills")) return;

    const cwd_param: ?[]const u8 = if (cwd.len > 0) cwd else null;

    const data = tool_list_skills_mod.listAllSkills(allocator, io, cwd_param, environment) catch return;
    defer tool_list_skills_mod.freeSkillsListData(allocator, data);

    if (data.global_skills.len == 0 and data.local_skills.len == 0) return;

    try result.appendSlice(allocator, "\n\n## Available Skills\n\n");
    try result.appendSlice(allocator,
        \\The following skills are installed and available for this session.
        \\Use `list_skills` to refresh this view, or `get_skill` / `view_skill`
        \\to load a skill's full instructions. Each entry includes the
        \\**exact file path** — pass it to `get_skill` verbatim as the `path`
        \\argument. Do NOT construct the path from the skill name: Linux is
        \\case-sensitive and the file lives at `<name>/SKILL.MD`, not
        \\`<name>.md`, and `~` is not expanded by the tool.
        \\
    );

    if (data.global_skills.len > 0) {
        try result.appendSlice(allocator, "\n### Global skills (~/.config/nalar/skills/)\n\n");
        for (data.global_skills) |s| {
            try result.appendSlice(allocator, "- **");
            try result.appendSlice(allocator, s.name);
            try result.appendSlice(allocator, "**: ");
            try result.appendSlice(allocator, s.description);
            try result.appendSlice(allocator, " — `");
            try result.appendSlice(allocator, s.path);
            try result.appendSlice(allocator, "`\n");
        }
    }

    if (data.local_skills.len > 0) {
        try result.appendSlice(allocator, "\n### Local skills (.nalar/skills/)\n\n");
        for (data.local_skills) |s| {
            try result.appendSlice(allocator, "- **");
            try result.appendSlice(allocator, s.name);
            try result.appendSlice(allocator, "**: ");
            try result.appendSlice(allocator, s.description);
            try result.appendSlice(allocator, " — `");
            try result.appendSlice(allocator, s.path);
            try result.appendSlice(allocator, "`\n");
        }
    }
}

// ---------------------------------------------------------------------------
// Available Sub-Agents listing
// ---------------------------------------------------------------------------

/// One row of the sub-agents listing. Borrowed slices from the
/// `SubAgentConfig` entry — they live as long as the parent
/// `LlmConfig`. Computed by the caller (typically
/// `buildMessages`); `appendSubAgentsListing` just renders the
/// rows passed to it.
pub const SubAgentListingRow = struct {
    name: []const u8,
    model: []const u8,
    /// First N chars of the sub-agent's `system_prompt`, used as
    /// a one-line description in the listing. Empty when the
    /// sub-agent has no system_prompt. Caller should pre-truncate
    /// (e.g. to 80 chars) to keep the prompt lean.
    description: []const u8,
    /// `""` for top-level, or the profile name when the row
    /// came from a profile's `sub_agents`. Used for the source
    /// suffix in the listing.
    source: []const u8,
};

/// Append a "## Available Sub-Agents" section to the result
/// ArrayList. Mirrors `appendToolListing` / `appendSkillsListing`
/// in shape (markdown bullet list with a header that gates on
/// `spawn_sub_agent` being present in the tool list — the section
/// is only useful when the LLM can actually call it).
///
/// Format:
/// ```
/// ## Available Sub-Agents
///
/// You can use `spawn_sub_agent` with one of these `agent_name` values:
///
/// - **code-reviewer** — model: `gpt-4o` — "You are a strict code reviewer..."
/// - **frontend-helper** — model: `claude-3.5-sonnet` — "You are a frontend..."
///
/// (Loaded from the `sub_agents` array in `~/.config/nalar/config.json`.
/// With a profile selected, the profile's sub_agents list is used;
/// otherwise the top-level list is used.)
/// ```
///
/// No-op when `rows.len == 0` so callers can pass an empty slice
/// to mean "no sub-agents configured" (matches the convention used
/// by `appendToolListing` for empty tool lists).
pub fn appendSubAgentsListing(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    rows: []const SubAgentListingRow,
) !void {
    if (rows.len == 0) return;

    try result.appendSlice(allocator,
        \\## Available Sub-Agents
        \\
        \\You can use the `spawn_sub_agent` tool with one of these
        \\`agent_name` values to delegate the task to a pre-configured
        \\specialized sub-agent:
        \\
    );

    for (rows) |row| {
        // Skip rows with empty name (defensive — should never
        // happen since the LlmConfig rejects empty names at
        // load time, but be tolerant).
        if (row.name.len == 0) continue;
        try result.appendSlice(allocator, "- **");
        try result.appendSlice(allocator, row.name);
        try result.appendSlice(allocator, "**");
        if (row.model.len > 0) {
            try result.appendSlice(allocator, " (model: `");
            try result.appendSlice(allocator, row.model);
            try result.appendSlice(allocator, "`)");
        }
        if (row.description.len > 0) {
            try result.appendSlice(allocator, " — \"");
            try result.appendSlice(allocator, row.description);
            try result.appendSlice(allocator, "\"");
        }
        if (row.source.len > 0) {
            try result.appendSlice(allocator, " _(from profile `");
            try result.appendSlice(allocator, row.source);
            try result.appendSlice(allocator, "`)_");
        }
        try result.appendSlice(allocator, "\n");
    }

    try result.appendSlice(allocator,
        \\
        \\Loaded from the `sub_agents` array in `~/.config/nalar/config.json`.
        \\With a profile selected, the profile's sub_agents list is
        \\used; otherwise the top-level list is used.
        \\
    );
}
