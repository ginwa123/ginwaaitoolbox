const std = @import("std");
const root_mod = @import("nalarcore");
const agent = root_mod.agent;
const tool_models = root_mod.tool_models;
const spawn_sub_agent_tool = root_mod.spawn_sub_agent;

// Tool imports for exec functions and tool_defs
const BashTool = root_mod.bash_tool;
const ReadFileTool = root_mod.read_file;
const SearchTool = root_mod.search_tool;
const GlobTool = root_mod.glob_tool;
const TextReplaceTool = root_mod.text_replace_tool;
const WriteFileTool = root_mod.write_file;
const ListSkillsTool = root_mod.list_skills_tool;
const GetSkillTool = root_mod.get_skill_tool;
const RemoveSkillTool = root_mod.remove_skill_tool;
const ListAgentsTool = root_mod.list_agents;
const ChangeAgentTool = root_mod.change_agent;
const TreeDirTool = root_mod.tree_dir;
const LspDefinitionTool = root_mod.tools.lspDefinitionTool;
const LspReferencesTool = root_mod.tools.lspReferencesTool;
const LspWorkspaceSymbolTool = root_mod.tools.lspWorkspaceSymbolTool;
const LspDocumentSymbolTool = root_mod.tools.lspDocumentSymbolTool;
const LspHoverTool = root_mod.tools.lspHoverTool;

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
    .{ .name = "set_agent_properties", .exec = handle_spawn_sub_agent.execSetAgentProperties, .tool_def = root_mod.tools.setAgentPropertiesTool, .allowed_for_subagent = false },
    .{ .name = "spawn_sub_agent", .exec = handle_spawn_sub_agent.execSpawnSubAgent, .tool_def = spawn_sub_agent_tool.tool, .allowed_for_subagent = false },

    // === AGENT MANAGEMENT (allowed for sub-agents, auto-save) ===
    .{ .name = "list_agents", .exec = handle_spawn_sub_agent.execListAgents, .tool_def = ListAgentsTool.listAgentsTool, .allowed_for_subagent = true, .auto_save_agent = true },
    .{ .name = "change_agent", .exec = handle_spawn_sub_agent.execChangeAgent, .tool_def = ChangeAgentTool.ChangeAgentTool, .allowed_for_subagent = true, .auto_save_agent = true },

    // === SKILL MANAGEMENT ===
    .{ .name = "list_skills", .exec = handle_spawn_sub_agent.execListSkills, .tool_def = ListSkillsTool.listSkillsTool, .allowed_for_subagent = true },
    .{ .name = "get_skill", .exec = handle_spawn_sub_agent.execGetSkill, .tool_def = GetSkillTool.getSkillTool, .allowed_for_subagent = true, .auto_save_skill = true },
    .{ .name = "remove_skill", .exec = handle_spawn_sub_agent.execRemoveSkill, .tool_def = RemoveSkillTool.removeSkillTool, .allowed_for_subagent = true },

    // === FILE OPERATIONS ===
    .{ .name = "bash", .exec = handle_spawn_sub_agent.execBash, .tool_def = BashTool.bashTool, .allowed_for_subagent = true },
    .{ .name = "read_file", .exec = handle_spawn_sub_agent.execReadFile, .tool_def = ReadFileTool.readFileTool, .allowed_for_subagent = true },
    .{ .name = "write_file", .exec = handle_spawn_sub_agent.execWriteFile, .tool_def = WriteFileTool.writeFileTool, .allowed_for_subagent = true },
    .{ .name = "text_replace", .exec = handle_spawn_sub_agent.execTextReplace, .tool_def = TextReplaceTool.textReplaceTool, .allowed_for_subagent = true },
    .{ .name = "search", .exec = handle_spawn_sub_agent.execSearch, .tool_def = SearchTool.searchTool, .allowed_for_subagent = true },
    .{ .name = "glob", .exec = handle_spawn_sub_agent.execGlob, .tool_def = GlobTool.globTool, .allowed_for_subagent = true },
    .{ .name = "tree_dir", .exec = handle_spawn_sub_agent.execTreeDir, .tool_def = TreeDirTool.tree_dir_tool, .allowed_for_subagent = true },

    // === LSP TOOLS ===
    .{ .name = "lsp_definition", .exec = handle_spawn_sub_agent.execLspDefinition, .tool_def = LspDefinitionTool, .allowed_for_subagent = true },
    .{ .name = "lsp_references", .exec = handle_spawn_sub_agent.execLspReferences, .tool_def = LspReferencesTool, .allowed_for_subagent = true },
    .{ .name = "lsp_workspace_symbol", .exec = handle_spawn_sub_agent.execLspWorkspaceSymbol, .tool_def = LspWorkspaceSymbolTool, .allowed_for_subagent = true },
    .{ .name = "lsp_document_symbol", .exec = handle_spawn_sub_agent.execLspDocumentSymbol, .tool_def = LspDocumentSymbolTool, .allowed_for_subagent = true },
    .{ .name = "lsp_hover", .exec = handle_spawn_sub_agent.execLspHover, .tool_def = LspHoverTool, .allowed_for_subagent = true },
};

// ============================================================================
// DERIVED REGISTRIES
// ============================================================================

/// Registry for main agent (all tools)
pub const MAIN_AGENT_TOOL_REGISTRY: []const ToolInfo = UNIFIED_TOOL_REGISTRY;

/// Registry for sub-agents (excludes dangerous tools like spawn_sub_agent, set_agent_properties)
pub const SUB_AGENT_TOOL_REGISTRY: []const ToolInfo = blk: {
    @setEvalBranchQuota(4000);
    var tools: [UNIFIED_TOOL_REGISTRY.len]ToolInfo = undefined;
    var count: usize = 0;
    for (UNIFIED_TOOL_REGISTRY) |tool| {
        if (tool.allowed_for_subagent) {
            tools[count] = tool;
            count += 1;
        }
    }
    break :blk tools[0..count];
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
