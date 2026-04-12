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
const handle_bash_tool = @import("handle_bash_tool.zig");
const handle_read_file_tool = @import("handle_read_file_tool.zig");
const handle_text_replace_tool = @import("handle_text_replace_tool.zig");
const handle_write_file_tool = @import("handle_write_file_tool.zig");
const handle_list_skills_tool = @import("handle_list_skills_tool.zig");
const handle_get_skill_tool = @import("handle_get_skill_tool.zig");
const handle_remove_skill_tool = @import("handle_remove_skill_tool.zig");
const handle_list_agents_tool = @import("handle_list_agents_tool.zig");
const handle_change_agent_tool = @import("handle_change_agent_tool.zig");
const handle_add_skill_tool = @import("handle_add_skill_tool.zig");
const handle_add_agent_tool = @import("handle_add_agent_tool.zig");
const handle_remove_agent_tool = @import("handle_remove_agent_tool.zig");
const handle_lsp_definition_tool = @import("handle_lsp_definition_tool.zig");

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

// Individual tool executors
pub fn execBash(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    return handle_bash_tool.runWithContext(allocator, tc, db, session_id);
}

pub fn execReadFile(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = db;
    _ = session_id;
    return handle_read_file_tool.handle_read_file_tool_run(allocator, tc);
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

pub fn execAddSkill(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = db;
    _ = session_id;
    return handle_add_skill_tool.handle_add_skill_tool_run(allocator, tc);
}

pub fn execAddAgent(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = db;
    _ = session_id;
    return handle_add_agent_tool.handle_add_agent_tool_run(allocator, tc);
}

pub fn execRemoveAgent(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = db;
    _ = session_id;
    return handle_remove_agent_tool.handle_remove_agent_tool_run(allocator, tc);
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

// Web search tool handlers
const handle_web_search_tool = @import("handle_web_search_tool.zig");
const handle_glob_tool = @import("handle_glob_tool.zig");
const handle_search_tool = @import("handle_search_tool.zig");

pub fn execWebSearch(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    return handle_web_search_tool.runWithContext(allocator, tc, db, session_id);
}

pub fn execGlob(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = db;
    _ = session_id;
    return handle_glob_tool.handle_glob_tool_run(allocator, tc);
}

pub fn execSearch(allocator: std.mem.Allocator, tc: agent.ToolCall, db: *sqlite.SqliteBackend, session_id: []const u8) ![]const u8 {
    _ = db;
    _ = session_id;
    return handle_search_tool.handle_search_tool_run(allocator, tc);
}

// ============================================================================
// UNIFIED TOOL REGISTRY - Single source of truth for ALL tool metadata
// ============================================================================

/// Metadata for each tool in the unified registry
pub const ToolInfo = struct {
    name: []const u8,
    exec: SubAgentToolExec,
    tool_def: tool_models.AgentTool,
    allowed_for_subagent: bool = true,
    auto_save_skill: bool = false,
    auto_save_agent: bool = false,
};

/// The ONE registry for all tool metadata.
/// `allowed_for_subagent = false` excludes dangerous tools (spawn_sub_agent, set_agent_properties).
pub const UNIFIED_TOOL_REGISTRY: []const ToolInfo = &.{
    // === AGENT CONTROL (not allowed for sub-agents) ===
    .{ .name = "set_agent_properties", .exec = execSetAgentProperties, .tool_def = set_agent_properties_mod.set_agent_properties_tool, .allowed_for_subagent = false },
    .{ .name = "spawn_sub_agent", .exec = execSpawnSubAgent, .tool_def = spawn_sub_agent_tool.spawn_sub_agent_tool, .allowed_for_subagent = false },

    // === AGENT MANAGEMENT (allowed for sub-agents, auto-save) ===
    .{ .name = "list_agents", .exec = execListAgents, .tool_def = list_agents_mod.list_agents_tool, .allowed_for_subagent = true, .auto_save_agent = true },
    .{ .name = "change_agent", .exec = execChangeAgent, .tool_def = change_agent_mod.change_agent_tool, .allowed_for_subagent = true, .auto_save_agent = true },
    .{ .name = "remove_agent", .exec = execRemoveAgent, .tool_def = remove_agent_mod.remove_agent_tool, .allowed_for_subagent = true },

    // === SKILL MANAGEMENT ===
    .{ .name = "list_skills", .exec = execListSkills, .tool_def = list_skills_mod.list_skills_tool, .allowed_for_subagent = true },
    .{ .name = "get_skill", .exec = execGetSkill, .tool_def = get_skill_mod.get_skill_tool, .allowed_for_subagent = true, .auto_save_skill = true },
    .{ .name = "remove_skill", .exec = execRemoveSkill, .tool_def = remove_skill_mod.remove_skill_tool, .allowed_for_subagent = true },

    // === SKILL/AGENT CREATION ===
    .{ .name = "add_skill", .exec = execAddSkill, .tool_def = add_skill_mod.add_skill_tool, .allowed_for_subagent = true, .auto_save_skill = true },
    .{ .name = "add_agent", .exec = execAddAgent, .tool_def = add_agent_mod.add_agent_tool, .allowed_for_subagent = true, .auto_save_agent = true },

    // === FILE OPERATIONS ===
    .{ .name = "bash", .exec = execBash, .tool_def = bash_tool_mod.bash_tool, .allowed_for_subagent = true },
    .{ .name = "read_file", .exec = execReadFile, .tool_def = read_file_mod.read_file_tool, .allowed_for_subagent = true },
    .{ .name = "write_file", .exec = execWriteFile, .tool_def = write_file_mod.write_file_tool, .allowed_for_subagent = true },
    .{ .name = "text_replace", .exec = execTextReplace, .tool_def = text_replace_mod.text_replace_tool, .allowed_for_subagent = true },

    // === LSP TOOLS ===
    .{ .name = "lsp_definition", .exec = execLspDefinition, .tool_def = lsp_definition_mod.lsp_definition_tool, .allowed_for_subagent = true },
    .{ .name = "lsp_references", .exec = execLspReferences, .tool_def = lsp_references_mod.lsp_references_tool, .allowed_for_subagent = true },
    .{ .name = "lsp_workspace_symbol", .exec = execLspWorkspaceSymbol, .tool_def = lsp_workspace_symbol_mod.lsp_workspace_symbol_tool, .allowed_for_subagent = true },
    .{ .name = "lsp_document_symbol", .exec = execLspDocumentSymbol, .tool_def = lsp_document_symbol_mod.lsp_document_symbol_tool, .allowed_for_subagent = true },
    .{ .name = "lsp_hover", .exec = execLspHover, .tool_def = lsp_hover_mod.lsp_hover_tool, .allowed_for_subagent = true },

    // === WEB SEARCH TOOLS ===
    .{ .name = "web_search", .exec = execWebSearch, .tool_def = web_search_mod.web_search_tool, .allowed_for_subagent = true },

    // === FILE SEARCH TOOLS ===
    .{ .name = "glob", .exec = execGlob, .tool_def = glob_tool_mod.glob_tool, .allowed_for_subagent = true },
    .{ .name = "search", .exec = execSearch, .tool_def = search_tool_mod.search_tool, .allowed_for_subagent = true },
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

/// Registry for sub-agents (excludes dangerous tools like spawn_sub_agent, set_agent_properties)
pub const SUB_AGENT_TOOL_REGISTRY: []const ToolInfo = &.{
    // === AGENT MANAGEMENT (allowed for sub-agents, auto-save) ===
    .{ .name = "list_agents", .exec = execListAgents, .tool_def = list_agents_mod.list_agents_tool, .allowed_for_subagent = true, .auto_save_agent = true },
    .{ .name = "change_agent", .exec = execChangeAgent, .tool_def = change_agent_mod.change_agent_tool, .allowed_for_subagent = true, .auto_save_agent = true },
    .{ .name = "remove_agent", .exec = execRemoveAgent, .tool_def = remove_agent_mod.remove_agent_tool, .allowed_for_subagent = true },

    // === SKILL MANAGEMENT ===
    .{ .name = "list_skills", .exec = execListSkills, .tool_def = list_skills_mod.list_skills_tool, .allowed_for_subagent = true },
    .{ .name = "get_skill", .exec = execGetSkill, .tool_def = get_skill_mod.get_skill_tool, .allowed_for_subagent = true, .auto_save_skill = true },
    .{ .name = "remove_skill", .exec = execRemoveSkill, .tool_def = remove_skill_mod.remove_skill_tool, .allowed_for_subagent = true },

    // === SKILL/AGENT CREATION ===
    .{ .name = "add_skill", .exec = execAddSkill, .tool_def = add_skill_mod.add_skill_tool, .allowed_for_subagent = true, .auto_save_skill = true },
    .{ .name = "add_agent", .exec = execAddAgent, .tool_def = add_agent_mod.add_agent_tool, .allowed_for_subagent = true, .auto_save_agent = true },

    // === FILE OPERATIONS ===
    .{ .name = "bash", .exec = execBash, .tool_def = bash_tool_mod.bash_tool, .allowed_for_subagent = true },
    .{ .name = "read_file", .exec = execReadFile, .tool_def = read_file_mod.read_file_tool, .allowed_for_subagent = true },
    .{ .name = "write_file", .exec = execWriteFile, .tool_def = write_file_mod.write_file_tool, .allowed_for_subagent = true },
    .{ .name = "text_replace", .exec = execTextReplace, .tool_def = text_replace_mod.text_replace_tool, .allowed_for_subagent = true },

    // === LSP TOOLS ===
    .{ .name = "lsp_definition", .exec = execLspDefinition, .tool_def = lsp_definition_mod.lsp_definition_tool, .allowed_for_subagent = true },
    .{ .name = "lsp_references", .exec = execLspReferences, .tool_def = lsp_references_mod.lsp_references_tool, .allowed_for_subagent = true },
    .{ .name = "lsp_workspace_symbol", .exec = execLspWorkspaceSymbol, .tool_def = lsp_workspace_symbol_mod.lsp_workspace_symbol_tool, .allowed_for_subagent = true },
    .{ .name = "lsp_document_symbol", .exec = execLspDocumentSymbol, .tool_def = lsp_document_symbol_mod.lsp_document_symbol_tool, .allowed_for_subagent = true },
    .{ .name = "lsp_hover", .exec = execLspHover, .tool_def = lsp_hover_mod.lsp_hover_tool, .allowed_for_subagent = true },

    // === WEB SEARCH TOOLS ===
    .{ .name = "web_search", .exec = execWebSearch, .tool_def = web_search_mod.web_search_tool, .allowed_for_subagent = true },

    // === FILE SEARCH TOOLS ===
    .{ .name = "glob", .exec = execGlob, .tool_def = glob_tool_mod.glob_tool, .allowed_for_subagent = true },
    .{ .name = "search", .exec = execSearch, .tool_def = search_tool_mod.search_tool, .allowed_for_subagent = true },
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
