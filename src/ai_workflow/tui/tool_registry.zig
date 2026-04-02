const std = @import("std");
const root_mod = @import("nalarcore");
const agent = root_mod.agent;
const tool_models = root_mod.tool_models;

// ============================================================================
// UNIFIED TOOL REGISTRY - Single source of truth for ALL tool metadata
// ============================================================================

/// Metadata for each tool in the unified registry
pub const ToolInfo = struct {
    name: []const u8,
    allowed_for_subagent: bool = true,
    auto_save_skill: bool = false,
    auto_save_agent: bool = false,
};

/// The ONE registry for all tool metadata.
/// `allowed_for_subagent = false` excludes dangerous tools (spawn_sub_agent, set_agent_properties).
pub const UNIFIED_TOOL_REGISTRY: []const ToolInfo = &.{
    // === AGENT CONTROL (not allowed for sub-agents) ===
    .{ .name = "set_agent_properties", .allowed_for_subagent = false },
    .{ .name = "spawn_sub_agent", .allowed_for_subagent = false },

    // === AGENT MANAGEMENT (allowed for sub-agents, auto-save) ===
    .{ .name = "list_agents", .allowed_for_subagent = true, .auto_save_agent = true },
    .{ .name = "change_agent", .allowed_for_subagent = true, .auto_save_agent = true },

    // === SKILL MANAGEMENT ===
    .{ .name = "list_skills", .allowed_for_subagent = true },
    .{ .name = "get_skill", .allowed_for_subagent = true, .auto_save_skill = true },
    .{ .name = "remove_skill", .allowed_for_subagent = true },

    // === FILE OPERATIONS ===
    .{ .name = "bash", .allowed_for_subagent = true },
    .{ .name = "read_file", .allowed_for_subagent = true },
    .{ .name = "write_file", .allowed_for_subagent = true },
    .{ .name = "text_replace", .allowed_for_subagent = true },
    .{ .name = "search", .allowed_for_subagent = true },
    .{ .name = "glob", .allowed_for_subagent = true },
    .{ .name = "tree_dir", .allowed_for_subagent = true },

    // === LSP TOOLS ===
    .{ .name = "lsp_definition", .allowed_for_subagent = true },
    .{ .name = "lsp_references", .allowed_for_subagent = true },
    .{ .name = "lsp_workspace_symbol", .allowed_for_subagent = true },
    .{ .name = "lsp_document_symbol", .allowed_for_subagent = true },
    .{ .name = "lsp_hover", .allowed_for_subagent = true },
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
