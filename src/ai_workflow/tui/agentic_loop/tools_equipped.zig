const std = @import("std");
const mod = @import("mod.zig");
const nalarcore = mod.nalarcore;
const helpers = nalarcore.helpers;
const agent = nalarcore.agent;
const AgentTool = nalarcore.agent.AgentTool;

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
const get_design_context_mod = nalarcore.get_design_context;
const preview_design_page_mod = nalarcore.preview_design_page;
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
const kanban_create_task_tool = nalarcore.create_kanban_task_tool;
const xmlEscape = helpers.xml_escape;
const ToolExecContext = mod.tools.ToolExecContext;
const ToolExecResult = mod.tools.ToolExecResult;

pub fn equips(allocator: std.mem.Allocator) []const AgentTool {
    const tools_list = comptime &[_]AgentTool{
        spawn_sub_agent_tool.spawn_sub_agent_tool,
        update_activity_mod.update_activity_tool,
        list_skills_mod.list_skills_tool,
        list_memory_mod.list_memory_tool,
        search_history_mod.search_history_tool,
        view_skill_mod.view_skill_tool,
        get_skill_mod.get_skill_tool,
        remove_skill_mod.remove_skill_tool,
        add_skill_mod.add_skill_tool,
        edit_skill_mod.edit_skill_tool,
        bash_tool_mod.bash_tool,
        read_file_mod.read_file_tool,
        write_file_mod.write_file_tool,
        text_replace_mod.text_replace_tool,
        remove_file_mod.remove_file_tool,
        glob_tool_mod.glob_tool,
        search_tool_mod.search_tool,
        nalar_browser_mod.nalar_browser_tool,
        set_git_worktree_mod.set_git_worktree_tool,
        show_preview_mod.show_preview_tool,

        // kanban only
        kanban_list_mod.kanban_list_tool,
        kanban_move_task_mod.kanban_move_task_tool,

        // design only
        set_design_page_mod.set_design_page_tool,
        add_design_element_mod.add_design_element_tool,
        update_design_element_mod.update_design_element_tool,
        group_design_elements_mod.group_design_element_tool,
        set_element_parent_mod.set_element_parent_tool,
        move_design_element_mod.move_design_element_tool,
        get_design_context_mod.get_design_context_tool,
        preview_design_page_mod.preview_design_page_tool,
    };
    return allocator.dupe(AgentTool, tools_list) catch return &.{};
}


pub const ToolExecFunc = *const fn (ctx: ToolExecContext, tc: agent.ToolCall) anyerror!ToolExecResult;

pub const ToolInfo = struct {
    name: []const u8,
    exec: ToolExecFunc,
    tool_def: AgentTool,
    auto_save_skill: bool = false,
    auto_save_agent: bool = false,
};


pub fn UNIFIED_TOOL_REGISTRY() []const ToolInfo {
    return &.{
        // === AGENT CONTROL (main agent only) ===
        .{ .name = "set_agent_properties", .exec = mod.tools.execSetAgentProperties, .tool_def = set_agent_properties_mod.set_agent_properties_tool },
        .{ .name = "spawn_sub_agent", .exec = mod.tools.execSpawnSubAgent, .tool_def = spawn_sub_agent_tool.spawn_sub_agent_tool },
        .{ .name = "update_activity", .exec = mod.tools.execUpdateActivity, .tool_def = update_activity_mod.update_activity_tool },

        // === AGENT MANAGEMENT (auto-save) ===

        // === SKILL MANAGEMENT ===
        .{ .name = "list_skills", .exec = mod.tools.execListSkills, .tool_def = list_skills_mod.list_skills_tool },
        .{ .name = "view_skill", .exec = mod.tools.execViewSkill, .tool_def = view_skill_mod.view_skill_tool },
        .{ .name = "get_skill", .exec = mod.tools.execGetSkill, .tool_def = get_skill_mod.get_skill_tool, .auto_save_skill = true },
        .{ .name = "remove_skill", .exec = mod.tools.execRemoveSkill, .tool_def = remove_skill_mod.remove_skill_tool },

        .{ .name = "add_skill", .exec = mod.tools.execAddSkill, .tool_def = add_skill_mod.add_skill_tool, .auto_save_skill = true },
        .{ .name = "edit_skill", .exec = mod.tools.execEditSkill, .tool_def = edit_skill_mod.edit_skill_tool },

        // === MEMORY TOOLS ===
        .{ .name = "list_memory", .exec = mod.tools.execListMemory, .tool_def = list_memory_mod.list_memory_tool },
        .{ .name = "search_history", .exec = mod.tools.execSearchHistory, .tool_def = search_history_mod.search_history_tool },

        // === FILE OPERATIONS ===
        .{ .name = "bash", .exec = mod.tools.execBash, .tool_def = bash_tool_mod.bash_tool },
        .{ .name = "read_file", .exec = mod.tools.execReadFile, .tool_def = read_file_mod.read_file_tool },
        .{ .name = "write_file", .exec = mod.tools.execWriteFile, .tool_def = write_file_mod.write_file_tool },
        .{ .name = "text_replace", .exec = mod.tools.execTextReplace, .tool_def = text_replace_mod.text_replace_tool },
        .{ .name = "remove_file", .exec = mod.tools.execRemoveFile, .tool_def = remove_file_mod.remove_file_tool },

        // === GIT WORKTREE BINDING ===
        .{ .name = "set_git_worktree", .exec = mod.tools.execSetGitWorktree, .tool_def = set_git_worktree_mod.set_git_worktree_tool },

        // === KANBAN TOOLS ===
        // Both tools read directly from the DB (kanban_model.listColumns
        // + a new SELECT on workspace_item_tasks) instead of going
        // through the HTTP layer. This avoids the round-trip cost AND
        // works around the GET /tasks endpoint not returning
        // kanban_column_id / kanban_position (see project memory
        // nalar-image-urls-vs-image-url for the parallel image_url
        // situation).
        .{ .name = "kanban_list", .exec = mod.tools.execKanbanList, .tool_def = kanban_list_mod.kanban_list_tool },
        .{ .name = "kanban_move_task", .exec = mod.tools.execKanbanMoveTask, .tool_def = kanban_move_task_mod.kanban_move_task_tool },
        .{ .name = "create_kanban_task", .exec = mod.tools.execCreateKanbanTask, .tool_def = kanban_create_task_tool.create_kanban_task_tool },

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
        .{ .name = "set_design_page", .exec = mod.tools.execSetDesignPage, .tool_def = set_design_page_mod.set_design_page_tool },
        .{ .name = "add_element", .exec = mod.tools.execAddElement, .tool_def = add_design_element_mod.add_design_element_tool },
        .{ .name = "update_element", .exec = mod.tools.execUpdateElement, .tool_def = update_design_element_mod.update_design_element_tool },
        .{ .name = "group_elements", .exec = mod.tools.execGroupElements, .tool_def = group_design_elements_mod.group_design_element_tool },
        .{ .name = "set_element_parent", .exec = mod.tools.execSetElementParent, .tool_def = set_element_parent_mod.set_element_parent_tool },
        .{ .name = "move_design_element", .exec = mod.tools.execMoveDesignElement, .tool_def = move_design_element_mod.move_design_element_tool },
        .{ .name = "get_design_context", .exec = mod.tools.execGetDesignContext, .tool_def = get_design_context_mod.get_design_context_tool },
        .{ .name = "preview_design_page", .exec = mod.tools.execPreviewDesignPage, .tool_def = preview_design_page_mod.preview_design_page_tool },

        // === PREVIEW TOOLS ===
        .{ .name = "show_preview", .exec = mod.tools.execShowPreview, .tool_def = show_preview_mod.show_preview_tool },

        // === LSP TOOLS ===
        .{ .name = "lsp_definition", .exec = mod.tools.execLspDefinition, .tool_def = lsp_definition_mod.lsp_definition_tool },
        .{ .name = "lsp_references", .exec = mod.tools.execLspReferences, .tool_def = lsp_references_mod.lsp_references_tool },
        .{ .name = "lsp_workspace_symbol", .exec = mod.tools.execLspWorkspaceSymbol, .tool_def = lsp_workspace_symbol_mod.lsp_workspace_symbol_tool },
        .{ .name = "lsp_document_symbol", .exec = mod.tools.execLspDocumentSymbol, .tool_def = lsp_document_symbol_mod.lsp_document_symbol_tool },
        .{ .name = "lsp_hover", .exec = mod.tools.execLspHover, .tool_def = lsp_hover_mod.lsp_hover_tool },

        // === WEB SEARCH TOOLS ===
        // .{ .name = "web_search", .exec = mod.tools.execWebSearch, .tool_def = web_search_mod.web_search_tool },
        .{ .name = "nalar_browser", .exec = mod.tools.execNalarBrowser, .tool_def = nalar_browser_mod.nalar_browser_tool },

        // === FILE SEARCH TOOLS ===
        .{ .name = "glob", .exec = mod.tools.execGlob, .tool_def = glob_tool_mod.glob_tool },
        .{ .name = "search", .exec = mod.tools.execSearch, .tool_def = search_tool_mod.search_tool },
        // .{ .name = "semantic_search", .exec = execSemanticSearch, .tool_def = semantic_search_mod.semantic_search_tool },
        // .{ .name = "index_codebase", .exec = execIndexCodebase, .tool_def = semantic_search_mod.index_codebase_tool },
    };
}

