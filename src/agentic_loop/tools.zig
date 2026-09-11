const std = @import("std");
const nalarcore = @import("nalarcore");

const logger_mod = nalarcore.loggermod;
const sqlite = nalarcore.sqlite;
const config_mod = nalarcore.config;
const ActiveLoops = @import("ActiveLoops.zig").ActiveLoops;

pub const all_agent_tools = @import("tools_equipped.zig").equips;
pub const wrapToolOutput = @import("tools_wrap_output.zig").wrapToolOutput;

// Re-export every migrated exec function. Tool_Registry.zig references
// these via `agentic_loop_mod.tools.execXxx` etc.
pub const execReadFile = @import("tools_exec_read_file.zig").execReadFile;
pub const execTextReplace = @import("tools_exec_text_replace.zig").execTextReplace;
pub const execWriteFile = @import("tools_exec_write_file.zig").execWriteFile;
pub const execListSkills = @import("tools_exec_skills.zig").execListSkills;
pub const execListMemory = @import("tools_exec_list_memory.zig").execListMemory;
pub const execSaveMemory = @import("tools_exec_save_memory.zig").execSaveMemory;
pub const execLoadMemory = @import("tools_exec_load_memory.zig").execLoadMemory;
pub const execDeleteMemory = @import("tools_exec_delete_memory.zig").execDeleteMemory; // 2026-08-24-delete-memory-agent-tool
pub const execSearchHistory = @import("tools_exec_search_history.zig").execSearchHistory;
pub const execUseSkill = @import("tools_exec_skills.zig").execUseSkill;
pub const execRemoveSkill = @import("tools_exec_skills.zig").execRemoveSkill;
pub const execAddSkill = @import("tools_exec_skills.zig").execAddSkill;
pub const execEditSkill = @import("tools_exec_skills.zig").execEditSkill;
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
pub const execMoveElementToPage = @import("tools_exec_move_element_to_page.zig").execMoveElementToPage;
pub const execShowPreview = @import("tools_exec_show_preview.zig").execShowPreview;
pub const execGenerateImage = @import("tools_exec_generate_image.zig").execGenerateImage;
pub const execGetDesignContext = @import("tools_exec_get_design_context.zig").execGetDesignContext;
pub const execPreviewDesignPage = @import("tools_exec_preview_design_page.zig").execPreviewDesignPage;
pub const execWebSearch = @import("tools_exec_web_search.zig").execWebSearch;
pub const execGlob = @import("tools_exec_glob.zig").execGlob;
pub const execSearch = @import("tools_exec_search.zig").execSearch;
pub const execBash = @import("tools_exec_bash.zig").execBash;
pub const execPwsh = @import("tools_exec_pwsh.zig").execPwsh;
pub const execCommand = @import("tools_exec_command.zig").execCommand;
// 2026-08-14 — list_directory agent tool (Task 5 of ban-absolute-paths plan).
pub const execListDirectory = @import("tools_exec_list_directory.zig").execListDirectory;
pub const execUpdateActivity = @import("tools_exec_update_activity.zig").execUpdateActivity;
pub const execSpawnSubAgent = @import("tools_exec_spawn_sub_agent.zig").execSpawnSubAgent;

// 2026-08-19 — session_plan agent tools (Task 4 of 2026-08-19-session-plan-agent-tool.md).
// update_plan (UPSERT) + get_plan (fetch) — the markdown task plan that
// persists across iterations and gets re-injected into the system prompt.
pub const execUpdatePlan = @import("tools_exec_update_plan.zig").execUpdatePlan;
pub const execGetPlan = @import("tools_exec_get_plan.zig").execGetPlan;
pub const execListSubAgent = @import("tools_exec_list_sub_agent.zig").execListSubAgent;
// 2026-08-28 — add_mcp_server agent tool (Step 3 of 2026-08-28-add-mcp-server-agent-tool.md).
// Lets the LLM register a new MCP server (stdio in v1) in the live config +
// persist to disk + hot-reload `di.llm_config` so the new server's tools
// appear on the next iteration's system prompt.
pub const execAddMcpServer = @import("tools_exec_add_mcp_server.zig").execAddMcpServer;

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
    /// The active design page id (when the LLM is in a design-item
    /// session). Empty string means "no active design page" — the
    /// design tools (move_design_element, set_design_page, etc.)
    /// require this. The agentic loop sets it from
    /// `activeDesignPageId` in the session state.
    ///
    /// Added 2026-08-06 for the `move_element_to_page` tool — the
    /// LLM needs to know which page the element is currently on
    /// (the model function takes `source_page_id` as a required
    /// param). Default empty so existing call sites continue to
    /// compile.
    active_page_id: []const u8 = "",
    /// The parent's tool_call id for THIS dispatch. 2026-08-23 spawn-
    /// subagent-live-progress: `execSpawnSubAgent` needs this to key
    /// its per-tool progress events (ChatView.vue's frontend reducer
    /// routes by it). Empty string default so every existing call
    /// site that doesn't care about this field continues to compile.
    tool_call_id: []const u8 = "",
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
