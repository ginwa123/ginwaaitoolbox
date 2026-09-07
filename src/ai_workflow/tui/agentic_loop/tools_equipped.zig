const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const helpers = @import("helpers");
const agent = nalarcore.agent;
const AgentTool = nalarcore.agent.AgentTool;

const read_file_mod = nalarcore.read_file;
const text_replace_mod = nalarcore.text_replace_tool;
const write_file_mod = nalarcore.write_file;
const list_skills_mod = nalarcore.list_skills_tool;
const memories_mod = nalarcore.memories;
const list_memory_mod = nalarcore.list_memory_tool;
const save_memory_mod = nalarcore.save_memory;
const load_memory_mod = nalarcore.load_memory;
const delete_memory_mod = nalarcore.delete_memory; // 2026-08-24-delete-memory-agent-tool
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
const move_element_to_page_mod = nalarcore.move_element_to_page;
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
const generate_image_mod = nalarcore.generate_image;
const update_activity_mod = nalarcore.update_activity;
// 2026-08-19 — session_plan agent tools (Task 4 of 2026-08-19-session-plan-agent-tool.md).
// Markdown task plan with - [ ] / - [x] checklist, persisted across iterations.
const update_plan_mod = nalarcore.update_plan;
const get_plan_mod = nalarcore.get_plan;
// 2026-08-28 — add_mcp_server agent tool (Step 5 of 2026-08-28-add-mcp-server-agent-tool.md).
// LLM-callable tool that registers a new MCP server in the live config +
// persists to disk + hot-reloads `di.llm_config` so the new server's tools
// appear on the next iteration's system prompt. v1 is stdio-only (HTTP lands
// in task_1787928601804_8 without changing the wire shape).
const add_mcp_server_mod = nalarcore.add_mcp_server;
const glob_tool_mod = nalarcore.glob_tool;
const search_tool_mod = nalarcore.search_tool;
// 2026-08-14 — list_directory tool (Task 5 of ban-absolute-paths plan).
const list_directory_mod = nalarcore.list_directory;
const semantic_search_mod = nalarcore.semantic_search;
const spawn_sub_agent_tool = nalarcore.spawn_sub_agent;
const kanban_create_task_tool = nalarcore.create_kanban_task;
const command_tool_mod = nalarcore.command_tool;
const xmlEscape = helpers.xml_escape;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;

pub fn equips(allocator: std.mem.Allocator) []const AgentTool {
    const tools_list = comptime &[_]AgentTool{
        spawn_sub_agent_tool.spawn_sub_agent_tool,
        update_activity_mod.update_activity_tool,
        // 2026-08-19 — session_plan tools (Task 4). The plan is
        // automatically re-injected into the system prompt on every
        // iteration, so the LLM sees the current checklist even
        // without calling get_plan. update_plan is the write-side,
        // get_plan is the read-side.
        update_plan_mod.update_plan_tool,
        get_plan_mod.get_plan_tool,
        // 2026-08-28 — add_mcp_server agent tool (Task 5).
        add_mcp_server_mod.add_mcp_server_tool,
        list_skills_mod.list_skills_tool,
        // list_memory_mod.list_memory_tool,
        save_memory_mod.save_memory_tool,
        load_memory_mod.load_memory_tool,
        delete_memory_mod.delete_memory_tool, // 2026-08-24-delete-memory-agent-tool
        search_history_mod.search_history_tool,
        view_skill_mod.view_skill_tool,
        get_skill_mod.get_skill_tool,
        remove_skill_mod.remove_skill_tool,
        add_skill_mod.add_skill_tool,
        edit_skill_mod.edit_skill_tool,
        command_tool_mod.command_tool,
        read_file_mod.read_file_tool,
        write_file_mod.write_file_tool,
        text_replace_mod.text_replace_tool,
        remove_file_mod.remove_file_tool,
        glob_tool_mod.glob_tool,
        search_tool_mod.search_tool,
        // 2026-08-14 — first-level ls-like tool (Task 5).
        list_directory_mod.list_directory_tool,
        nalar_browser_mod.nalar_browser_tool,
        generate_image_mod.generate_image_tool,
        set_git_worktree_mod.set_git_worktree_tool,
        show_preview_mod.show_preview_tool,

        // kanban only
        kanban_list_mod.kanban_list_tool,
        kanban_move_task_mod.kanban_move_task_tool,
        kanban_create_task_tool.create_kanban_task_tool,

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
        .{ .name = "set_agent_properties", .exec = tools.execSetAgentProperties, .tool_def = set_agent_properties_mod.set_agent_properties_tool },
        .{ .name = "spawn_sub_agent", .exec = tools.execSpawnSubAgent, .tool_def = spawn_sub_agent_tool.spawn_sub_agent_tool },
        .{ .name = "update_activity", .exec = tools.execUpdateActivity, .tool_def = update_activity_mod.update_activity_tool },

        // === PLAN TOOLS ===
        // 2026-08-19 — session_plan agent tools (Task 4 of
        // 2026-08-19-session-plan-agent-tool.md). The plan is a
        // markdown body with a `- [ ]` / `- [x]` checklist, UPSERTed
        // by update_plan and read by get_plan. Auto-injected into
        // the system prompt on every iteration (Task 5), so calling
        // get_plan is mostly for explicit verification.
        .{ .name = "update_plan", .exec = tools.execUpdatePlan, .tool_def = update_plan_mod.update_plan_tool },
        .{ .name = "get_plan", .exec = tools.execGetPlan, .tool_def = get_plan_mod.get_plan_tool },

        // === MCP MANAGEMENT ===
        // 2026-08-28 — add_mcp_server (Task 5 of 2026-08-28-add-mcp-server-agent-tool.md).
        // Registers a new MCP server in the live config + persists to disk +
        // hot-reloads `di.llm_config` so the new server's tools appear on
        // the next iteration's system prompt. v1 supports the `stdio`
        // transport only (HTTP lands in task_1787928601804_8).
        .{ .name = "add_mcp_server", .exec = tools.execAddMcpServer, .tool_def = add_mcp_server_mod.add_mcp_server_tool },

        // === AGENT MANAGEMENT (auto-save) ===

        // === SKILL MANAGEMENT ===
        .{ .name = "list_skills", .exec = tools.execListSkills, .tool_def = list_skills_mod.list_skills_tool },
        .{ .name = "view_skill", .exec = tools.execViewSkill, .tool_def = view_skill_mod.view_skill_tool },
        .{ .name = "get_skill", .exec = tools.execGetSkill, .tool_def = get_skill_mod.get_skill_tool, .auto_save_skill = true },
        .{ .name = "remove_skill", .exec = tools.execRemoveSkill, .tool_def = remove_skill_mod.remove_skill_tool },

        .{ .name = "add_skill", .exec = tools.execAddSkill, .tool_def = add_skill_mod.add_skill_tool, .auto_save_skill = true },
        .{ .name = "edit_skill", .exec = tools.execEditSkill, .tool_def = edit_skill_mod.edit_skill_tool },

        // === MEMORY TOOLS ===
        // .{ .name = "list_memory", .exec = tools.execListMemory, .tool_def = list_memory_mod.list_memory_tool },
        .{ .name = "save_memory", .exec = tools.execSaveMemory, .tool_def = save_memory_mod.save_memory_tool },
        .{ .name = "load_memory", .exec = tools.execLoadMemory, .tool_def = load_memory_mod.load_memory_tool },
        .{ .name = "delete_memory", .exec = tools.execDeleteMemory, .tool_def = delete_memory_mod.delete_memory_tool }, // 2026-08-24-delete-memory-agent-tool
        .{ .name = "search_history", .exec = tools.execSearchHistory, .tool_def = search_history_mod.search_history_tool },

        // === FILE OPERATIONS ===
        .{ .name = "command", .exec = tools.execCommand, .tool_def = command_tool_mod.command_tool },
        .{ .name = "read_file", .exec = tools.execReadFile, .tool_def = read_file_mod.read_file_tool },
        .{ .name = "write_file", .exec = tools.execWriteFile, .tool_def = write_file_mod.write_file_tool },
        .{ .name = "text_replace", .exec = tools.execTextReplace, .tool_def = text_replace_mod.text_replace_tool },
        .{ .name = "remove_file", .exec = tools.execRemoveFile, .tool_def = remove_file_mod.remove_file_tool },

        // === GIT WORKTREE BINDING ===
        .{ .name = "set_git_worktree", .exec = tools.execSetGitWorktree, .tool_def = set_git_worktree_mod.set_git_worktree_tool },

        // === KANBAN TOOLS ===
        // Both tools read directly from the DB (kanban_model.listColumns
        // + a new SELECT on workspace_item_tasks) instead of going
        // through the HTTP layer. This avoids the round-trip cost AND
        // works around the GET /tasks endpoint not returning
        // kanban table placement data directly (see project memory
        // nalar-image-urls-vs-image-url for the parallel image_url
        // situation).
        .{ .name = "kanban_list", .exec = tools.execKanbanList, .tool_def = kanban_list_mod.kanban_list_tool },
        .{ .name = "kanban_move_task", .exec = tools.execKanbanMoveTask, .tool_def = kanban_move_task_mod.kanban_move_task_tool },
        .{ .name = "create_kanban_task", .exec = tools.execCreateKanbanTask, .tool_def = kanban_create_task_tool.create_kanban_task_tool },

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
        .{ .name = "set_design_page", .exec = tools.execSetDesignPage, .tool_def = set_design_page_mod.set_design_page_tool },
        .{ .name = "add_element", .exec = tools.execAddElement, .tool_def = add_design_element_mod.add_design_element_tool },
        .{ .name = "update_element", .exec = tools.execUpdateElement, .tool_def = update_design_element_mod.update_design_element_tool },
        .{ .name = "group_elements", .exec = tools.execGroupElements, .tool_def = group_design_elements_mod.group_design_element_tool },
        .{ .name = "set_element_parent", .exec = tools.execSetElementParent, .tool_def = set_element_parent_mod.set_element_parent_tool },
        .{ .name = "move_design_element", .exec = tools.execMoveDesignElement, .tool_def = move_design_element_mod.move_design_element_tool },
        .{ .name = "move_element_to_page", .exec = tools.execMoveElementToPage, .tool_def = move_element_to_page_mod.move_element_to_page_tool },
        .{ .name = "get_design_context", .exec = tools.execGetDesignContext, .tool_def = get_design_context_mod.get_design_context_tool },
        .{ .name = "preview_design_page", .exec = tools.execPreviewDesignPage, .tool_def = preview_design_page_mod.preview_design_page_tool },

        // === PREVIEW TOOLS ===
        .{ .name = "show_preview", .exec = tools.execShowPreview, .tool_def = show_preview_mod.show_preview_tool },

        // === IMAGE GENERATION TOOLS ===
        // generate_image calls OpenAI's /v1/images/generations endpoint
        // (DALL-E 2/3 + gpt-image-1). Saves the result to disk and returns
        // a path; the agent calls show_preview next to display it.
        // Plan: docs/superpowers/plans/2026-08-14-generate-image-tool.md
        .{ .name = "generate_image", .exec = tools.execGenerateImage, .tool_def = generate_image_mod.generate_image_tool },

        // === LSP TOOLS ===
        .{ .name = "lsp_definition", .exec = tools.execLspDefinition, .tool_def = lsp_definition_mod.lsp_definition_tool },
        .{ .name = "lsp_references", .exec = tools.execLspReferences, .tool_def = lsp_references_mod.lsp_references_tool },
        .{ .name = "lsp_workspace_symbol", .exec = tools.execLspWorkspaceSymbol, .tool_def = lsp_workspace_symbol_mod.lsp_workspace_symbol_tool },
        .{ .name = "lsp_document_symbol", .exec = tools.execLspDocumentSymbol, .tool_def = lsp_document_symbol_mod.lsp_document_symbol_tool },
        .{ .name = "lsp_hover", .exec = tools.execLspHover, .tool_def = lsp_hover_mod.lsp_hover_tool },

        // === WEB SEARCH TOOLS ===
        // .{ .name = "web_search", .exec = tools.execWebSearch, .tool_def = web_search_mod.web_search_tool },
        .{ .name = "nalar_browser", .exec = tools.execNalarBrowser, .tool_def = nalar_browser_mod.nalar_browser_tool },

        // === FILE SEARCH TOOLS ===
        .{ .name = "glob", .exec = tools.execGlob, .tool_def = glob_tool_mod.glob_tool },
        .{ .name = "search", .exec = tools.execSearch, .tool_def = search_tool_mod.search_tool },
        // 2026-08-14 — first-level ls-like tool (Task 5 of ban-absolute-paths plan).
        .{ .name = "list_directory", .exec = tools.execListDirectory, .tool_def = list_directory_mod.list_directory_tool },
        // .{ .name = "semantic_search", .exec = execSemanticSearch, .tool_def = semantic_search_mod.semantic_search_tool },
        // .{ .name = "index_codebase", .exec = execIndexCodebase, .tool_def = semantic_search_mod.index_codebase_tool },
    };
}

// =====================================================================
// Default tools seeded at workspace-item creation (2026-09-06).
// Fresh `agent` / `kanban` items are born with a small, safe,
// immediately-useful toolset so the user can chat/run without opening
// the Tools tab first. Mirrors the frontend preset
// (`KanbanToolsPanel.vue:76-79` RECOMMENDED_TOOLS) — backend and UI agree.
// `command` is the unified shell (bash/pwsh were removed 2026-09-04).
// Plan: docs/superpowers/plans/2026-09-06-default-agent-tools-on-creation.md
// =====================================================================

/// Canonical default toolset seeded on creation. Single source of truth —
/// both `workspace_items_create_agent.zig` and
/// `workspace_items_create_kanban.zig` seed exactly this list.
pub const DEFAULT_AGENT_TOOLS: []const []const u8 = &.{
    // basic tools
    command_tool_mod.command_tool.function.name,
    read_file_mod.read_file_tool.function.name,
    write_file_mod.write_file_tool.function.name,
    text_replace_mod.text_replace_tool.function.name,
    remove_file_mod.remove_file_tool.function.name,
    list_directory_mod.list_directory_tool.function.name,
    search_tool_mod.search_tool.function.name,

    // for context-aware tools
    update_plan_mod.update_plan_tool.function.name,
    get_plan_mod.get_plan_tool.function.name,
    update_activity_mod.update_activity_tool.function.name,

    // for memory tools // addon
    save_memory_mod.save_memory_tool.function.name,
    load_memory_mod.load_memory_tool.function.name,
    delete_memory_mod.delete_memory_tool.function.name, 
    search_history_mod.search_history_tool.function.name,


    // skill tools
    get_skill_mod.get_skill_tool.function.name,
    view_skill_mod.view_skill_tool.function.name,
    remove_skill_mod.remove_skill_tool.function.name,
    add_skill_mod.add_skill_tool.function.name,
    edit_skill_mod.edit_skill_tool.function.name,
    list_skills_mod.list_skills_tool.function.name,

    // spawn
    spawn_sub_agent_tool.spawn_sub_agent_tool.function.name,
};

pub const DEFAULT_KANBAN_TOOLS: []const []const u8 = &.{
    kanban_list_mod.kanban_list_tool.function.name,
    kanban_move_task_mod.kanban_move_task_tool.function.name,
};

/// Seed DEFAULT_AGENT_TOOLS into `agent_tools` for `agent_id`.
/// Uses `INSERT OR IGNORE` so re-seeding never trips
/// UNIQUE(agent_id, tool_name). Ids are `at_<nanos>_<index>` (matches the
/// `at_<nanos>` convention in `agent_tools_create.zig`, index-suffixed so
/// the 3 rows in one call can't collide on the PK).
pub fn seedDefaultAgentTools(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    agent_id: []const u8,
) !void {
    const ts = helpers.unixTimestampNanos();
    for (DEFAULT_AGENT_TOOLS, 0..) |tool_name, i| {
        const id = try std.fmt.allocPrint(allocator, "at_{d}_{d}", .{ ts, i });
        defer allocator.free(id);
        try db.exec(allocator,
            "INSERT OR IGNORE INTO agent_tools (id, agent_id, tool_name, enabled, created_at) VALUES (?, ?, ?, 1, datetime('now'))",
            &.{ id, agent_id, tool_name },
        );
    }
}

/// Seed DEFAULT_AGENT_TOOLS into `agent_kanban_tools` for `kanban_id`.
/// Same contract as `seedDefaultAgentTools` with the kanban table shape
/// (`akt_<nanos>_<index>`, UNIQUE(kanban_id, tool_name)).
pub fn seedDefaultKanbanTools(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    kanban_id: []const u8,
) !void {
    const ts = helpers.unixTimestampNanos();
    for (DEFAULT_AGENT_TOOLS, 0..) |tool_name, i| {
        const id = try std.fmt.allocPrint(allocator, "akt_{d}_{d}", .{ ts, i });
        defer allocator.free(id);
        try db.exec(allocator,
            "INSERT OR IGNORE INTO agent_kanban_tools (id, kanban_id, tool_name, enabled, created_at) VALUES (?, ?, ?, 1, datetime('now'))",
            &.{ id, kanban_id, tool_name },
        );
    }

    for (DEFAULT_KANBAN_TOOLS, 0..) |tool_name, i| {
        const id = try std.fmt.allocPrint(allocator, "akt_{d}_{d}", .{ ts, i });
        defer allocator.free(id);
        try db.exec(allocator,
            "INSERT OR IGNORE INTO agent_kanban_tools (id, kanban_id, tool_name, enabled, created_at) VALUES (?, ?, ?, 1, datetime('now'))",
            &.{ id, kanban_id, tool_name },
        );
    }
}

