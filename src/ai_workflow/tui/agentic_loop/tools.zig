const std = @import("std");
const nalarcore = @import("nalarcore");

const logger_mod = nalarcore.loggermod;
const sqlite = nalarcore.sqlite;
const config_mod = nalarcore.config;
const ActiveLoops = @import("../ActiveLoops.zig").ActiveLoops;

pub const all_agent_tools = @import("tools_equipped.zig").equips;
pub const wrapToolOutput = @import("tools_wrap_output.zig").wrapToolOutput;

// Re-export every migrated exec function. Tool_Registry.zig references
// these via `agentic_loop_mod.tools.execXxx` etc.
pub const execReadFile = @import("tools_exec_read_file.zig").execReadFile;
pub const execTextReplace = @import("tools_exec_text_replace.zig").execTextReplace;
pub const execWriteFile = @import("tools_exec_write_file.zig").execWriteFile;
pub const execListSkills = @import("tools_exec_list_skills.zig").execListSkills;
pub const execListMemory = @import("tools_exec_list_memory.zig").execListMemory;
pub const execSearchHistory = @import("tools_exec_search_history.zig").execSearchHistory;
pub const execGetSkill = @import("tools_exec_get_skill.zig").execGetSkill;
pub const execViewSkill = @import("tools_exec_view_skill.zig").execViewSkill;
pub const execRemoveSkill = @import("tools_exec_remove_skill.zig").execRemoveSkill;
pub const execAddSkill = @import("tools_exec_add_skill.zig").execAddSkill;
pub const execEditSkill = @import("tools_exec_edit_skill.zig").execEditSkill;
pub const execRemoveAgent = @import("tools_exec_remove_agent.zig").execRemoveAgent;
pub const execRemoveFile = @import("tools_exec_remove_file.zig").execRemoveFile;
pub const execListAgents = @import("tools_exec_list_agents.zig").execListAgents;
pub const execChangeAgent = @import("tools_exec_change_agent.zig").execChangeAgent;
pub const execSetGitWorktree = @import("tools_exec_set_git_worktree.zig").execSetGitWorktree;
pub const execKanbanList = @import("tools_exec_kanban_list.zig").execKanbanList;
pub const execKanbanMoveTask = @import("tools_exec_kanban_move_task.zig").execKanbanMoveTask;
pub const execCreateKanbanTask = @import("tools_exec_create_kanban_task.zig").execCreateKanbanTask;
pub const execSetDesignPage = @import("tools_exec_set_design_page.zig").execSetDesignPage;
pub const execAddElement = @import("tools_exec_add_element.zig").execAddElement;
pub const execUpdateElement = @import("tools_exec_update_element.zig").execUpdateElement;
pub const execGroupElements = @import("tools_exec_group_elements.zig").execGroupElements;
pub const execSetElementParent = @import("tools_exec_set_element_parent.zig").execSetElementParent;
pub const execMoveDesignElement = @import("tools_exec_move_design_element.zig").execMoveDesignElement;
pub const execShowPreview = @import("tools_exec_show_preview.zig").execShowPreview;
pub const execGetDesignContext = @import("tools_exec_get_design_context.zig").execGetDesignContext;
pub const execPreviewDesignPage = @import("tools_exec_preview_design_page.zig").execPreviewDesignPage;
pub const execLspDefinition = @import("tools_exec_lsp_definition.zig").execLspDefinition;
pub const execLspReferences = @import("tools_exec_lsp_references.zig").execLspReferences;
pub const execLspWorkspaceSymbol = @import("tools_exec_lsp_workspace_symbol.zig").execLspWorkspaceSymbol;
pub const execLspDocumentSymbol = @import("tools_exec_lsp_document_symbol.zig").execLspDocumentSymbol;
pub const execLspHover = @import("tools_exec_lsp_hover.zig").execLspHover;
pub const execWebSearch = @import("tools_exec_web_search.zig").execWebSearch;
pub const execNalarBrowser = @import("tools_exec_nalar_browser.zig").execNalarBrowser;
pub const execGlob = @import("tools_exec_glob.zig").execGlob;
pub const execSearch = @import("tools_exec_search.zig").execSearch;
pub const execBash = @import("tools_exec_bash.zig").execBash;
pub const execSetAgentProperties = @import("tools_exec_set_agent_properties.zig").execSetAgentProperties;
pub const execUpdateActivity = @import("tools_exec_update_activity.zig").execUpdateActivity;
pub const execSpawnSubAgent = @import("tools_exec_spawn_sub_agent.zig").execSpawnSubAgent;

pub const SkillSaveInfo = struct {
    name: []const u8,
    content: []const u8,
};

pub const AgentSaveInfo = struct {
    name: []const u8,
};

pub const ToolExecContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    api_key: []const u8,
    base_url: []const u8,
    config: *const config_mod.LlmConfig,
    agent_temperature: *f32,
    is_thinking: *bool,
    environment: ?*const std.process.Environ.Map,
    active_loops: *ActiveLoops,
    selected_profile_model: []const u8 = "",
    cwd_override: ?[]const u8 = null,
};

pub const ToolExecResult = struct {
    output: []const u8,
    output_allocated: bool = false,
    temperature: ?f32 = null,
    is_thinking: ?bool = null,
    skill_save: ?SkillSaveInfo = null,
    agent_save: ?AgentSaveInfo = null,

    pub fn deinit(self: *const ToolExecResult, allocator: std.mem.Allocator) void {
        if (self.output_allocated) {
            allocator.free(self.output);
        }
    }
};
