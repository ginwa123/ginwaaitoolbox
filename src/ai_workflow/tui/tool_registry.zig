const std = @import("std");
const root_mod = @import("nalarcore");
const agent = root_mod.agent;
const tool_models = root_mod.tool_models;
const sqlite = root_mod.sqlite;
const spawn_sub_agent_tool = root_mod.spawn_sub_agent;

// Tool imports for exec functions and tool_defs
const bash_tool_mod = root_mod.bash_tool;
const read_file_mod = root_mod.read_file;
const text_replace_mod = root_mod.text_replace_tool;
const write_file_mod = root_mod.write_file;
const list_skills_mod = root_mod.list_skills_tool;
const get_skill_mod = root_mod.get_skill_tool;
const remove_skill_mod = root_mod.remove_skill_tool;
const list_agents_mod = root_mod.list_agents;
const add_skill_mod = root_mod.add_skill;
const add_agent_mod = root_mod.add_agent;
const remove_agent_mod = root_mod.remove_agent;
const change_agent_mod = root_mod.change_agent;
const lsp_definition_mod = root_mod.tools.lsp_definition;
const lsp_references_mod = root_mod.tools.lsp_references;
const lsp_workspace_symbol_mod = root_mod.tools.lsp_workspace_symbol;
const lsp_document_symbol_mod = root_mod.tools.lsp_document_symbol;
const lsp_hover_mod = root_mod.tools.lsp_hover;
const set_agent_properties_mod = root_mod.set_agent_properties;
const web_search_mod = root_mod.web_search;
const glob_tool_mod = root_mod.glob_tool;
const search_tool_mod = root_mod.search_tool;

// Handle tool imports for exec functions
const background_process = @import("background_process.zig");

// ============================================================================
// CODE EXEC TOOL TYPES AND FUNCTIONS
// ============================================================================

/// Function signature for sub-agent tool executors
pub const SubAgentToolExec = *const fn (
    allocator: std.mem.Allocator,
    tc: agent.ToolCall,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) anyerror![]const u8;

/// Tool execution result with optional auto-save metadata
pub const SubAgentToolResult = struct {
    output: []const u8,
    skill_save: ?SkillSaveInfo = null,
    agent_save: ?AgentSaveInfo = null,
};

pub const SkillSaveInfo = struct {
    name: []const u8,
    content: []const u8,
};

pub const AgentSaveInfo = struct {
    name: []const u8,
};

// ============================================================================
// BASH TOOL EXECUTION
// ============================================================================

/// Run with database context for background process tracking
pub fn runWithContext(
    allocator: std.mem.Allocator,
    tool_call: agent.ToolCall,
    db: ?*sqlite.SqliteBackend,
    session_id: ?[]const u8,
) ![]const u8 {
    // Parse arguments JSON to BashInput
    const parsed = try std.json.parseFromSlice(
        tool_models.BashInput,
        allocator,
        tool_call.function.arguments,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const is_background = parsed.value.background;

    const bash_output = try bash_tool_mod.execute_bash(allocator, parsed.value);

    // If background mode and DB is available, save the process info
    if (is_background and db != null and session_id != null) {
        const db_ptr = db.?;
        const sess_id = session_id.?;

        // Parse PID from bash output (format: "PID: {pid}\nLog: {path}")
        const stdout = bash_output.stdout;
        if (stdout.len > 5) {
            // Skip "PID: " prefix
            const pid_start = 5;
            var pid_end: usize = 4;
            while (pid_end < stdout.len and stdout[pid_end] != '\n') : (pid_end += 1) {}

            if (pid_end > pid_start) {
                const pid_str = stdout[pid_start..pid_end];
                const pid = std.fmt.parseInt(u32, pid_str, 10) catch 0;

                if (pid > 0) {
                    // Extract log path from "Log: {path}" part
                    var log_start: usize = 0;
                    while (log_start < stdout.len and stdout[log_start] != '\n') : (log_start += 1) {}
                    log_start += 1; // skip newline

                    // Find "Log: " prefix
                    var log_path_start = log_start;
                    while (log_path_start < stdout.len and log_path_start < log_start + 5) : (log_path_start += 1) {}

                    if (log_path_start < stdout.len) {
                        const log_path = stdout[log_path_start..];

                        // Save to database
                        const started_at = std.time.timestamp();
                        background_process.save(db_ptr, allocator, sess_id, pid, parsed.value.command, log_path, started_at) catch {
                            // Log error but don't fail the tool execution
                        };
                    }
                }
            }
        }
    }

    const res_bash = try bash_tool_mod.bash_result_to_string(allocator, bash_output);

    return res_bash;
}

// Individual tool executors
pub fn execBash(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    return runWithContext(allocator, tc, db, session_id);
}

pub fn execReadFile(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = db;
    _ = session_id;

    // Parse arguments JSON to ReadFileInput
    const parsed = try std.json.parseFromSlice(
        tool_models.ReadFileInput,
        allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const read_opts = read_file_mod.ReadFileOptions{
        .offset = parsed.value.offset,
        .limit = parsed.value.limit,
        .show_line_numbers = parsed.value.show_line_numbers,
    };

    const read_result = try read_file_mod.read_file(allocator, parsed.value.path, read_opts);
    defer read_result.deinit(allocator);

    // Single allocation: combines path and content into XML result
    return try read_file_mod.to_xml(allocator, read_result, parsed.value.path);
}

pub fn execTextReplace(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = db;
    _ = session_id;

    // Check for empty arguments first
    if (tc.function.arguments.len == 0) {
        return try std.fmt.allocPrint(allocator,
            \\<error>text_replace failed: Missing arguments (empty JSON)</error>
            \\<path></path>
            \\<old_str></old_str>
            \\<new_str></new_str>
            \\<success>false</success>
        , .{});
    }

    const parsed = std.json.parseFromSlice(
        text_replace_mod.TextReplaceInput,
        allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const err_msg: []const u8 = switch (err) {
            error.UnexpectedEndOfInput => "text_replace failed: UnexpectedEndOfInput - arguments may be incomplete or malformed",
            else => "text_replace failed: Invalid JSON arguments",
        };
        return try std.fmt.allocPrint(allocator,
            \\<error>{s}</error>
            \\<path></path>
            \\<old_str></old_str>
            \\<new_str></new_str>
            \\<success>false</success>
        , .{err_msg});
    };
    defer parsed.deinit();

    const result = try text_replace_mod.text_replace(
        allocator,
        parsed.value.path,
        parsed.value.old_str,
        parsed.value.new_str,
    );

    return text_replace_mod.to_xml(allocator, result);
}

pub fn execWriteFile(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = db;
    _ = session_id;

    const parsed = try std.json.parseFromSlice(
        write_file_mod.WriteFileInput,
        allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const write_result = try write_file_mod.write_file(allocator, parsed.value);
    const res_write = try write_file_mod.write_file_to_string(allocator, write_result);
    write_result.deinit(allocator);

    return res_write;
}

pub fn execListSkills(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = tc;
    _ = db;
    _ = session_id;

    return list_skills_mod.execute_list_skills(allocator) catch blk: {
        break :blk "{\"error\": \"Failed to list skills\"}";
    };
}

pub fn execGetSkill(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = db;
    _ = session_id;

    const parsed = std.json.parseFromSlice(
        get_skill_mod.GetSkillInput,
        allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch {
        return "<skill_name></skill_name><content></content><loaded>false</loaded><error>Failed to parse get_skill arguments</error>";
    };
    defer parsed.deinit();

    return get_skill_mod.execute_get_skill_to_string(allocator, parsed.value) catch {
        return "<skill_name></skill_name><content></content><loaded>false</loaded><error>Failed to get skill</error>";
    };
}

pub fn execRemoveSkill(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = db;
    _ = session_id;

    const parsed = std.json.parseFromSlice(
        remove_skill_mod.RemoveSkillInput,
        allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch {
        return try std.fmt.allocPrint(allocator,
            \\<skill_name></skill_name>
            \\<removed>false</removed>
            \\<error>Failed to parse remove_skill arguments</error>
        , .{});
    };
    defer parsed.deinit();

    return remove_skill_mod.execute_remove_skill_to_string(allocator, parsed.value) catch {
        return try std.fmt.allocPrint(allocator,
            \\<skill_name>{s}</skill_name>
            \\<removed>false</removed>
            \\<error>Unknown error</error>
        , .{ parsed.value.skill_name });
    };
}

pub fn execAddSkill(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = db;
    _ = session_id;

    const parsed = std.json.parseFromSlice(
        add_skill_mod.AddSkillInput,
        allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch {
        return try std.fmt.allocPrint(allocator,
            \\<skill>
            \\<name></name>
            \\<created>false</created>
            \\<error>Failed to parse add_skill arguments</error>
            \\</skill>
        , .{});
    };
    defer parsed.deinit();

    return add_skill_mod.execute_add_skill_to_string(allocator, parsed.value) catch {
        return try std.fmt.allocPrint(allocator,
            \\<skill>
            \\<name>{s}</name>
            \\<created>false</created>
            \\<error>Failed to add skill</error>
            \\</skill>
        , .{ parsed.value.name });
    };
}

pub fn execAddAgent(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = db;
    _ = session_id;

    const parsed = std.json.parseFromSlice(
        add_agent_mod.AddAgentInput,
        allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch {
        return try std.fmt.allocPrint(allocator,
            \\<agent>
            \\<name></name>
            \\<created>false</created>
            \\<error>Failed to parse add_agent arguments</error>
            \\</agent>
        , .{});
    };
    defer parsed.deinit();

    return add_agent_mod.execute_add_agent_to_string(allocator, parsed.value) catch {
        return try std.fmt.allocPrint(allocator,
            \\<agent>
            \\<name>{s}</name>
            \\<created>false</created>
            \\<error>Failed to add agent</error>
            \\</agent>
        , .{ parsed.value.name });
    };
}

pub fn execRemoveAgent(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = db;
    _ = session_id;

    const parsed = std.json.parseFromSlice(
        remove_agent_mod.RemoveAgentInput,
        allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch {
        return try std.fmt.allocPrint(allocator,
            \\<name></name>
            \\<removed>false</removed>
            \\<error>Failed to parse remove_agent arguments</error>
        , .{});
    };
    defer parsed.deinit();

    return remove_agent_mod.execute_remove_agent_to_string(allocator, parsed.value) catch {
        return try std.fmt.allocPrint(allocator,
            \\<name>{s}</name>
            \\<removed>false</removed>
            \\<error>Failed to remove agent</error>
        , .{ parsed.value.name });
    };
}

pub fn execListAgents(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = tc;
    _ = db;
    _ = session_id;

    return list_agents_mod.execute_list_agents(allocator) catch {
        return try std.fmt.allocPrint(allocator,
            \\<agents>
            \\  <error>Failed to list agents</error>
            \\</agents>
        , .{});
    };
}

pub fn execChangeAgent(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = db;
    _ = session_id;

    const parsed = std.json.parseFromSlice(
        change_agent_mod.ChangeAgentInput,
        allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch {
        return try std.fmt.allocPrint(allocator,
            \\<agent>
            \\  <agent_name></agent_name>
            \\  <content></content>
            \\  <loaded>false</loaded>
            \\  <error>Failed to parse change_agent arguments</error>
            \\</agent>
        , .{});
    };
    defer parsed.deinit();

    return change_agent_mod.execute_change_agent_to_string(allocator, parsed.value) catch {
        return try std.fmt.allocPrint(allocator,
            \\<agent>
            \\  <agent_name></agent_name>
            \\  <content></content>
            \\  <loaded>false</loaded>
            \\  <error>Failed to get agent</error>
            \\</agent>
        , .{});
    };
}

pub fn execLspDefinition(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = db;
    _ = session_id;

    const parsed = std.json.parseFromSlice(
        lsp_definition_mod.LspDefinitionInput,
        allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        return try std.fmt.allocPrint(allocator,
            "<error>Failed to parse lsp_definition arguments: {s}</error>",
            .{@errorName(err)},
        );
    };
    defer parsed.deinit();

    const result = lsp_definition_mod.execute_lsp_definition(allocator, parsed.value) catch |err| {
        return try std.fmt.allocPrint(allocator,
            "<error>Failed to get definition: {s}</error>",
            .{@errorName(err)},
        );
    };
    defer result.deinit(allocator);

    return lsp_definition_mod.lsp_definition_to_string(allocator, result);
}

// Placeholder for restricted tools
pub fn execSpawnSubAgent(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = allocator;
    _ = tc;
    _ = db;
    _ = session_id;
    return "spawn_sub_agent should not be called from sub-agent context";
}

pub fn execSetAgentProperties(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = allocator;
    _ = tc;
    _ = db;
    _ = session_id;
    return "set_agent_properties should not be called from sub-agent context";
}

// Placeholder LSP exec functions
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

pub fn execWebSearch(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = db;
    _ = session_id;

    const parsed = try std.json.parseFromSlice(
        tool_models.WebSearchInput,
        allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const result = try web_search_mod.execute_web_search(allocator, parsed.value);
    defer result.deinit(allocator);

    return try web_search_mod.web_search_result_to_string(allocator, result);
}

pub fn execGlob(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = db;
    _ = session_id;

    const args = tc.function.arguments;
    const args_to_parse: []const u8 = if (args.len == 0) "{}" else args;

    const parsed = try std.json.parseFromSlice(
        glob_tool_mod.GlobInput,
        allocator,
        args_to_parse,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    var glob_result = try glob_tool_mod.execute_glob(allocator, parsed.value);
    const res_glob = try glob_tool_mod.glob_result_to_string(allocator, glob_result);
    glob_result.deinit(allocator);

    return res_glob;
}

pub fn execSearch(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = db;
    _ = session_id;

    const args = tc.function.arguments;
    const args_to_parse: []const u8 = if (args.len == 0) "{}" else args;

    const parsed = try std.json.parseFromSlice(
        search_tool_mod.SearchInput,
        allocator,
        args_to_parse,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    var search_result = search_tool_mod.execute_search(allocator, parsed.value) catch |err| {
        if (err == error.StdoutStreamTooLong) {
            return try allocator.dupe(u8,
                \\<warning>Search output exceeded max_output limit. Use a larger max_output value (e.g. 5242880 for 5MB), narrow your search path, or use a more specific pattern.</warning>
            );
        }
        return err;
    };

    if (search_result.matches.items.len == 0) {
        const content = try allocator.dupe(u8, search_result.content);
        search_result.deinit(allocator);
        return content;
    }

    const res_search = try search_tool_mod.search_result_to_string(allocator, search_result);
    search_result.deinit(allocator);

    return res_search;
}

// ============================================================================
// UNIFIED TOOL REGISTRY - Single source of truth for ALL tool metadata
// ============================================================================

/// Metadata for each tool in the unified registry
pub const ToolInfo = struct {
    name: []const u8,
    exec: SubAgentToolExec,
    tool_def: tool_models.AgentTool,
    auto_save_skill: bool = false,
    auto_save_agent: bool = false,
};

/// The ONE registry for all tool metadata.
/// Main agent gets all tools. Sub-agents get SUB_AGENT_TOOL_REGISTRY (hard filtered).
pub const UNIFIED_TOOL_REGISTRY: []const ToolInfo = &.{
    // === AGENT CONTROL (main agent only) ===
    .{ .name = "set_agent_properties", .exec = execSetAgentProperties, .tool_def = set_agent_properties_mod.set_agent_properties_tool },
    .{ .name = "spawn_sub_agent", .exec = execSpawnSubAgent, .tool_def = spawn_sub_agent_tool.spawn_sub_agent_tool },

    // === AGENT MANAGEMENT (auto-save) ===
    .{ .name = "list_agents", .exec = execListAgents, .tool_def = list_agents_mod.list_agents_tool, .auto_save_agent = true },
    .{ .name = "change_agent", .exec = execChangeAgent, .tool_def = change_agent_mod.change_agent_tool, .auto_save_agent = true },
    .{ .name = "remove_agent", .exec = execRemoveAgent, .tool_def = remove_agent_mod.remove_agent_tool },

    // === SKILL MANAGEMENT ===
    .{ .name = "list_skills", .exec = execListSkills, .tool_def = list_skills_mod.list_skills_tool },
    .{ .name = "get_skill", .exec = execGetSkill, .tool_def = get_skill_mod.get_skill_tool, .auto_save_skill = true },
    .{ .name = "remove_skill", .exec = execRemoveSkill, .tool_def = remove_skill_mod.remove_skill_tool },

    // === SKILL/AGENT CREATION ===
    .{ .name = "add_skill", .exec = execAddSkill, .tool_def = add_skill_mod.add_skill_tool, .auto_save_skill = true },
    .{ .name = "add_agent", .exec = execAddAgent, .tool_def = add_agent_mod.add_agent_tool, .auto_save_agent = true },

    // === FILE OPERATIONS ===
    .{ .name = "bash", .exec = execBash, .tool_def = bash_tool_mod.bash_tool },
    .{ .name = "read_file", .exec = execReadFile, .tool_def = read_file_mod.read_file_tool },
    .{ .name = "write_file", .exec = execWriteFile, .tool_def = write_file_mod.write_file_tool },
    .{ .name = "text_replace", .exec = execTextReplace, .tool_def = text_replace_mod.text_replace_tool },

    // === LSP TOOLS ===
    .{ .name = "lsp_definition", .exec = execLspDefinition, .tool_def = lsp_definition_mod.lsp_definition_tool },
    .{ .name = "lsp_references", .exec = execLspReferences, .tool_def = lsp_references_mod.lsp_references_tool },
    .{ .name = "lsp_workspace_symbol", .exec = execLspWorkspaceSymbol, .tool_def = lsp_workspace_symbol_mod.lsp_workspace_symbol_tool },
    .{ .name = "lsp_document_symbol", .exec = execLspDocumentSymbol, .tool_def = lsp_document_symbol_mod.lsp_document_symbol_tool },
    .{ .name = "lsp_hover", .exec = execLspHover, .tool_def = lsp_hover_mod.lsp_hover_tool },

    // === WEB SEARCH TOOLS ===
    .{ .name = "web_search", .exec = execWebSearch, .tool_def = web_search_mod.web_search_tool },

    // === FILE SEARCH TOOLS ===
    .{ .name = "glob", .exec = execGlob, .tool_def = glob_tool_mod.glob_tool },
    .{ .name = "search", .exec = execSearch, .tool_def = search_tool_mod.search_tool },
};

// ============================================================================
// DERIVED REGISTRIES
// ============================================================================

/// Registry for main agent (all tools)
pub const MAIN_AGENT_TOOL_REGISTRY: []const ToolInfo = UNIFIED_TOOL_REGISTRY;

/// All tool definitions for the main agent
/// This is the canonical list of tool definitions for the main agent
pub const ALL_AGENT_TOOLS: []const tool_models.AgentTool = &.{
    set_agent_properties_mod.set_agent_properties_tool,
    spawn_sub_agent_tool.spawn_sub_agent_tool,
    list_agents_mod.list_agents_tool,
    change_agent_mod.change_agent_tool,
    remove_agent_mod.remove_agent_tool,
    list_skills_mod.list_skills_tool,
    get_skill_mod.get_skill_tool,
    remove_skill_mod.remove_skill_tool,
    add_skill_mod.add_skill_tool,
    add_agent_mod.add_agent_tool,
    bash_tool_mod.bash_tool,
    read_file_mod.read_file_tool,
    write_file_mod.write_file_tool,
    text_replace_mod.text_replace_tool,
    lsp_definition_mod.lsp_definition_tool,
    lsp_references_mod.lsp_references_tool,
    lsp_workspace_symbol_mod.lsp_workspace_symbol_tool,
    lsp_document_symbol_mod.lsp_document_symbol_tool,
    lsp_hover_mod.lsp_hover_tool,
    web_search_mod.web_search_tool,
    glob_tool_mod.glob_tool,
    search_tool_mod.search_tool,
};

/// Registry for sub-agents (excludes dangerous tools: spawn_sub_agent, set_agent_properties)
pub const SUB_AGENT_TOOL_REGISTRY: []const ToolInfo = &.{
    // === AGENT MANAGEMENT (auto-save) ===
    .{ .name = "list_agents", .exec = execListAgents, .tool_def = list_agents_mod.list_agents_tool, .auto_save_agent = true },
    .{ .name = "change_agent", .exec = execChangeAgent, .tool_def = change_agent_mod.change_agent_tool, .auto_save_agent = true },
    .{ .name = "remove_agent", .exec = execRemoveAgent, .tool_def = remove_agent_mod.remove_agent_tool },

    // === SKILL MANAGEMENT ===
    .{ .name = "list_skills", .exec = execListSkills, .tool_def = list_skills_mod.list_skills_tool },
    .{ .name = "get_skill", .exec = execGetSkill, .tool_def = get_skill_mod.get_skill_tool, .auto_save_skill = true },
    .{ .name = "remove_skill", .exec = execRemoveSkill, .tool_def = remove_skill_mod.remove_skill_tool },

    // === SKILL/AGENT CREATION ===
    .{ .name = "add_skill", .exec = execAddSkill, .tool_def = add_skill_mod.add_skill_tool, .auto_save_skill = true },
    .{ .name = "add_agent", .exec = execAddAgent, .tool_def = add_agent_mod.add_agent_tool, .auto_save_agent = true },

    // === FILE OPERATIONS ===
    .{ .name = "bash", .exec = execBash, .tool_def = bash_tool_mod.bash_tool },
    .{ .name = "read_file", .exec = execReadFile, .tool_def = read_file_mod.read_file_tool },
    .{ .name = "write_file", .exec = execWriteFile, .tool_def = write_file_mod.write_file_tool },
    .{ .name = "text_replace", .exec = execTextReplace, .tool_def = text_replace_mod.text_replace_tool },

    // === LSP TOOLS ===
    .{ .name = "lsp_definition", .exec = execLspDefinition, .tool_def = lsp_definition_mod.lsp_definition_tool },
    .{ .name = "lsp_references", .exec = execLspReferences, .tool_def = lsp_references_mod.lsp_references_tool },
    .{ .name = "lsp_workspace_symbol", .exec = execLspWorkspaceSymbol, .tool_def = lsp_workspace_symbol_mod.lsp_workspace_symbol_tool },
    .{ .name = "lsp_document_symbol", .exec = execLspDocumentSymbol, .tool_def = lsp_document_symbol_mod.lsp_document_symbol_tool },
    .{ .name = "lsp_hover", .exec = execLspHover, .tool_def = lsp_hover_mod.lsp_hover_tool },

    // === WEB SEARCH TOOLS ===
    .{ .name = "web_search", .exec = execWebSearch, .tool_def = web_search_mod.web_search_tool },

    // === FILE SEARCH TOOLS ===
    .{ .name = "glob", .exec = execGlob, .tool_def = glob_tool_mod.glob_tool },
    .{ .name = "search", .exec = execSearch, .tool_def = search_tool_mod.search_tool },
};

/// Get tool metadata by name from registry
pub fn getToolByName(name: []const u8) ?*const ToolInfo {
    for (UNIFIED_TOOL_REGISTRY) |*tool| {
        if (std.mem.eql(u8, tool.name, name)) {
            return tool;
        }
    }
    return null;
}

/// Check if tool is known
pub fn isKnownTool(name: []const u8) bool {
    return getToolByName(name) != null;
}

/// Get all tool names
pub fn getToolNames() []const []const u8 {
    var names: [UNIFIED_TOOL_REGISTRY.len][]const u8 = undefined;
    for (UNIFIED_TOOL_REGISTRY, 0..) |tool, i| {
        names[i] = tool.name;
    }
    return &names;
}

// ============================================================================
// AUTO-SAVE PARSING HELPERS
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
