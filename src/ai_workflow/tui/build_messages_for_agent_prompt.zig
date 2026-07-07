const std = @import("std");
const json = std.json;
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const llm_history = @import("llm_history.zig");
const session_helpers = llm_history;
const sqlite = tree1_mod.sqlite;
const prompt = tree1_mod.prompt;
const TUIHistory = @import("models.zig").TUIHistory;
const transform_llm_history_to_agent_messages = @import("transform_llm_history_to_agent_messages.zig");
const tool_models = tree1_mod.tool_models;
const config_mod = tree1_mod.config;
const http_client = tree1_mod.http_client;
const background_process = @import("background_process.zig");
const ProcessInfo = background_process.ProcessInfo;
const inherited_context = @import("inherited_context.zig");
const kanban_model = @import("kanban_model.zig");
const design_model = @import("design_model.zig");

const AgentTool = tool_models.AgentTool;
const AgentToolFunction = tool_models.AgentToolFunction;
const ToolParameters = tool_models.ToolParameters;
const ToolProperty = tool_models.ToolProperty;

pub fn buildMessages(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    cwd: []const u8,
    session_id: []const u8,
    parent_session_id: []const u8,
    historyMessages: []TUIHistory,
    tools: []tool_models.AgentTool,
    inherited_context_mode: []const u8,
    /// Optional explicit "active agent configuration" to inject as
    /// the `## Your Active Agent Configuration` section of the
    /// system prompt. When non-empty, this is used verbatim and
    /// `BuildDynamicAgentContent` is NOT called. When empty (the
    /// default), the function falls back to
    /// `BuildDynamicAgentContent(db, session_id)` to read the list
    /// of agents loaded via `change_agent` for this session.
    ///
    /// Use cases:
    ///   - Main agent flow: caller passes `""` to use the
    ///     `session_agents` table contents.
    ///   - Sub-agent flow with a config-driven system_prompt:
    ///     caller passes the resolved `SubAgentConfig.system_prompt`
    ///     and it appears as the sub-agent's "active configuration".
    ///   - Sub-agent flow with random fallback: caller passes `""`
    ///     so the sub-agent gets the default scaffold with no
    ///     specialized configuration.
    activeAgentContent: []const u8,
) ![]agent.AgentMessage {
    // Build content strings internally
    const skills = try BuildSkillContent(allocator, db, session_id);
    defer allocator.free(skills);

    const memoryMd = try BuildMemoryForAgent(allocator, io, cwd);
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
    const activity_info = try buildActivityInfo(allocator, io, db, session_id);
    defer allocator.free(activity_info);

    // Resolve environment for the Global Knowledge loader. The singleton
    // is the single source of truth for the process-level environment map.
    const di = try tree1_mod.getSingleton();
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
    const workspaceContext = try BuildWorkspaceContext(allocator, db, session_id);
    defer allocator.free(workspaceContext);

    // Build the "Kanban Status Tracking" section. Only rendered when
    // the session's parent item has item_type === 'kanban' (the
    // helper silently returns "" otherwise). Rendered right after
    // the Workspace Context section so the agent sees the workflow
    // expectations before the tool listing.
    const kanbanStatusContent = try BuildKanbanStatusPrompt(allocator, db, session_id);
    defer allocator.free(kanbanStatusContent);

    // Design canvas status — mirrors the kanban block above. Renders
    // a `## Design Canvas` section when the parent item_type is
    // `design`, listing the existing pages and reminding the agent
    // about the 3 design tools (`set_design_page`,
    // `delete_design_page`, `list_design_pages`). Returns `""` when
    // the session is not on a design canvas (same graceful-skip
    // pattern as `kanbanStatusContent` when empty).
    const designStatusContent = try BuildDesignCanvasPrompt(allocator, db, session_id);
    defer allocator.free(designStatusContent);

    const systemContent = try prompt.build_agent_prompt(allocator, io, cwd, skills, memoryMd, backgroundProcessmessage, agentUsed, tools, activity_info, environment, sub_agents_listing, workspaceContext, kanbanStatusContent, designStatusContent);

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
        const agentMsgs = try transform_llm_history_to_agent_messages.transform_llm_history_to_agent_message(allocator, hist);
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

/// Build skills content string from database for persistence
pub fn BuildSkillContent(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]const u8 {
    if (session_id.len == 0) {
        return allocator.dupe(u8, "");
    }

    var skillsBuilder: std.ArrayList(u8) = .empty;
    errdefer skillsBuilder.deinit(allocator);

    const sql = "SELECT skill_name, content FROM session_skills WHERE session_id = ?";
    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    var hasSkills = false;
    while (try rows.next()) |row| {
        hasSkills = true;
        const skill_name = row.values[0];
        const content = row.values[1];
        try skillsBuilder.appendSlice(allocator, "### ");
        try skillsBuilder.appendSlice(allocator, skill_name);
        try skillsBuilder.appendSlice(allocator, "\n\n");
        try skillsBuilder.appendSlice(allocator, content);
        try skillsBuilder.appendSlice(allocator, "\n\n");
        row.deinit(allocator);
    }

    if (!hasSkills) {
        return allocator.dupe(u8, "");
    }

    // Prepend the header to the existing content
    const header = "\n\n## Loaded Skills\n\n";
    const result = try allocator.alloc(u8, header.len + skillsBuilder.items.len);
    @memcpy(result[0..header.len], header);
    @memcpy(result[header.len..], skillsBuilder.items);
    return result;
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

    var parse_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
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

const memory_files = [_][]const u8{ "NALAR.md", "CLAUDE.md" };

pub fn BuildMemoryForAgent(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    const effective_cwd = if (cwd.len == 0) "." else cwd;
    const absolute_cwd = if (std.fs.path.isAbsolute(effective_cwd))
        try allocator.dupe(u8, effective_cwd)
    else
        try std.Io.Dir.cwd().realPathFileAlloc(io, effective_cwd, allocator);
    defer allocator.free(absolute_cwd);

    for (memory_files) |filename| {
        const file_path = try std.fs.path.join(allocator, &[_][]const u8{ absolute_cwd, filename });
        defer allocator.free(file_path);

        const file = std.Io.Dir.openFileAbsolute(io, file_path, .{
            .mode = .read_write,
        }) catch |err| {
            if (err == error.FileNotFound) {
                const new_file = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
                std.Io.File.close(new_file, io);
                continue;
            }
            return err;
        };
        defer std.Io.File.close(file, io);

        const content = try std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, std.Io.Limit.limited(std.math.maxInt(usize)));
        defer allocator.free(content);

        try result.appendSlice(allocator, content);

        if (content.len > 0 and content[content.len - 1] != '\n') {
            try result.append(allocator, '\n');
        }
    }

    return try result.toOwnedSlice(allocator);
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

/// Max pages to inline in the `## Design Canvas` status block.
/// Mirrors `MAX_KANBAN_COLUMNS` — a typical design canvas has 1–5
/// pages (login, dashboard, settings, etc.) so 10 is well above
/// any realistic design item.
const MAX_DESIGN_PAGES: u32 = 10;

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
    const di = tree1_mod.getSingleton() catch return allocator.dupe(u8, "");
    const config = tree1_mod.getLlmConfig(di);

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

/// Build a "## Workspace Context" section listing the workspace items
/// and tasks in the same workspace as the current task. Returns `""`
/// when the session is not bound to any workspace_item_task (caller
/// omits the section silently — matches `appendSkillsListing` behavior).
///
/// Cap: 20 items (siblings), 5 tasks per item. When exceeded, the
/// `… and N more` footer is rendered.
///
/// The block has this shape (omitted when empty):
///
/// ```markdown
/// ## Workspace Context
///
/// This task is part of workspace `<workspace_id>`. Sibling items
/// (same workspace, listed for discovery):
///
/// - **<name>** (item_type: `<type>`, path: `<path>`) *(this task)*
///   - task: `<task_name>` (type: standard|routine, session: `<sid>`)
///   - ...
/// - **<name>** (item_type: `<type>`, path: `<path>`)
///   - task: `<task_name>` ...
///
/// … and N more items in this workspace.
/// ```
///
/// Inserted into the system prompt right after the
/// `**Current working directory:**` line. See Chunk 3 for wiring.
pub fn BuildWorkspaceContext(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]const u8 {
    if (session_id.len == 0) return allocator.dupe(u8, "");

    const ctx = (llm_history.getWorkspaceContext(allocator, db, session_id) catch |err| {
        std.log.warn("BuildWorkspaceContext: lookup failed: {}", .{err});
        return allocator.dupe(u8, "");
    }) orelse return allocator.dupe(u8, "");
    defer ctx.deinit(allocator);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "\n\n## Workspace Context\n\n");
    try out.appendSlice(allocator, "This task is part of workspace `");
    try out.appendSlice(allocator, ctx.workspace_id);
    try out.appendSlice(allocator,
        \\`. The other items in this workspace are listed below for
        \\discovery — you can read or reference their files via `bash`,
        \\`read_file`, etc. by using the `path` shown for each item.
        \\
        \\The item marked *(this task)* is the one your session is bound
        \\to. Sibling items may be running other conversations; treat
        \\their files as a shared workspace, not as something to modify
        \\without the user asking.
        \\
    );

    if (ctx.self_path) |p| {
        try out.appendSlice(allocator, "**Your task's working directory (cwd hint):** `");
        try out.appendSlice(allocator, p);
        try out.appendSlice(allocator, "`\n\n");
    } else {
        try out.appendSlice(allocator,
            \\**Your task's working directory:** (none recorded)
            \\
        );
    }

    for (ctx.siblings) |sib| {
        // "- **<name>** (item_id: `<id>`, item_type: `<type>`, path: `<path>`)"
        //
        // The item_id is the **canonical** lookup key for workspace-scoped
        // tools (`kanban_list`, `kanban_move_task`, etc.). The name is
        // for human display; the LLM cannot call the tools with the
        // name and get correct results (the DB columns are indexed by
        // id, not name). The label is `item_id:` (not `id:`) so it cannot
        // be confused with the `task_id:` label on the tasks listed
        // below — see Chunk 1 of the 2026-06-26 plan for the validation
        // that depends on this distinction.
        try out.appendSlice(allocator, "- **");
        if (sib.name) |n| {
            try out.appendSlice(allocator, n);
        } else {
            try out.appendSlice(allocator, sib.id);
        }
        try out.appendSlice(allocator, "** (item_id: `");
        try out.appendSlice(allocator, sib.id);
        try out.appendSlice(allocator, "`, item_type: `");
        try out.appendSlice(allocator, sib.item_type);
        try out.appendSlice(allocator, "`, path: `");
        if (sib.path) |p| {
            try out.appendSlice(allocator, p);
        } else {
            try out.appendSlice(allocator, "(none)");
        }
        try out.appendSlice(allocator, "`)");
        if (sib.is_self) try out.appendSlice(allocator, " *(this task)*");
        try out.appendSlice(allocator, "\n");

        for (sib.tasks) |t| {
            try out.appendSlice(allocator, "  - task: `");
            try out.appendSlice(allocator, t.name);
            try out.appendSlice(allocator, "` (task_id: `");
            try out.appendSlice(allocator, t.id);
            try out.appendSlice(allocator, "`, type: ");
            try out.appendSlice(allocator, t.task_type);
            // The `session_id` field was dropped in Migration 052 —
            // a task's own `id` IS the session id per the
            // `task.id == session_id` convention. The Workspace
            // Context section's anchor uses `t.id = ?` so the
            // sibling listing naturally finds the chat session.
            try out.appendSlice(allocator, ")\n");
        }

        if (sib.truncated_tasks_count > 0) {
            const footer = try std.fmt.allocPrint(allocator,
                "    … and {d} more task{s} under this item\n",
                .{ sib.truncated_tasks_count, if (sib.truncated_tasks_count == 1) "" else "s" },
            );
            defer allocator.free(footer);
            try out.appendSlice(allocator, footer);
        }
    }

    if (ctx.truncated_items_count > 0) {
        const footer = try std.fmt.allocPrint(allocator,
            "\n… and {d} more item{s} in this workspace (cap: {d} shown).\n",
            .{ ctx.truncated_items_count, if (ctx.truncated_items_count == 1) "" else "s", llm_history.MAX_SIBLING_ITEMS },
        );
        defer allocator.free(footer);
        try out.appendSlice(allocator, footer);
    }

    return out.toOwnedSlice(allocator);
}

/// Build a "## Kanban Status Tracking" section that instructs the
/// agent to call `kanban_move_task` at every meaningful workflow
/// checkpoint (start, milestone, complete, blocked). The section is
/// rendered only when the session's parent item has
/// `item_type === 'kanban'`; otherwise returns `""` (silently
/// omitted, matching `BuildWorkspaceContext`'s empty-case behavior).
///
/// Re-uses the `getWorkspaceContext` anchor to avoid a second
/// round-trip — the parent item_type is already read there. The
/// helper:
///   1. Resolves the anchor (task → item → workspace) via
///      `getWorkspaceContext` and reads `ctx.self_item_type`.
///   2. Bails out if the parent is not a kanban.
///   3. Reads the columns via `kanban_model.listColumns` (cap: 10).
///   4. Reads the task's current `kanban_column_id` via a single
///      `SELECT` (the column id may be NULL when unassigned).
///   5. Renders the section.
///
/// Block shape (omitted when parent is not a kanban, or session is
/// not bound to any task):
///
/// ```markdown
/// ## Kanban Status Tracking
///
/// This task is on a kanban board (parent item_type: `kanban`). **You MUST
/// call `kanban_move_task` at every meaningful workflow checkpoint.**
/// The tool description (in the tool listing) shows the exact argument shape.
///
/// **Current column:** `<col_name>` (`<col_id>`)
///
/// **Columns on this board** (in flow order):
/// - `<name>` (`<id>`) — position 0
/// - `<name>` (`<id>`) — position 1
/// - ...
///
/// **Status transitions:**
/// - **start**: move from `<first_column>` → `<second_column>` (or
///   whatever the user-defined "in progress" column is) at the
///   first user-visible action in this session.
/// - **milestone**: stay in the current column; mention the milestone
///   in your reply so the user sees progress.
/// - **complete**: move to `<last_column>` (typically `done`) before
///   your final reply. This is the most-skipped transition.
/// - **blocked**: do NOT move; explain the blocker in your reply and
///   let the user decide. The card stays where it is.
/// ```
pub fn BuildKanbanStatusPrompt(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]const u8 {
    if (session_id.len == 0) return allocator.dupe(u8, "");

    // 1. Re-use the workspace-context anchor to read the parent's
    //    item_type without a second JOIN. Bail out when the parent
    //    isn't a kanban.
    const ctx = (llm_history.getWorkspaceContext(allocator, db, session_id) catch |err| {
        std.log.warn("BuildKanbanStatusPrompt: getWorkspaceContext failed: {}", .{err});
        return allocator.dupe(u8, "");
    }) orelse return allocator.dupe(u8, "");
    defer ctx.deinit(allocator);

    if (!std.mem.eql(u8, ctx.self_item_type, "kanban")) {
        return allocator.dupe(u8, "");
    }

    // 2. Read the columns. Same graceful-skip pattern as
    //    BuildWorkspaceContext — any DB failure returns "".
    const cols = kanban_model.listColumns(allocator, db, ctx.self_item_id) catch |err| {
        std.log.warn("BuildKanbanStatusPrompt: listColumns failed: {}", .{err});
        return allocator.dupe(u8, "");
    };
    defer kanban_model.freeColumns(allocator, cols);

    // 3. Read the task's current kanban_column_id (may be NULL when
    //    unassigned). One-row query — task.id == session_id per the
    //    workspace-context convention.
    const current_column_id: ?[]const u8 = blk: {
        var q = try db.query(allocator,
            \\SELECT COALESCE(kanban_column_id, '')
            \\FROM workspace_item_tasks t
            \\WHERE t.id = ?
        , &.{session_id});
        defer q.deinit();
        const row = (try q.next()) orelse break :blk null;
        defer row.deinit(allocator);
        const cid = row.values[0];
        if (cid.len == 0) break :blk null;
        break :blk try allocator.dupe(u8, cid);
    };
    defer if (current_column_id) |c| allocator.free(c);

    // 4. Render the markdown block.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "\n\n## Kanban Status Tracking\n\n");
    try out.appendSlice(allocator,
        \\This task is on a kanban board (parent item_type: `kanban`).
        \\**You MUST call the `kanban_move_task` tool at every meaningful
        \\workflow checkpoint** below. The tool's argument shape is
        \\documented in the tool listing — pass `workspace_id` + `item_id`
        \\from the `## Workspace Context` section above, and `task_id` is
        \\your own session_id (per the `task.id == session_id` convention).
        \\
    );

    // 4a. Current column line.
    if (current_column_id) |cid| {
        const col_name = blk: {
            for (cols) |c| {
                if (std.mem.eql(u8, c.id, cid)) break :blk c.name;
            }
            break :blk "<unknown>";
        };
        try out.appendSlice(allocator, "**Current column:** `");
        try out.appendSlice(allocator, col_name);
        try out.appendSlice(allocator, "` (`");
        try out.appendSlice(allocator, cid);
        try out.appendSlice(allocator, "`)\n\n");
    } else {
        try out.appendSlice(allocator,
            \\**Current column:** _unassigned_ — the task has no column yet.
            \\Your first move will assign it.
            \\
        );
    }

    // 4b. Column listing (cap: 10, with footer).
    try out.appendSlice(allocator, "**Columns on this board** (in flow order):\n");
    if (cols.len == 0) {
        try out.appendSlice(allocator,
            \\_No columns configured yet._ Ask the user to add columns before
            \\moving the task.
            \\
        );
    } else {
        const shown = @min(cols.len, MAX_KANBAN_COLUMNS);
        for (cols[0..shown]) |c| {
            try out.appendSlice(allocator, "- `");
            try out.appendSlice(allocator, c.name);
            try out.appendSlice(allocator, "` (`");
            try out.appendSlice(allocator, c.id);
            const pos_str = try std.fmt.allocPrint(allocator, "`, position {d})\n", .{c.position});
            defer allocator.free(pos_str);
            try out.appendSlice(allocator, pos_str);

            // Inject the column's free-text description (Migration 053)
            // as an indented sub-line. Skip when empty so the prompt
            // stays quiet for un-described columns.
            if (c.description.len > 0) {
                try out.appendSlice(allocator, "  Description: ");
                try out.appendSlice(allocator, c.description);
                try out.appendSlice(allocator, "\n");
            }
        }
        if (cols.len > MAX_KANBAN_COLUMNS) {
            const footer = try std.fmt.allocPrint(allocator,
                "… and {d} more columns (cap: {d} shown).\n",
                .{ cols.len - MAX_KANBAN_COLUMNS, MAX_KANBAN_COLUMNS },
            );
            defer allocator.free(footer);
            try out.appendSlice(allocator, footer);
        }
    }

    // 4c. Status transitions.
    try out.appendSlice(allocator, "\n**Status transitions** (call `kanban_move_task`):\n");
    try out.appendSlice(allocator,
        \\
        \\- **start** — at the first user-visible action of this session, move the
        \\  task from the first column (`todo`) to the next column (`in progress`,
        \\  or whatever the user-defined "in progress" column is). Pass the
        \\  `target_column_id` from the listing above.
        \\- **milestone** — when you reach a meaningful progress milestone but are
        \\  not done, do NOT move; instead, mention the milestone in your reply
        \\  so the user sees progress without you skipping the "done" transition.
        \\- **complete** — before your final reply, move the task to the last
        \\  column (`done`, or whatever the user-defined "done" column is). This
        \\  is the most-skipped transition; do not skip it.
        \\- **blocked** — if you cannot make progress, do NOT move; explain the
        \\  blocker in your reply. The card stays where it is until the user
        \\  resolves the blocker or you find a way forward.
        \\
    );

    return out.toOwnedSlice(allocator);
}

/// Build the "Design Canvas" status block for the current session.
///
/// Mirrors `BuildKanbanStatusPrompt` — returns a heap-allocated
/// `## Design Canvas` markdown section when the parent item_type is
/// `design`, or `""` otherwise (the section is then silently omitted
/// by `build_agent_prompt`). The block tells the agent:
/// 1. That the task is on a design canvas (so it should use the
///    `set_design_page` / `list_design_pages` / `delete_design_page`
///    tools instead of `kanban_move_task` etc.).
/// 2. Which pages already exist (so it can `set_design_page` to
///    update one of them or pick an unused name for a new one).
/// 3. The page-name + HTML conventions (so the agent writes valid
///    full HTML documents, not fragments).
///
/// Returns `""` for the same "graceful skip" cases as
/// `BuildKanbanStatusPrompt`: empty session_id, getWorkspaceContext
/// failure / null result, parent isn't a design item, or any DB
/// failure on the page-listing query.
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

    // 2. Read the pages (position ASC = display order). Same
    //    graceful-skip pattern as `BuildKanbanStatusPrompt`'s
    //    `listColumns` call.
    const pages = design_model.listPages(allocator, db, ctx.self_item_id) catch |err| {
        std.log.warn("BuildDesignCanvasPrompt: listPages failed: {}", .{err});
        return allocator.dupe(u8, "");
    };
    defer design_model.freePageSummaries(allocator, pages);

    // 3. Render the markdown block.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "\n\n## Design Canvas\n\n");
    try out.appendSlice(allocator,
        \\This task is on a design canvas (parent item_type: `design`).
        \\**You MUST use the design canvas tools to author pages** — the
        \\canvas is **file-backed** (plan v5): each page is a folder at
        \\`<workspace_item.path>/.nalar/design/<page_name>/` and each
        \\element is an HTML file inside that folder. Pages are pure
        \\metadata containers (no html); elements carry the html on disk.
        \\
        \\**Workflow:**
        \\  1. `set_design_page(item_id, name)` — creates (or updates) the page metadata + folder.
        \\  2. `set_design_element(page_id, name, html, x, y, width, height, z_index)` — writes an element HTML file + positions it.
        \\  3. `move_design_element(element_id, x, y)` — low-latency drag update.
        \\  4. `list_design_elements(page_id)` — see current state.
        \\  5. `delete_design_element(element_id)` — remove + unlink the file.
        \\
        \\After the page exists, you can ALSO edit the html files directly with `write_file` / `read_file` / `text_replace` tools — the DB is just position metadata; the files are the source of truth for html.
        \\
    );

    // 3a. Page listing (cap: MAX_DESIGN_PAGES, with footer).
    try out.appendSlice(allocator, "**Pages on this canvas** (in display order):\n");
    if (pages.len == 0) {
        try out.appendSlice(allocator,
            \\_No pages yet._ The canvas is empty — your first `set_design_page`
            \\call will create the first page. Pick a clear name like `Login`,
            \\`Dashboard`, `Settings`, etc.
            \\
        );
    } else {
        const shown = @min(pages.len, MAX_DESIGN_PAGES);
        for (pages[0..shown]) |p| {
            try out.appendSlice(allocator, "- `");
            try out.appendSlice(allocator, p.name);
            try out.appendSlice(allocator, "` (`");
            try out.appendSlice(allocator, p.id);
            const pos_str = try std.fmt.allocPrint(allocator, "`, position {d})\n", .{p.position});
            defer allocator.free(pos_str);
            try out.appendSlice(allocator, pos_str);
        }
        if (pages.len > MAX_DESIGN_PAGES) {
            const footer = try std.fmt.allocPrint(allocator,
                "… and {d} more pages (cap: {d} shown).\n",
                .{ pages.len - MAX_DESIGN_PAGES, MAX_DESIGN_PAGES },
            );
            defer allocator.free(footer);
            try out.appendSlice(allocator, footer);
        }
    }

    // 3b. Page-authoring conventions (file-backed model).
    try out.appendSlice(allocator, "\n**Page authoring** (`set_design_page`):\n");
    try out.appendSlice(allocator,
        \\
        \\- **Pages have no html** — `set_design_page` only manages the page
        \\  metadata (name, width, height, x, y) and creates the
        \\  `<page_name>/` subdir. Use `set_design_element` to add positioned HTML.
        \\- **Idempotent overwrite** — re-issuing `set_design_page` with the same
        \\  `(item_id, name)` REPLACES the existing page's geometry in place. The
        \\  element rows + html files are NOT touched; only `width/height/x/y` change.
        \\- **No "move page" tool** — pages don't have a workflow like kanban columns.
        \\  The frontend tab strip exposes drag-to-reorder; for programmatic
        \\  re-ordering, delete + recreate (the new page is appended to the end).
        \\
    );

    // 3c. Element-authoring conventions.
    try out.appendSlice(allocator, "\n**Element authoring** (`set_design_element`):\n");
    try out.appendSlice(allocator,
        \\
        \\- **Each element is a positioned HTML file** at
        \\  `<workspace_item.path>/.nalar/design/<page_name>/<element_name>.html`.
        \\  Element `name` is sanitized for filesystem use (lowercase, slashes
        \\  → underscore, leading dots stripped, whitespace → dashes).
        \\- **`html` body** — full HTML document preferred (`<!doctype html>...</html>`),
        \\  but a fragment works too (the canvas wraps it). The file is the source
        \\  of truth — after writing, you can edit it directly with `write_file` /
        \\  `read_file` / `text_replace` tools, and other connected clients see the
        \\  update via SSE.
        \\- **Common patterns**:
        \\    - Background: `name="Background", x=0, y=0, width=<page.width>,
        \\      height=<page.height>, z_index=-1, html="<div style='background:<color>;
        \\      width:100%; height:100%'></div>"`
        \\    - Phone mockup: `name="Phone mockup", width=375, height=667, html=...`
        \\    - Hero card: `name="Hero card", width=375, height=250, html=...`
        \\- **`z_index` draws order** — higher = on top. Use `-1` for background.
        \\- **Drag-to-move** — `move_design_element(element_id, x, y)` updates x/y
        \\  in the DB without rewriting the html file (low-latency).
        \\
    );

    return out.toOwnedSlice(allocator);
}
