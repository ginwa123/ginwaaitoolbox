const std = @import("std");
const root_mod = @import("nalarcore");
const agent = root_mod.agent;
const tool_models = root_mod.tool_models;
const spawn_sub_agent_tool = root_mod.spawn_sub_agent;

// Tool imports for exec functions and tool_defs
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
const tree_dir_mod = root_mod.tree_dir;
const lsp_definition_mod = root_mod.tools.lsp_definition;
const lsp_references_mod = root_mod.tools.lsp_references;
const lsp_workspace_symbol_mod = root_mod.tools.lsp_workspace_symbol;
const lsp_document_symbol_mod = root_mod.tools.lsp_document_symbol;
const lsp_hover_mod = root_mod.tools.lsp_hover;
const set_agent_properties_mod = root_mod.set_agent_properties;
const web_search_mod = root_mod.web_search;
const web_search_help_mod = root_mod.web_search_help;

// Forward declare to avoid circular import (exec functions)
const handle_spawn_sub_agent = @import("handle_spawn_sub_agent.zig");

// ============================================================================
// UNIFIED TOOL REGISTRY - Single source of truth for ALL tool metadata
// ============================================================================

/// Function signature for sub-agent tool executors
pub const SubAgentToolExec = handle_spawn_sub_agent.SubAgentToolExec;

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
    .{ .name = "set_agent_properties", .exec = handle_spawn_sub_agent.execSetAgentProperties, .tool_def = set_agent_properties_mod.set_agent_properties_tool, .allowed_for_subagent = false },
    .{ .name = "spawn_sub_agent", .exec = handle_spawn_sub_agent.execSpawnSubAgent, .tool_def = spawn_sub_agent_tool.spawn_sub_agent_tool, .allowed_for_subagent = false },

    // === AGENT MANAGEMENT (allowed for sub-agents, auto-save) ===
    .{ .name = "list_agents", .exec = handle_spawn_sub_agent.execListAgents, .tool_def = list_agents_mod.list_agents_tool, .allowed_for_subagent = true, .auto_save_agent = true },
    .{ .name = "change_agent", .exec = handle_spawn_sub_agent.execChangeAgent, .tool_def = change_agent_mod.change_agent_tool, .allowed_for_subagent = true, .auto_save_agent = true },

    // === SKILL MANAGEMENT ===
    .{ .name = "list_skills", .exec = handle_spawn_sub_agent.execListSkills, .tool_def = list_skills_mod.list_skills_tool, .allowed_for_subagent = true },
    .{ .name = "get_skill", .exec = handle_spawn_sub_agent.execGetSkill, .tool_def = get_skill_mod.get_skill_tool, .allowed_for_subagent = true, .auto_save_skill = true },
    .{ .name = "remove_skill", .exec = handle_spawn_sub_agent.execRemoveSkill, .tool_def = remove_skill_mod.remove_skill_tool, .allowed_for_subagent = true },

    // === FILE OPERATIONS ===
    .{ .name = "bash", .exec = handle_spawn_sub_agent.execBash, .tool_def = bash_tool_mod.bash_tool, .allowed_for_subagent = true },
    .{ .name = "read_file", .exec = handle_spawn_sub_agent.execReadFile, .tool_def = read_file_mod.read_file_tool, .allowed_for_subagent = true },
    .{ .name = "write_file", .exec = handle_spawn_sub_agent.execWriteFile, .tool_def = write_file_mod.write_file_tool, .allowed_for_subagent = true },
    .{ .name = "text_replace", .exec = handle_spawn_sub_agent.execTextReplace, .tool_def = text_replace_mod.text_replace_tool, .allowed_for_subagent = true },
    .{ .name = "search", .exec = handle_spawn_sub_agent.execSearch, .tool_def = search_tool_mod.search_tool, .allowed_for_subagent = true },
    .{ .name = "glob", .exec = handle_spawn_sub_agent.execGlob, .tool_def = glob_tool_mod.glob_tool, .allowed_for_subagent = true },
    .{ .name = "tree_dir", .exec = handle_spawn_sub_agent.execTreeDir, .tool_def = tree_dir_mod.tree_dir_tool, .allowed_for_subagent = true },

    // === LSP TOOLS ===
    .{ .name = "lsp_definition", .exec = handle_spawn_sub_agent.execLspDefinition, .tool_def = lsp_definition_mod.lsp_definition_tool, .allowed_for_subagent = true },
    .{ .name = "lsp_references", .exec = handle_spawn_sub_agent.execLspReferences, .tool_def = lsp_references_mod.lsp_references_tool, .allowed_for_subagent = true },
    .{ .name = "lsp_workspace_symbol", .exec = handle_spawn_sub_agent.execLspWorkspaceSymbol, .tool_def = lsp_workspace_symbol_mod.lsp_workspace_symbol_tool, .allowed_for_subagent = true },
    .{ .name = "lsp_document_symbol", .exec = handle_spawn_sub_agent.execLspDocumentSymbol, .tool_def = lsp_document_symbol_mod.lsp_document_symbol_tool, .allowed_for_subagent = true },
    .{ .name = "lsp_hover", .exec = handle_spawn_sub_agent.execLspHover, .tool_def = lsp_hover_mod.lsp_hover_tool, .allowed_for_subagent = true },

    // === WEB SEARCH TOOLS ===
    .{ .name = "web_search", .exec = handle_spawn_sub_agent.execWebSearch, .tool_def = web_search_mod.web_search_tool, .allowed_for_subagent = true },
    .{ .name = "web_search_help", .exec = handle_spawn_sub_agent.execWebSearchHelp, .tool_def = web_search_help_mod.web_search_help_tool, .allowed_for_subagent = true },
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
    list_skills_mod.list_skills_tool,
    get_skill_mod.get_skill_tool,
    remove_skill_mod.remove_skill_tool,
    bash_tool_mod.bash_tool,
    read_file_mod.read_file_tool,
    write_file_mod.write_file_tool,
    text_replace_mod.text_replace_tool,
    search_tool_mod.search_tool,
    glob_tool_mod.glob_tool,
    tree_dir_mod.tree_dir_tool,
    lsp_definition_mod.lsp_definition_tool,
    lsp_references_mod.lsp_references_tool,
    lsp_workspace_symbol_mod.lsp_workspace_symbol_tool,
    lsp_document_symbol_mod.lsp_document_symbol_tool,
    lsp_hover_mod.lsp_hover_tool,
    web_search_mod.web_search_tool,
    web_search_help_mod.web_search_help_tool,
};

/// Registry for sub-agents (excludes dangerous tools like spawn_sub_agent, set_agent_properties)
pub const SUB_AGENT_TOOL_REGISTRY: []const ToolInfo = &.{
    // === AGENT MANAGEMENT (allowed for sub-agents, auto-save) ===
    .{ .name = "list_agents", .exec = handle_spawn_sub_agent.execListAgents, .tool_def = list_agents_mod.list_agents_tool, .allowed_for_subagent = true, .auto_save_agent = true },
    .{ .name = "change_agent", .exec = handle_spawn_sub_agent.execChangeAgent, .tool_def = change_agent_mod.change_agent_tool, .allowed_for_subagent = true, .auto_save_agent = true },

    // === SKILL MANAGEMENT ===
    .{ .name = "list_skills", .exec = handle_spawn_sub_agent.execListSkills, .tool_def = list_skills_mod.list_skills_tool, .allowed_for_subagent = true },
    .{ .name = "get_skill", .exec = handle_spawn_sub_agent.execGetSkill, .tool_def = get_skill_mod.get_skill_tool, .allowed_for_subagent = true, .auto_save_skill = true },
    .{ .name = "remove_skill", .exec = handle_spawn_sub_agent.execRemoveSkill, .tool_def = remove_skill_mod.remove_skill_tool, .allowed_for_subagent = true },

    // === FILE OPERATIONS ===
    .{ .name = "bash", .exec = handle_spawn_sub_agent.execBash, .tool_def = bash_tool_mod.bash_tool, .allowed_for_subagent = true },
    .{ .name = "read_file", .exec = handle_spawn_sub_agent.execReadFile, .tool_def = read_file_mod.read_file_tool, .allowed_for_subagent = true },
    .{ .name = "write_file", .exec = handle_spawn_sub_agent.execWriteFile, .tool_def = write_file_mod.write_file_tool, .allowed_for_subagent = true },
    .{ .name = "text_replace", .exec = handle_spawn_sub_agent.execTextReplace, .tool_def = text_replace_mod.text_replace_tool, .allowed_for_subagent = true },
    .{ .name = "search", .exec = handle_spawn_sub_agent.execSearch, .tool_def = search_tool_mod.search_tool, .allowed_for_subagent = true },
    .{ .name = "glob", .exec = handle_spawn_sub_agent.execGlob, .tool_def = glob_tool_mod.glob_tool, .allowed_for_subagent = true },
    .{ .name = "tree_dir", .exec = handle_spawn_sub_agent.execTreeDir, .tool_def = tree_dir_mod.tree_dir_tool, .allowed_for_subagent = true },

    // === LSP TOOLS ===
    .{ .name = "lsp_definition", .exec = handle_spawn_sub_agent.execLspDefinition, .tool_def = lsp_definition_mod.lsp_definition_tool, .allowed_for_subagent = true },
    .{ .name = "lsp_references", .exec = handle_spawn_sub_agent.execLspReferences, .tool_def = lsp_references_mod.lsp_references_tool, .allowed_for_subagent = true },
    .{ .name = "lsp_workspace_symbol", .exec = handle_spawn_sub_agent.execLspWorkspaceSymbol, .tool_def = lsp_workspace_symbol_mod.lsp_workspace_symbol_tool, .allowed_for_subagent = true },
    .{ .name = "lsp_document_symbol", .exec = handle_spawn_sub_agent.execLspDocumentSymbol, .tool_def = lsp_document_symbol_mod.lsp_document_symbol_tool, .allowed_for_subagent = true },
    .{ .name = "lsp_hover", .exec = handle_spawn_sub_agent.execLspHover, .tool_def = lsp_hover_mod.lsp_hover_tool, .allowed_for_subagent = true },

    // === WEB SEARCH TOOLS ===
    .{ .name = "web_search", .exec = handle_spawn_sub_agent.execWebSearch, .tool_def = web_search_mod.web_search_tool, .allowed_for_subagent = true },
    .{ .name = "web_search_help", .exec = handle_spawn_sub_agent.execWebSearchHelp, .tool_def = web_search_help_mod.web_search_help_tool, .allowed_for_subagent = true },
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
    const skill_name = result[name_begin..name_begin + name_end];

    const content_start = std.mem.indexOf(u8, result, "<content>") orelse return null;
    const content_begin = content_start + "<content>".len;
    const content_end = std.mem.indexOf(u8, result[content_begin..], "</content>") orelse return null;
    const skill_content = result[content_begin..content_begin + content_end];

    return .{ .name = skill_name, .content = skill_content };
}

pub fn parseAgentFromResult(result: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, result, "<loaded>true</loaded>") == null) return null;

    const name_start = std.mem.indexOf(u8, result, "<agent_name>") orelse return null;
    const name_begin = name_start + "<agent_name>".len;
    const name_end = std.mem.indexOf(u8, result[name_begin..], "</agent_name>") orelse return null;
    return result[name_begin..name_begin + name_end];
}
