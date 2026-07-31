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
    /// Migration 063 — echo the unattended-mode flag back so the
    /// frontend's reactive Pinia store refreshes from the response.
    is_auto_retry_until_stop: []const u8 = "",
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
    /// Persisted on the `workspace_item_tasks.description` column
    /// (Migration 062). Optional; the DB default '' is the
    /// "no description" sentinel.
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
    /// Auto-retry-until-stop flag (Migration 063). Mirrors the
    /// `sessions.is_auto_retry_until_stop` column for routine tasks
    /// where task.id == session.id (project convention). When set
    /// during standard-task creation, the handler ALSO inserts a
    /// `sessions` row (task.id becomes session.id) so the flag has
    /// somewhere to land. Accepts `"1"`, `"0"`, or null/absent.
    /// Frontend's KanbanTaskDetailDialog toggle sends this on
    /// create when the user flipped unattended-mode ON.
    is_auto_retry_until_stop: ?[]const u8 = null,
    /// JSON-encoded array of tag strings (Migration 067 — kanban
    /// task tags feature). Null/undefined means "no tags supplied",
    /// which is the same as an empty array. The handler validates
    /// the JSON shape, char whitelist, dedupe, and length caps
    /// (see http_handlers/tags_validation.zig). Stored verbatim on
    /// the row's `tags` column. Plan:
    /// docs/superpowers/plans/2026-07-28-kanban-task-tags.md
    tags: ?[]const u8 = null,
};

pub const TaskUpdateRequest = struct {
    name: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    /// Free-form description. Mirrors `TaskCreateRequest.description`.
    /// When present (non-null), overwrites the existing value; the
    /// empty string is the canonical "no description" sentinel and is
    /// stored verbatim. UI uses an "Add a description…" placeholder for
    /// empty values; the DB column has DEFAULT '' so legacy rows
    /// without a description look identical.
    description: ?[]const u8 = null,
    /// Routine-only. New cron expression. Validated by the handler.
    /// When changed, next_run_at is recomputed.
    schedule: ?[]const u8 = null,
    /// Routine-only. New prompt text.
    initial_prompt: ?[]const u8 = null,
    /// Routine-only. New active flag. When false, the routine stays
    /// in the DB but is skipped by the scheduler.
    enabled: ?bool = null,
    /// JSON-encoded array of tag strings (Migration 067).
    /// Semantics:
    ///   - null/undefined  → don't change existing tags (no-op).
    ///   - `""` (empty string) → clear all tags (sets `tags = ''`).
    ///   - `'["a","b"]'` → replace existing tags with this array
    ///     (after validation + dedupe via tags_validation.zig).
    /// The handler validates the shape, char whitelist, length cap,
    /// and dedupes case-insensitively. Plan:
    /// docs/superpowers/plans/2026-07-28-kanban-task-tags.md.
    tags: ?[]const u8 = null,
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
    /// Session's selected profile name (NULL/empty when no profile is
    /// selected). Mirrors `sessions.selected_profile_model`. Populated by
    /// `sessionMessagesHandler` from `llm_history.SessionMessageResponse`.
    /// Without this field the frontend's profile chip resets to "Default"
    /// on every page refresh because the read endpoint never returned
    /// the value that PUT `/api/llm/session/:id` writes. Bug fix:
    /// 2026-08-07-profile-persist-read.
    selected_profile_model: ?[]const u8 = null,
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
    /// Optional top-level override for the model's context window (in tokens).
    /// `null` = fall through to per-profile override, then built-in default.
    /// Restored in plan 2026-07-07-compaction-inline so the Defaults tab
    /// can show + edit the top-level compaction defaults.
    max_capacity_token_model: ?u32 = null,
    /// Optional top-level compaction threshold as a percentage (0-100).
    /// `null` = fall through to per-profile override, then built-in 80.
    compaction_threshold_percent: ?u8 = null,
    /// Delay in milliseconds before the workflow retries a failed
    /// `callDynamicAgentNew` call. 0 = no delay. Consumed by
    /// `workflow.zig:513` (the `callDynamicAgentNew` retry catch) and
    /// `workflow.zig:595` (the `else` finish_reason branch).
    retry_delay_ms: u32 = 0,
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
    /// Free-form description (Migration 062). Empty string is the
    /// canonical "no description" sentinel; the column is NOT NULL
    /// DEFAULT '' so this is never null.
    description: []const u8 = "",
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
    /// Unattended-mode flag, joined from `sessions` for routine
    /// tasks (where `task.id == session.id` per the project
    /// convention). `'0'` for standard tasks that have no
    /// session row, and the literal session value otherwise.
    /// Empty string when the join didn't find a row — the
    /// frontend's KanbanTaskDetailDialog defaults to off in that
    /// case.
    is_auto_retry_until_stop: []const u8 = "",

    /// Last `finish_reason` from the joined `sessions` row (Migration
    /// 065 / kanban notification icon feature). Empty string when
    /// the LEFT JOIN found no session row — the frontend treats this
    /// as "AI never ran on this task". Drives the green checkmark
    /// vs no-icon decision in the kanban card.
    last_finish_reason: []const u8 = "",

    /// Computed boolean for the kanban card "AI finished — awaiting
    /// review" orange dot. SQL CASE produces 1 when the AI has
    /// finished (last_finish_reason='stop') and no human has touched
    /// the task since. The kanban card UI uses this directly:
    ///   - true  → orange pulsing dot
    ///   - false AND last_finish_reason==='stop' → green checkmark
    ///   - false AND last_finish_reason==='' → no icon (never ran)
    needs_human_review: bool = false,

    /// JSON-encoded array of tag strings (Migration 067 — kanban
    /// task tags feature). Empty string is the canonical "no tags"
    /// sentinel (NOT NULL DEFAULT ''). Frontend decodes via
    /// JSON.parse. Plan:
    /// docs/superpowers/plans/2026-07-28-kanban-task-tags.md.
    tags: []const u8 = "",
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

/// One entry in the kanban tag suggestions dropdown. Returned by
/// `GET /api/workspaces/:ws/items/:item/kanban/tags` ordered by
/// frequency DESC, last_used_at DESC.
/// Plan: docs/superpowers/plans/2026-07-30-kanban-task-tags-autocomplete.md
pub const KanbanTagSuggestionResponse = struct {
    name: []const u8,
    count: u32,
    last_used_at: ?[]const u8 = null,
};

pub const KanbanTagsListResponse = struct {
    tags: []const KanbanTagSuggestionResponse,
    /// True when more tags exist past this page. The frontend uses
    /// this to decide whether to render the scroll sentinel + load
    /// another page (or stop paginating).
    has_more: bool,
};

pub fn makeKanbanTagsListResponse(
    allocator: std.mem.Allocator,
    suggestions: []const KanbanTagSuggestionResponse,
    has_more: bool,
) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, KanbanTagsListResponse{
        .tags = suggestions,
        .has_more = has_more,
    }, .{});
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

// ─── Design-mode response types ────────────────────────────────────────────
// Wire shapes for `GET/POST/PUT/PATCH/DELETE /api/.../design/...`.
// Mirrors the `DesignPage` and `DesignElement` structs in
// `src/ai_workflow/tui/design_model.zig` field-for-field so a future
// contract change is one struct definition to update.
//
// `DesignElementResponse` deliberately omits the `html` body — the
// full HTML is fetched lazily via a separate `GET .../elements/:eid/html`
// endpoint (`DesignElement.loadElementHtml`). This keeps the page+elements
// JSON payload small even for designs with 50+ elements, and lets the
// iframe preview opt in to fetching bodies only when the element is
// selected.
//
// The model's `elem_type` field is renamed to `type` on the wire (the
// SQL column is `type` too — `elem_type` is a Zig-only name because
// `type` is a Zig keyword).
//
// Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
//   (Chunk 3, Task 3.1).
pub const DesignPageResponse = struct {
    id: []const u8,
    workspace_item_id: []const u8,
    name: []const u8,
    /// 1:1 FK to `workspace_item_tasks.id`. Set atomically by
    /// `design_model.setDesignPage` at create time. The frontend
    /// uses this directly to resolve the page's chat task via
    /// `workspacesStore.setActiveTask(page.workspace_item_task_id)`
    /// — no name matching, no legacy migration.
    workspace_item_task_id: []const u8,
    width: i64,
    height: i64,
    position: i64,
    created_at: []const u8,
    updated_at: []const u8,
};

/// Map a `design_model.DesignPage` (or any struct with the same
/// fields) into a `DesignPageResponse`. The `anytype` parameter keeps
/// this helper decoupled from the data-layer struct so the two can
/// evolve independently without touching the response shape.
pub fn makeDesignPageResponse(page: anytype) DesignPageResponse {
    return .{
        .id = page.id,
        .workspace_item_id = page.workspace_item_id,
        .name = page.name,
        .workspace_item_task_id = page.workspace_item_task_id,
        .width = page.width,
        .height = page.height,
        .position = page.position,
        .created_at = page.created_at,
        .updated_at = page.updated_at,
    };
}

/// Build the `{"pages":[...], "count": N}` envelope used by
/// `GET /design/pages`. The inner slice is allocated from the
/// per-request arena and freed before this function returns; the
/// outer envelope JSON is what the caller receives.
pub fn makeDesignPageListResponse(allocator: std.mem.Allocator, pages: anytype) ![]u8 {
    const DesignPageListResponse = struct {
        pages: []const DesignPageResponse,
        count: u32,
    };

    const mapped = try allocator.alloc(DesignPageResponse, pages.len);
    defer allocator.free(mapped);
    for (pages, 0..) |p, i| mapped[i] = makeDesignPageResponse(p);

    return std.json.Stringify.valueAlloc(
        allocator,
        DesignPageListResponse{
            .pages = mapped,
            .count = @intCast(pages.len),
        },
        .{},
    );
}

pub const DesignElementResponse = struct {
    id: []const u8,
    page_id: []const u8,
    name: []const u8,
    /// Element type — wire string from `ElementType` enum tagName.
    /// One of: "rectangle" | "ellipse" | "text" | "image" | "frame" | "group".
    type: []const u8,
    file_path: []const u8,
    x: i64,
    y: i64,
    width: i64,
    height: i64,
    rotation: f64,
    fill: []const u8,
    stroke: []const u8,
    stroke_width: i64,
    corner_radius: i64,
    opacity: f64,
    text_content: []const u8,
    text_style: []const u8,
    image_url: []const u8,
    /// FK to a `group`/`frame` element on the same page (empty string
    /// for top-level elements). Empty-slice convention matches the
    /// data-layer (NULL parent_id round-trips to `""`). See the
    /// 2026-07-28-grouped-layers plan (Chunk 1).
    parent_id: []const u8,
    z_index: i64,
    position: i64,
    created_at: []const u8,
    updated_at: []const u8,
};

/// Map a `design_model.DesignElement` (or any struct with the same
/// fields) into a `DesignElementResponse`. The model's `elem_type`
/// field (renamed from SQL `type` because `type` is a Zig keyword)
/// is exposed on the wire as `type`.
pub fn makeDesignElementResponse(elem: anytype) DesignElementResponse {
    return .{
        .id = elem.id,
        .page_id = elem.page_id,
        .name = elem.name,
        .type = elem.elem_type,
        .file_path = elem.file_path,
        .x = elem.x,
        .y = elem.y,
        .width = elem.width,
        .height = elem.height,
        .rotation = elem.rotation,
        .fill = elem.fill,
        .stroke = elem.stroke,
        .stroke_width = elem.stroke_width,
        .corner_radius = elem.corner_radius,
        .opacity = elem.opacity,
        .text_content = elem.text_content,
        .text_style = elem.text_style,
        .image_url = elem.image_url,
        .parent_id = elem.parent_id,
        .z_index = elem.z_index,
        .position = elem.position,
        .created_at = elem.created_at,
        .updated_at = elem.updated_at,
    };
}

/// Build the `{"elements":[...], "count": N}` envelope used by
/// callers that want to return a flat element list (currently
/// unused by the 9 HTTP handlers — all of them wrap the elements
/// inside a `DesignPageWithElements` payload — but exported for
/// future endpoints, e.g. a search-by-name route).
pub fn makeDesignElementListResponse(allocator: std.mem.Allocator, elements: anytype) ![]u8 {
    const DesignElementListResponse = struct {
        elements: []const DesignElementResponse,
        count: u32,
    };

    const mapped = try allocator.alloc(DesignElementResponse, elements.len);
    defer allocator.free(mapped);
    for (elements, 0..) |e, i| mapped[i] = makeDesignElementResponse(e);

    return std.json.Stringify.valueAlloc(
        allocator,
        DesignElementListResponse{
            .elements = mapped,
            .count = @intCast(elements.len),
        },
        .{},
    );
}

/// Bundle used by `GET /design/pages/:page_id` — returns the page
/// metadata + all elements in one payload (HTML bodies excluded —
/// fetch lazily via `GET .../elements/:eid/html`).
pub const DesignPageWithElementsResponse = struct {
    page: DesignPageResponse,
    elements: []const DesignElementResponse,
};

/// Build the `{"page":..., "elements":[...]}` envelope for
/// `getPageWithElements`. Mirrors the `kanban_model.PageWithElements`
/// pattern: the page is the parent, elements are the children, both
/// in the same JSON object. The inner slices are allocated from the
/// per-request arena and freed before this function returns; the
/// outer envelope JSON is what the caller receives.
pub fn makeDesignPageWithElementsResponse(
    allocator: std.mem.Allocator,
    page: anytype,
    elements: anytype,
) ![]u8 {
    const mapped_elements = try allocator.alloc(DesignElementResponse, elements.len);
    defer allocator.free(mapped_elements);
    for (elements, 0..) |e, i| mapped_elements[i] = makeDesignElementResponse(e);

    return std.json.Stringify.valueAlloc(
        allocator,
        DesignPageWithElementsResponse{
            .page = makeDesignPageResponse(page),
            .elements = mapped_elements,
        },
        .{},
    );
}

// ─── Frontend error log response types ────────────────────────────────────
// Wire shapes for `POST /api/logs` (no response body, 204 No Content)
// and `GET /api/logs` (returns `{ logs: [...], count: N }`). Mirrors
// the `logs` table column-for-column. `stack`/`source`/`line`/
// `route_path`/`session_id` are nullable per the table schema.
// Plan: docs/plans/2026-07-17-frontend-error-logs-design.md.
pub const FrontendLogRow = struct {
    id: []const u8,
    created_at: i64,
    level: []const u8,
    kind: []const u8,
    message: []const u8,
    stack: ?[]const u8 = null,
    source: ?[]const u8 = null,
    line: ?i64 = null,
    route_path: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    count: i64,
};

pub const FrontendLogListResponse = struct {
    logs: []const FrontendLogRow,
    count: u32,
};

pub fn makeFrontendLogListResponse(allocator: std.mem.Allocator, logs: []const FrontendLogRow) ![]u8 {
    return std.json.Stringify.valueAlloc(
        allocator,
        FrontendLogListResponse{ .logs = logs, .count = @intCast(logs.len) },
        .{},
    );
}
