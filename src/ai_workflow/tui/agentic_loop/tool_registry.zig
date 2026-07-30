const std = @import("std");
const nalar_mod = @import("nalarcore");
const models = @import("../models.zig");
const helpers = nalar_mod.helpers;
const agent = nalar_mod.agent;
const tool_models = nalar_mod.tool_models;
const sqlite = nalar_mod.sqlite;
const logger_mod = nalar_mod.loggermod;
const config_mod = nalar_mod.config;
const llm_history = nalar_mod.llm_history;

// Tool imports for tool_defs (the exec functions live in
// agentic_loop/tools_exec_*.zig and are re-exported via
// agentic_loop_mod.tools).
const bash_tool_mod = nalar_mod.bash_tool;
const read_file_mod = nalar_mod.read_file;
const text_replace_mod = nalar_mod.text_replace_tool;
const write_file_mod = nalar_mod.write_file;
const list_skills_mod = nalar_mod.list_skills_tool;
const memories_mod = nalar_mod.memories;
const list_memory_mod = nalar_mod.list_memory_tool;
const search_history_mod = nalar_mod.search_history_tool;
const get_skill_mod = nalar_mod.get_skill_tool;
const view_skill_mod = nalar_mod.view_skill_tool;
const remove_skill_mod = nalar_mod.remove_skill_tool;
const list_agents_mod = nalar_mod.list_agents;
const add_skill_mod = nalar_mod.add_skill;
const edit_skill_mod = nalar_mod.edit_skill;
const set_git_worktree_mod = nalar_mod.set_git_worktree;
const kanban_list_mod = nalar_mod.kanban_list;
const kanban_move_task_mod = nalar_mod.kanban_move_task;
const create_kanban_task_mod = nalar_mod.create_kanban_task;
const set_design_page_mod = nalar_mod.set_design_page;
const add_design_element_mod = nalar_mod.add_design_element;
const update_design_element_mod = nalar_mod.update_design_element;
const group_design_elements_mod = nalar_mod.group_design_elements;
const set_element_parent_mod = nalar_mod.set_element_parent;
const show_preview_mod = nalar_mod.ai_mod.show_preview;
const remove_agent_mod = nalar_mod.remove_agent;
const remove_file_mod = nalar_mod.remove_file;
const change_agent_mod = nalar_mod.change_agent;
const lsp_definition_mod = nalar_mod.tools.lsp_definition;
const lsp_references_mod = nalar_mod.tools.lsp_references;
const lsp_workspace_symbol_mod = nalar_mod.tools.lsp_workspace_symbol;
const lsp_document_symbol_mod = nalar_mod.tools.lsp_document_symbol;
const lsp_hover_mod = nalar_mod.tools.lsp_hover;
const set_agent_properties_mod = nalar_mod.set_agent_properties;
const web_search_mod = nalar_mod.web_search;
const nalar_browser_mod = nalar_mod.nalar_browser;
const update_activity_mod = nalar_mod.update_activity;
const glob_tool_mod = nalar_mod.glob_tool;
const search_tool_mod = nalar_mod.search_tool;
const semantic_search_mod = nalar_mod.semantic_search;
const spawn_sub_agent_tool = nalar_mod.spawn_sub_agent;
const xmlEscape = helpers.xml_escape;

// agentic_loop_mod re-exports the migrated exec functions and the
// shared ToolExecContext / ToolExecResult / wrapToolOutput.
const agentic_loop_mod = nalar_mod.agentic_loop_mod;

// ============================================================================
// RE-EXPORTS for backward compatibility
// ============================================================================
//
// These were previously defined in tool_registry.zig. They've been
// moved to `agentic_loop/tools.zig` (the canonical home after the
// migration) and are re-exported here so existing callers
// (handle_tool.zig, the static-contract tests, etc.) keep working
// without rewrites.

/// Standardized tool output envelope helper.
pub const wrapToolOutput = agentic_loop_mod.tools.wrapToolOutput;

/// Context passed to all tool handlers.
pub const ToolExecContext = agentic_loop_mod.tools.ToolExecContext;

/// Tool execution result with optional agent state changes.
pub const ToolExecResult = agentic_loop_mod.tools.ToolExecResult;

/// Re-export SkillSaveInfo so callers can name the type without
/// reaching into agentic_loop.
pub const SkillSaveInfo = struct {
    name: []const u8,
    content: []const u8,
};

/// Re-export AgentSaveInfo so callers can name the type without
/// reaching into agentic_loop.
pub const AgentSaveInfo = struct {
    name: []const u8,
};

/// Legacy alias for backward compatibility.
pub const SubAgentToolResult = ToolExecResult;

/// Function signature for tool executors.
/// Takes full context to enable tools like set_agent_properties and spawn_sub_agent
pub const ToolExecFunc = *const fn (ctx: ToolExecContext, tc: agent.ToolCall) anyerror!ToolExecResult;

// ============================================================================
// STANDARDIZED TOOL OUTPUT ENVELOPE
// ============================================================================

// ============================================================================
// UNIFIED TOOL REGISTRY - Single source of truth for ALL tool metadata
// ============================================================================

/// Metadata for each tool in the unified registry
pub const ToolInfo = struct {
    name: []const u8,
    exec: ToolExecFunc,
    tool_def: tool_models.AgentTool,
    auto_save_skill: bool = false,
    auto_save_agent: bool = false,
};

/// The ONE registry for all tool metadata.
/// All exec functions are now in `agentic_loop/tools_exec_*.zig` and
/// re-exported via `agentic_loop_mod.tools.execXxx`.
pub fn UNIFIED_TOOL_REGISTRY() []const ToolInfo {
    return &.{
        // === AGENT CONTROL (main agent only) ===
        .{ .name = "set_agent_properties", .exec = agentic_loop_mod.tools.execSetAgentProperties, .tool_def = set_agent_properties_mod.set_agent_properties_tool },
        .{ .name = "spawn_sub_agent", .exec = agentic_loop_mod.tools.execSpawnSubAgent, .tool_def = spawn_sub_agent_tool.spawn_sub_agent_tool },
        .{ .name = "update_activity", .exec = agentic_loop_mod.tools.execUpdateActivity, .tool_def = update_activity_mod.update_activity_tool },

        // === AGENT MANAGEMENT (auto-save) ===

        // === SKILL MANAGEMENT ===
        .{ .name = "list_skills", .exec = agentic_loop_mod.tools.execListSkills, .tool_def = list_skills_mod.list_skills_tool },
        .{ .name = "view_skill", .exec = agentic_loop_mod.tools.execViewSkill, .tool_def = view_skill_mod.view_skill_tool },
        .{ .name = "get_skill", .exec = agentic_loop_mod.tools.execGetSkill, .tool_def = get_skill_mod.get_skill_tool, .auto_save_skill = true },
        .{ .name = "remove_skill", .exec = agentic_loop_mod.tools.execRemoveSkill, .tool_def = remove_skill_mod.remove_skill_tool },

        .{ .name = "add_skill", .exec = agentic_loop_mod.tools.execAddSkill, .tool_def = add_skill_mod.add_skill_tool, .auto_save_skill = true },
        .{ .name = "edit_skill", .exec = agentic_loop_mod.tools.execEditSkill, .tool_def = edit_skill_mod.edit_skill_tool },

        // === MEMORY TOOLS ===
        .{ .name = "list_memory", .exec = agentic_loop_mod.tools.execListMemory, .tool_def = list_memory_mod.list_memory_tool },
        .{ .name = "search_history", .exec = agentic_loop_mod.tools.execSearchHistory, .tool_def = search_history_mod.search_history_tool },

        // === FILE OPERATIONS ===
        .{ .name = "bash", .exec = agentic_loop_mod.tools.execBash, .tool_def = bash_tool_mod.bash_tool },
        .{ .name = "read_file", .exec = agentic_loop_mod.tools.execReadFile, .tool_def = read_file_mod.read_file_tool },
        .{ .name = "write_file", .exec = agentic_loop_mod.tools.execWriteFile, .tool_def = write_file_mod.write_file_tool },
        .{ .name = "text_replace", .exec = agentic_loop_mod.tools.execTextReplace, .tool_def = text_replace_mod.text_replace_tool },
        .{ .name = "remove_file", .exec = agentic_loop_mod.tools.execRemoveFile, .tool_def = remove_file_mod.remove_file_tool },

        // === GIT WORKTREE BINDING ===
        .{ .name = "set_git_worktree", .exec = agentic_loop_mod.tools.execSetGitWorktree, .tool_def = set_git_worktree_mod.set_git_worktree_tool },

        // === KANBAN TOOLS ===
        // Both tools read directly from the DB (kanban_model.listColumns
        // + a new SELECT on workspace_item_tasks) instead of going
        // through the HTTP layer. This avoids the round-trip cost AND
        // works around the GET /tasks endpoint not returning
        // kanban_column_id / kanban_position (see project memory
        // nalar-image-urls-vs-image-url for the parallel image_url
        // situation).
        .{ .name = "kanban_list", .exec = agentic_loop_mod.tools.execKanbanList, .tool_def = kanban_list_mod.kanban_list_tool },
        .{ .name = "kanban_move_task", .exec = agentic_loop_mod.tools.execKanbanMoveTask, .tool_def = kanban_move_task_mod.kanban_move_task_tool },
        .{ .name = "create_kanban_task", .exec = agentic_loop_mod.tools.execCreateKanbanTask, .tool_def = create_kanban_task_mod.create_kanban_task_tool },

        // === DESIGN TOOLS ===
        // Three tools cover the v6 design mode LLM surface:
        //   set_design_page  — idempotent create/update for a page,
        //                      returns page + elements (no HTML bodies).
        //   add_element      — creates a new positioned element on a page,
        //                      writes the HTML body to disk atomically.
        //   update_element   — partial-update for an existing element
        //                      (only the fields the LLM provides change).
        //
        // All three read directly from the DB via design_model.* helpers
        // (matching the kanban tool pattern). They do NOT go through the
        // HTTP layer — this avoids the round-trip cost AND keeps the
        // tool's envelope (XML with `<error>` blocks) consistent.
        .{ .name = "set_design_page", .exec = agentic_loop_mod.tools.execSetDesignPage, .tool_def = set_design_page_mod.set_design_page_tool },
        .{ .name = "add_element", .exec = agentic_loop_mod.tools.execAddElement, .tool_def = add_design_element_mod.add_design_element_tool },
        .{ .name = "update_element", .exec = agentic_loop_mod.tools.execUpdateElement, .tool_def = update_design_element_mod.update_design_element_tool },
        .{ .name = "group_elements", .exec = agentic_loop_mod.tools.execGroupElements, .tool_def = group_design_elements_mod.group_design_element_tool },
        .{ .name = "set_element_parent", .exec = agentic_loop_mod.tools.execSetElementParent, .tool_def = set_element_parent_mod.set_element_parent_tool },

        // === PREVIEW TOOLS ===
        .{ .name = "show_preview", .exec = agentic_loop_mod.tools.execShowPreview, .tool_def = show_preview_mod.show_preview_tool },

        // === LSP TOOLS ===
        .{ .name = "lsp_definition", .exec = agentic_loop_mod.tools.execLspDefinition, .tool_def = lsp_definition_mod.lsp_definition_tool },
        .{ .name = "lsp_references", .exec = agentic_loop_mod.tools.execLspReferences, .tool_def = lsp_references_mod.lsp_references_tool },
        .{ .name = "lsp_workspace_symbol", .exec = agentic_loop_mod.tools.execLspWorkspaceSymbol, .tool_def = lsp_workspace_symbol_mod.lsp_workspace_symbol_tool },
        .{ .name = "lsp_document_symbol", .exec = agentic_loop_mod.tools.execLspDocumentSymbol, .tool_def = lsp_document_symbol_mod.lsp_document_symbol_tool },
        .{ .name = "lsp_hover", .exec = agentic_loop_mod.tools.execLspHover, .tool_def = lsp_hover_mod.lsp_hover_tool },

        // === WEB SEARCH TOOLS ===
        // .{ .name = "web_search", .exec = agentic_loop_mod.tools.execWebSearch, .tool_def = web_search_mod.web_search_tool },
        .{ .name = "nalar_browser", .exec = agentic_loop_mod.tools.execNalarBrowser, .tool_def = nalar_browser_mod.nalar_browser_tool },

        // === FILE SEARCH TOOLS ===
        .{ .name = "glob", .exec = agentic_loop_mod.tools.execGlob, .tool_def = glob_tool_mod.glob_tool },
        .{ .name = "search", .exec = agentic_loop_mod.tools.execSearch, .tool_def = search_tool_mod.search_tool },
        // .{ .name = "semantic_search", .exec = execSemanticSearch, .tool_def = semantic_search_mod.semantic_search_tool },
        // .{ .name = "index_codebase", .exec = execIndexCodebase, .tool_def = semantic_search_mod.index_codebase_tool },
    };
}

// ============================================================================
// DERIVED REGISTRIES
// ============================================================================

/// Registry for main agent (all tools)
/// Get tool metadata by name from registry
pub fn getToolByName(name: []const u8) ?*const ToolInfo {
    for (UNIFIED_TOOL_REGISTRY()) |*tool| {
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
    const unified = UNIFIED_TOOL_REGISTRY();
    const names = comptime blk: {
        var n: [unified.len][]const u8 = undefined;
        for (unified, 0..) |tool, i| {
            n[i] = tool.name;
        }
        break :blk n;
    };
    return &names;
}
