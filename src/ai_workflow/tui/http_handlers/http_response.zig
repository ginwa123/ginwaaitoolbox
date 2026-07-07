const std = @import("std");
const llm_history = @import("../llm_history.zig");

pub const WorkspaceResponse = struct { id: []const u8, name: []const u8, created_at: ?[]const u8 = null, updated_at: ?[]const u8 = null };

pub const WorkspaceItemResponse = struct { id: []const u8, success: bool = true };

pub const WorkspaceItemFullResponse = struct { id: []const u8, workspace_id: []const u8, item_type: []const u8, name: ?[]const u8 = null, path: ?[]const u8 = null, created_at: ?[]const u8 = null, updated_at: ?[]const u8 = null };

// ─── Kanban column types ───────────────────────────────────────────────────
// Wire shape for `GET /api/workspaces/:wsId/items/:itemId/kanban/columns`
// (and the PATCH/POST variants). Mirrors the `KanbanColumn` struct in
// `src/ai_workflow/tui/kanban_model.zig` field-for-field so a future
// contract change is one struct definition to update.
//
// `id` is generated server-side (e.g. `col_<unix_nanoseconds>`).
// `position` is an `i64` because SQLite INTEGER can be 64-bit and the
// kanban model layer stores positions as i64. The frontend reads it as
// a JS number (up to 2^53 is safe; the kanban flow renumbers densely
// so positions never approach that ceiling in practice).
pub const KanbanColumnResponse = struct {
    id: []const u8,
    workspace_item_id: []const u8,
    name: []const u8,
    /// Free-text description of what the column means. Empty
    /// string when the column has no description set. The frontend
    /// renders "" as the "Add a description..." placeholder.
    description: []const u8,
    position: i64,
    created_at: []const u8,
};

/// Map a `kanban_model.KanbanColumn` (or any struct with the same
/// fields) into a `KanbanColumnResponse`. The `anytype` parameter keeps
/// this helper decoupled from the data-layer struct so the two can
/// evolve independently without touching the response shape.
pub fn makeKanbanColumnResponse(col: anytype) KanbanColumnResponse {
    return .{
        .id = col.id,
        .workspace_item_id = col.workspace_item_id,
        .name = col.name,
        .description = col.description,
        .position = col.position,
        .created_at = col.created_at,
    };
}

/// Build the `{"columns":[...], "count": N}` envelope used by
/// `GET /kanban/columns` (and the success-path of PATCH/DELETE that
/// returns the full updated board). The inner slice is allocated from
/// the per-request arena and freed before this function returns; the
/// outer envelope JSON is what the caller receives.
pub fn makeKanbanColumnListResponse(allocator: std.mem.Allocator, cols: anytype) ![]u8 {
    const KanbanColumnListResponse = struct {
        columns: []const KanbanColumnResponse,
        count: u32,
    };

    const mapped = try allocator.alloc(KanbanColumnResponse, cols.len);
    defer allocator.free(mapped);
    for (cols, 0..) |c, i| mapped[i] = makeKanbanColumnResponse(c);

    return std.json.Stringify.valueAlloc(
        allocator,
        KanbanColumnListResponse{
            .columns = mapped,
            .count = @intCast(cols.len),
        },
        .{},
    );
}

pub const LlmRunResponse = struct { status: []const u8, session_id: []const u8 };

pub const WorkspaceItemUpdateResponse = struct { id: []const u8, workspace_id: []const u8, item_type: []const u8, success: bool = true };

pub const WorkspaceItemGetResponse = struct { id: []const u8, workspace_id: []const u8, item_type: []const u8, name: ?[]const u8 = null, path: ?[]const u8 = null, created_at: ?[]const u8 = null, updated_at: ?[]const u8 = null };

pub const SystemFolderErrorResponse = struct { @"error": []const u8, details: ?[]const u8 = null };

pub const SessionCreateResponse = struct { id: []const u8, name: []const u8, status: []const u8 };

pub const SessionUpdateResponse = struct {
    id: []const u8,
    name: []const u8,
    status: []const u8,
    selected_profile_model: []const u8,
};

pub const WorkerResponse = struct { id: []const u8, status: []const u8 };

pub const HealthResponse = struct { status: []const u8, timestamp: i64 };

pub const TaskDeleteResponse = struct { id: []const u8, success: bool = true };

pub const TaskCreateResponse = struct { id: []const u8, name: []const u8, description: ?[]const u8, completed: bool };

// Request types
pub const TaskCreateRequest = struct {
    name: []const u8,
    /// Free-form text the frontend attaches to every task (the
    /// `AddTaskDialog` and `AddRoutineDialog` both emit it).
    /// `workspace_item_tasks` has no `description` column, so the
    /// value is parsed and accepted but not persisted — the
    /// frontend holds the authoritative copy.
    description: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    /// Task type. Defaults to 'standard' (preserves the existing flow).
    ///   - 'standard': interactive chat task (default; creates a session).
    ///   - 'routine':  cron-scheduled task backed by a `routines` row.
    ///   - 'memory':   a local memory file scoped to the parent
    ///                 workspace_item's directory. The .md file is
    ///                 created at <workspace_item.path>/.nalar/memories/
    ///                 so `loadLocalKnowledge` picks it up on the
    ///                 next chat. Requires `memory_name` and
    ///                 `memory_content` in the body.
    task_type: []const u8 = "standard",
    /// 5-field cron expression. Required iff task_type='routine'.
    schedule: ?[]const u8 = null,
    /// What the LLM sees on every fire. Required iff task_type='routine'.
    initial_prompt: ?[]const u8 = null,
    /// Whether the routine is active. Defaults to true.
    enabled: bool = true,
    /// Filename for the memory file. Must end in `.md` and contain
    /// no path separators or `..` (validated by `memories.isValidMemoryName`).
    /// Required iff task_type='memory'.
    memory_name: ?[]const u8 = null,
    /// Initial content of the memory file. Required iff task_type='memory'.
    memory_content: ?[]const u8 = null,
};

pub const TaskUpdateRequest = struct {
    name: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    /// Routine-only. New cron expression. Validated by the handler.
    /// When changed, next_run_at is recomputed.
    schedule: ?[]const u8 = null,
    /// Routine-only. New prompt text.
    initial_prompt: ?[]const u8 = null,
    /// Routine-only. New active flag. When false, the routine stays
    /// in the DB but is skipped by the scheduler.
    enabled: ?bool = null,
};

pub const GitStageResponse = struct {
    success: bool,
    message: []const u8,
    staged_files: []const []const u8,
    failed_files: []const []const u8 = &.{},
};

pub const WorkerInfo = struct { id: []const u8, session_id: []const u8, working_directory: ?[]const u8, last_activity: ?[]const u8, last_activity_description: ?[]const u8, created_at: ?[]const u8, status: []const u8, is_running: bool, queue_count: u32 };

pub const WorkerListResponse = struct { workers: []const WorkerInfo, count: u32 };

pub const SessionMessage = struct {
    id: []const u8,
    session_id: []const u8,
    role: []const u8,
    content: []const u8,
    created_at: []const u8,
    /// Wire-format boolean. Emitted as JSON `true`/`false` by
    /// `std.json.Stringify.valueAlloc` (called from
    /// `makeSessionMessagesResponse`). Matches the SSE
    /// `SseEventLLMHistory.is_input` shape and the TypeScript
    /// `is_input?: boolean` type. The DB column is `INTEGER` (0/1);
    /// the conversion to bool happens in `llm_history.SessionMessage`
    /// via `parseRowBool`. See
    /// docs/plans/2026-07-01-is-input-output-bool-consistency.md.
    is_input: bool,
    is_output: bool,
    tool_name: []const u8,
    finish_reason: []const u8,
    reasoning_content: []const u8,
    diffview_before: []const u8 = "",
    diffview_after: []const u8 = "",
    image_url: []const u8 = "",
    tool_call_id: []const u8 = "",
    tool_calls_json: []const u8 = "",
};

pub const SessionMessagesResponse = struct {
    messages: []const SessionMessage,
    has_more: bool,
    next_cursor: ?[]const u8,
    cwd: ?[]const u8 = null,
    /// Session's bound git worktree path (NULL/empty when no worktree is
    /// bound). Mirrors `sessions.git_worktree_cwd`. Populated by
    /// `sessionMessagesHandler` from `llm_history.SessionMessageResponse`.
    /// See Chunk 1 of the git-worktree-cwd-pr plan.
    git_worktree_cwd: ?[]const u8 = null,
    max_total_tokens: u32 = 0,
    max_capacity_total_tokens: u32 = 0,
    total: ?u32 = null, // Total count of messages for VirtualScroller
    skills: ?[]const llm_history.SkillInfo = null, // Skills loaded for this session
};

pub fn makeSessionMessagesResponse(allocator: std.mem.Allocator, response: SessionMessagesResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{
        .emit_strings_as_arrays = false,
    });
}

pub fn makeSystemFolderErrorResponse(allocator: std.mem.Allocator, message: []const u8, err: anytype) ![]u8 {
    const response = SystemFolderErrorResponse{
        .@"error" = message,
        .details = @errorName(err),
    };
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeSessionCreateResponse(allocator: std.mem.Allocator, response: SessionCreateResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeSessionUpdateResponse(allocator: std.mem.Allocator, response: SessionUpdateResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeWorkerResponse(allocator: std.mem.Allocator, response: WorkerResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeHealthResponse(allocator: std.mem.Allocator, response: HealthResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeTaskDeleteResponse(allocator: std.mem.Allocator, response: TaskDeleteResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeTaskCreateResponse(allocator: std.mem.Allocator, response: TaskCreateResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeWorkerListResponse(allocator: std.mem.Allocator, workers: []const WorkerInfo, count: u32) ![]u8 {
    const response = WorkerListResponse{
        .workers = workers,
        .count = count,
    };
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub const ErrorResponse = struct { @"error": []const u8 };

pub fn makeErrorResponse(allocator: std.mem.Allocator, response: ErrorResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub const NalarConfigResponse = struct {
    api_endpoint: []const u8,
    api_key: []const u8,
    model: []const u8,
    url_style: []const u8,
    temperature: f64,
    max_tokens: ?usize,
    system_prompt: []const u8,
    profiles: ?std.json.Value = null,
    active_profile: ?[]const u8 = null,
    /// Map of MCP server name to its raw JSON config (`{"url": "...", "headers": {...}}`).
    /// Sent as-is so the frontend gets full fidelity (header values, etc.).
    mcp_servers: ?std.json.Value = null,
    /// Top-level sub-agents. Each entry carries the full LLM
    /// configuration (model, base_url, thinking, temperature, url_style,
    /// api_key) plus a `system_prompt`. Borrowed slices — the caller
    /// must keep the source alive until the response is serialized.
    sub_agents: ?[]const SubAgentResponse = null,
    /// Opt-in OS notification flag. When true, the backend fires
    /// `notify-send` / osascript / PowerShell when an LLM response
    /// completes with `finish_reason == "stop"`. Consumed by
    /// `workflow.zig:483`.
    notify_on_complete: bool = false,
    /// Compaction threshold in KB. Sessions whose DB-stored token
    /// estimate exceeds this value trigger context compaction.
    /// Consumed by `session_compact.zig:57`.
    model_compaction_size_kb: usize = 100,
};

/// Wire format for a single sub-agent entry. Mirrors
/// `LlmConfig.SubAgentJson` field-for-field; lives here as a separate
/// type so the response boundary doesn't need to import the internal
/// `LlmConfig` module just to serialize a list of sub-agents.
pub const SubAgentResponse = struct {
    name: []const u8,
    model: []const u8,
    base_url: []const u8,
    thinking: []const u8,
    temperature: []const u8,
    url_style: []const u8,
    api_key: []const u8,
    system_prompt: []const u8,
};

pub fn makeNalarConfigResponse(allocator: std.mem.Allocator, response: NalarConfigResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeWorkspaceResponse(allocator: std.mem.Allocator, response: WorkspaceResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeWorkspaceItemResponse(allocator: std.mem.Allocator, response: WorkspaceItemResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeLlmRunResponse(allocator: std.mem.Allocator, response: LlmRunResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeWorkspaceItemUpdateResponse(allocator: std.mem.Allocator, response: WorkspaceItemUpdateResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeWorkspaceItemGetResponse(allocator: std.mem.Allocator, response: WorkspaceItemGetResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeWorkspaceItemFullResponse(allocator: std.mem.Allocator, response: WorkspaceItemFullResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeWorkspaceItemListResponse(allocator: std.mem.Allocator, items: anytype) ![]u8 {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    try list.appendSlice(allocator, "[");
    for (items, 0..) |item, i| {
        if (i > 0) try list.appendSlice(allocator, ",");
        const json_str = try std.json.Stringify.valueAlloc(allocator, WorkspaceItemFullResponse{
            .id = item.id,
            .workspace_id = item.workspace_id,
            .item_type = item.item_type,
            .name = item.name,
            .path = item.path,
            .created_at = item.created_at,
            .updated_at = item.updated_at,
        }, .{});
        defer allocator.free(json_str);
        try list.appendSlice(allocator, json_str);
    }
    try list.appendSlice(allocator, "]");
    return try list.toOwnedSlice(allocator);
}

/// Object-wrapped variant of `makeWorkspaceItemListResponse`.
/// Returns `{"items":[...],"count":N}` to match the shape the desktop store's
/// `getWorkspacesItems` frontend wrapper expects. Delegates the inner array
/// build to the bare-array helper to avoid duplicating the item-shape logic.
pub fn makeWorkspaceItemListObjectResponse(allocator: std.mem.Allocator, items: anytype) ![]u8 {
    const array_json = try makeWorkspaceItemListResponse(allocator, items);
    defer allocator.free(array_json);

    return std.fmt.allocPrint(allocator, "{{\"items\":{s},\"count\":{d}}}", .{ array_json, items.len });
}

// Workspace Item Task types
/// Wire shape for the inline `routine` field on `WorkspaceItemTaskResponse`.
/// Mirrors the API response in the design doc.
pub const RoutineMetaResponse = struct {
    schedule: []const u8,
    initial_prompt: []const u8,
    enabled: bool,
    last_run_at: ?[]const u8 = null,
    next_run_at: []const u8,
    last_status: ?[]const u8 = null, // "success" | "failed" | "running" | null
    last_error: ?[]const u8 = null,
};

pub const WorkspaceItemTaskResponse = struct {
    id: []const u8,
    name: []const u8,
    workspace_item_id: []const u8,
    /// Task type. Always present; 'standard' for legacy rows.
    task_type: []const u8 = "standard",
    /// Inline routine metadata. Present iff task_type === 'routine'.
    routine: ?RoutineMetaResponse = null,
    created_at: ?[]const u8 = null,
    updated_at: ?[]const u8 = null,
    /// Pin flag. `true` when the user has pinned this task. Default
    /// `false` so older call sites that don't supply it still compile.
    /// Mirrors `WorkspaceItemTaskInfo.is_pinned` in `llm_history.zig`.
    is_pinned: bool = false,
    /// Position within the pinned subset of a single workspace item.
    /// Only meaningful when `is_pinned == true`. Mirrors
    /// `WorkspaceItemTaskInfo.pinned_position`.
    pinned_position: i64 = 0,
    /// Kanban column this task belongs to (when the parent workspace
    /// item is a kanban). `null` for tasks under non-kanban parents.
    /// Mirrors `WorkspaceItemTaskInfo.kanban_column_id` (Migration 048).
    kanban_column_id: ?[]const u8 = null,
    /// Position within the kanban column. `0` for non-kanban tasks.
    /// Mirrors `WorkspaceItemTaskInfo.kanban_position` (Migration 048).
    kanban_position: i64 = 0,
};

pub const WorkspaceItemTaskListResponse = struct {
    tasks: []const WorkspaceItemTaskResponse,
    count: u32,
    // Pagination fields. `has_more` is true when at least one more page
    // exists after this one; `next_cursor` is the `created_at` of the
    // last task in this page, to be passed back as `?cursor=` for the
    // next page. `next_cursor` is null when there are no more pages.
    // Both default to "end of list" so older call sites that don't
    // supply them still compile.
    has_more: bool = false,
    next_cursor: ?[]const u8 = null,
};

/// One entry in the `GET /api/routines` list response. Includes
/// `workspace_id` + `workspace_item_id` + `task_name` so the caller
/// can navigate from the listing to the routine's source without a
/// second round-trip to `GET /api/workspaces` + grep.
///
/// `last_run_at` / `last_status` / `last_error` are nullable for
/// routines that have never fired (the corresponding DB columns are
/// NULL). `next_run_at` is `NOT NULL` per Migration 044.
pub const RoutinesListEntry = struct {
    id: []const u8,
    task_id: []const u8,
    workspace_id: []const u8,
    workspace_item_id: []const u8,
    task_name: []const u8,
    schedule: []const u8,
    initial_prompt: []const u8,
    enabled: bool,
    last_run_at: ?[]const u8 = null,
    next_run_at: []const u8,
    /// "success" | "failed" | "running" | null (null = never fired or
    /// unknown string → matches `RoutineRunStatus.idle`).
    last_status: ?[]const u8 = null,
    last_error: ?[]const u8 = null,
};

pub const RoutinesListResponse = struct {
    routines: []const RoutinesListEntry,
    count: u32,
};

pub fn makeWorkspaceItemTaskResponse(allocator: std.mem.Allocator, response: WorkspaceItemTaskResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeWorkspaceItemTaskListResponse(
    allocator: std.mem.Allocator,
    tasks: []const WorkspaceItemTaskResponse,
    has_more: bool,
    next_cursor: ?[]const u8,
) ![]u8 {
    const response = WorkspaceItemTaskListResponse{
        .tasks = tasks,
        .count = @intCast(tasks.len),
        .has_more = has_more,
        .next_cursor = next_cursor,
    };
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeRoutinesListResponse(
    allocator: std.mem.Allocator,
    routines: []const RoutinesListEntry,
) ![]u8 {
    const response = RoutinesListResponse{
        .routines = routines,
        .count = @intCast(routines.len),
    };
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

// Git status types
pub const GitStatusResponse = struct { is_git_repo: bool, branch: ?[]const u8 = null, has_changes: bool = false, is_clean: bool = true, status: ?[]const u8 = null };

pub const GitStatusErrorResponse = struct { @"error": []const u8 };

pub fn makeGitStatusResponse(allocator: std.mem.Allocator, response: GitStatusResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeGitStatusErrorResponse(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    const response = GitStatusErrorResponse{
        .@"error" = message,
    };
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeGitStageResponse(allocator: std.mem.Allocator, response: GitStageResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

// ─── Git worktree info types ───────────────────────────────────────────────
// Wire shape for `GET /api/git/worktree/info?path=<worktree>[&base=<branch>]`
// consumed by the desktop app's CreatePrDialog. Mirrors the response
// struct in `git_worktree_info.zig` so a future contract change is one
// struct definition to update. See Chunk 2 of the
// git-worktree-cwd-pr plan.
pub const GitWorktreeInfoResponse = struct {
    is_git_repo: bool = false,
    branch: []const u8 = "",
    last_commit_sha: []const u8 = "",
    last_commit_msg: []const u8 = "",
    default_base: []const u8 = "",
    commits_ahead: i64 = 0,
    diff_summary: []const u8 = "",
    draft_title: []const u8 = "",
    draft_body: []const u8 = "",
};

pub fn makeGitWorktreeInfoResponse(allocator: std.mem.Allocator, response: GitWorktreeInfoResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

// ─── Git PR create types ──────────────────────────────────────────────────
// Wire shape for `POST /api/git/pr`. See Chunk 3 of the
// git-worktree-cwd-pr plan.
pub const GitPrCreateResponse = struct {
    success: bool = false,
    pr_url: []const u8 = "",
    // Renamed from `error_message` per PR review (line 60 of git_pr_create.zig).
    // `error` is a Zig keyword, so the field is `@"error"` here; it serializes
    // to JSON `"error"` via std.json.Stringify.
    @"error": []const u8 = "",
};

pub fn makeGitPrCreateResponse(allocator: std.mem.Allocator, response: GitPrCreateResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

// Profile types
pub const LlmProfileResponse = struct {
    name: []const u8,
    model: []const u8,
    base_url: []const u8,
    thinking: []const u8,
    temperature: []const u8,
    api_key: []const u8,
    /// Per-profile sub-agents. Borrowed slices from the source profile;
    /// the caller must keep the source alive until the response is
    /// serialized.
    sub_agents: ?[]const SubAgentResponse = null,
};

pub const ProfilesListResponse = struct {
    profiles: []const LlmProfileResponse,
    count: u32,
    active_profile: ?[]const u8 = null,
};

pub fn makeProfilesListResponse(allocator: std.mem.Allocator, profiles: []const LlmProfileResponse, active_profile: ?[]const u8) ![]u8 {
    const response = ProfilesListResponse{
        .profiles = profiles,
        .count = @intCast(profiles.len),
        .active_profile = active_profile,
    };
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

// ─── Workspaces reorder ────────────────────────────────────────────────────
// Typed response for `POST /api/workspaces/reorder`. Uses the same
// `std.json.Stringify.valueAlloc` pattern as every other response
// in this file — never manual `std.fmt.allocPrint` of JSON strings
// (those break on field names with special characters and drift
// away from the struct definition on every refactor).
pub const WorkspacesReorderResponse = struct {
    success: bool = true,
    count: usize,
};

pub fn makeWorkspacesReorderResponse(allocator: std.mem.Allocator, count: usize) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, WorkspacesReorderResponse{ .count = count }, .{});
}

// Typed response for `POST /api/workspaces/:workspace_id/items/reorder`.
// Mirrors WorkspacesReorderResponse — same shape, same std.json.Stringify
// pattern. The frontend reads `{success, count}` to confirm the reorder
// took effect.
pub const WorkspaceItemReorderResponse = struct {
    success: bool = true,
    count: usize,
};

pub fn makeWorkspaceItemReorderResponse(allocator: std.mem.Allocator, count: usize) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, WorkspaceItemReorderResponse{ .count = count }, .{});
}

/// Typed response for `POST /api/.../tasks/:task_id/pin`. Returns the
/// new `pinned_position` so the client can confirm the row landed at
/// the bottom of the pinned region. `is_pinned` echoes the requested
/// state.
pub const TaskPinResponse = struct {
    success: bool = true,
    id: []const u8,
    is_pinned: bool,
    pinned_position: i64,
};

pub fn makeTaskPinResponse(
    allocator: std.mem.Allocator,
    id: []const u8,
    is_pinned: bool,
    pinned_position: i64,
) ![]u8 {
    return std.json.Stringify.valueAlloc(
        allocator,
        TaskPinResponse{
            .id = id,
            .is_pinned = is_pinned,
            .pinned_position = pinned_position,
        },
        .{},
    );
}

/// Typed response for `POST /api/.../tasks/reorder_pinned`. Returns
/// the number of rows in the payload (a row that isn't currently
/// pinned is silently skipped by the WHERE clause, but the count
/// still reflects the input list size so the client can verify the
/// request reached the server).
pub const TasksReorderPinnedResponse = struct {
    success: bool = true,
    count: usize,
};

pub fn makeTasksReorderPinnedResponse(allocator: std.mem.Allocator, count: usize) ![]u8 {
    return std.json.Stringify.valueAlloc(
        allocator,
        TasksReorderPinnedResponse{ .count = count },
        .{},
    );
}
