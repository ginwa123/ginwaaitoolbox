//! HTTP Handlers module - one file per endpoint for better organization
//!
//! This module exports all HTTP handlers used by the TUI HTTP server.
//! Each handler is in its own file for maintainability.

const std = @import("std");
pub const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const sqlite = nalarcore.sqlite;
const ai_workflow = nalarcore.ai_workflow;
const loggermod = nalarcore.loggermod;

const config = nalarcore.config;
pub const http_response = nalarcore.http_response;

// =============================================================================
// Re-exports
// =============================================================================

// Re-export all handlers
pub const corsPreflightHandler = @import("cors.zig").corsPreflightHandler;
pub const sessionCreateHandler = @import("session_create.zig").sessionCreateHandler;
pub const sessionUpdateHandler = @import("session_update.zig").sessionUpdateHandler;
pub const sessionListHandler = @import("session_list.zig").sessionListHandler;
pub const sessionStopHandler = @import("session_stop.zig").sessionStopHandler;
pub const sessionExistHandler = @import("session_exist.zig").sessionExistHandler;
pub const sessionMessagesHandler = @import("session_messages_get.zig").sessionMessagesHandler;
pub const sessionLatestHandler = @import("session_latest.zig").sessionLatestHandler;
pub const sseDisconnectHandler = @import("sse_disconnect.zig").sseDisconnectHandler;
pub const pingHandler = @import("ping.zig").pingHandler;
pub const sessionCompactHandler = @import("session_compact.zig").sessionCompactHandler;
pub const systemFolderHandler = @import("system_folder.zig").systemFolderHandler;
pub const healthHandler = @import("health.zig").healthHandler;
pub const shutdownHandler = @import("shutdown.zig").shutdownHandler;

// Workspace handlers (stub implementations for desktop app compatibility)
pub const workspacesListHandler = @import("workspaces_list.zig").workspacesListHandler;
pub const workspacesCreateHandler = @import("workspaces_create.zig").workspacesCreateHandler;
pub const workspacesReorderHandler = @import("workspaces_reorder.zig").workspacesReorderHandler;
pub const workspaceGetHandler = @import("workspace_get.zig").workspaceGetHandler;
pub const workspaceUpdateHandler = @import("workspace_update.zig").workspaceUpdateHandler;
pub const workspaceDeleteHandler = @import("workspace_delete.zig").workspaceDeleteHandler;
pub const workspaceItemsCreateHandler = @import("workspace_items_create.zig").workspaceItemsCreateHandler;
pub const workspaceItemsListHandler = @import("workspace_items_get.zig").workspaceItemsListHandler;
pub const workspaceItemsGetHandler = @import("workspace_items_get.zig").workspaceItemsGetHandler;
pub const workspaceItemsUpdateHandler = @import("workspace_items_update.zig").workspaceItemsUpdateHandler;
pub const workspaceItemsReorderHandler = @import("workspace_items_reorder.zig").workspaceItemsReorderHandler;
pub const workspaceItemsDeleteHandler = @import("workspace_items_delete.zig").workspaceItemsDeleteHandler;
pub const workspaceItemsCreateKanbanHandler = @import("workspace_items_create_kanban.zig").workspaceItemsCreateKanbanHandler;
pub const workspaceItemsCreateDesignHandler = @import("design_items_create.zig").workspaceItemsCreateDesignHandler;

// Kanban column CRUD handlers (item_type='kanban' sub-resources).
// See docs/superpowers/plans/2026-06-21-workspace-item-kanban.md (Chunk 3).
pub const kanbanColumnsListHandler = @import("kanban_columns_list.zig").kanbanColumnsListHandler;
pub const kanbanColumnsCreateHandler = @import("kanban_columns_create.zig").kanbanColumnsCreateHandler;
pub const kanbanColumnsUpdateHandler = @import("kanban_columns_update.zig").kanbanColumnsUpdateHandler;
pub const kanbanColumnsDeleteHandler = @import("kanban_columns_delete.zig").kanbanColumnsDeleteHandler;
// Copy a kanban's column spec (names + descriptions, preserving order)
// from a source kanban to a target kanban. Tasks are NOT copied.
// Body: `{mode: "replace" | "append"}`. See plan
// docs/superpowers/plans/2026-07-04-copy-kanban-spec.md (Chunk 2).
pub const kanbanCopySpecHandler = @import("kanban_copy_spec.zig").kanbanCopySpecHandler;
pub const tasksMoveHandler = @import("tasks_move.zig").tasksMoveHandler;
pub const tasksListHandler = @import("tasks_list.zig").tasksListHandler;
pub const tasksCreateHandler = @import("task_create.zig").tasksCreateHandler;
pub const tasksUpdateHandler = @import("task_update.zig").tasksUpdateHandler;
pub const tasksUpdateByIdHandler = @import("task_update.zig").tasksUpdateByIdHandler;
pub const tasksDeleteHandler = @import("task_delete.zig").tasksDeleteHandler;
// Use-case + outcome type live in the same file as the handler
// (DELETE /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id).
// The handler is a thin orchestrator over `deleteTaskUseCase`; both
// are scoped under `nalarcore.http_handlers.*` per the project
// convention (see `nalar_config_profile_delete.zig`'s re-exports).
pub const deleteTaskUseCase = @import("task_delete.zig").deleteTaskUseCase;
pub const TaskDeleteOutcome = @import("task_delete.zig").TaskDeleteOutcome;
pub const taskPinHandler = @import("task_pin.zig").taskPinHandler;
pub const tasksReorderPinnedHandler = @import("tasks_reorder_pinned.zig").tasksReorderPinnedHandler;
pub const routinesRunHandler = @import("routines_run.zig").routinesRunHandler;
pub const routinesListHandler = @import("routines_list.zig").routinesListHandler;

// Worker API handlers
pub const workerGetHandler = @import("worker_get.zig").workerGetHandler;
pub const workerListHandler = @import("worker_list.zig").workerListHandler;

// Unified SSE handler — single endpoint that fans out all event families.
// Replaces the 5 dedicated routes registered in main.zig. See
// unified_events_sse.zig for the channel grammar (?channels=).
pub const unifiedEventsStreamHandler = @import("unified_events_sse.zig").unifiedEventsStreamHandler;

// Skills API handlers
pub const skillsListHandler = @import("skills_list.zig").skillsListHandler;
pub const skillDetailHandler = @import("skill_detail.zig").skillDetailHandler;
pub const skillDeleteHandler = @import("skill_delete.zig").skillDeleteHandler;

// Memories API handlers
pub const memoriesListHandler = @import("memories_list.zig").memoriesListHandler;
pub const memoryDetailHandler = @import("memories_detail.zig").memoryDetailHandler;
pub const memoryCreateHandler = @import("memories_create.zig").memoryCreateHandler;
pub const memoryUpdateHandler = @import("memories_update.zig").memoryUpdateHandler;
pub const memoryDeleteHandler = @import("memories_delete.zig").memoryDeleteHandler;

// Local Memories API handlers — same CRUD shape as the global memories
// handlers above but operating on `<cwd>/.nalar/memories/` instead of
// `~/.config/nalar/memories/`. The `cwd` resolution prefers the body
// (for POST/PUT) or the query string (for GET/DELETE), falling back
// to the nalar server's CWD via `io.realPath` when no explicit cwd
// is provided. See `docs/plans/2026-06-20-add-markdown-memory.md`.
pub const localMemoriesListHandler = @import("local_memories_list.zig").localMemoriesListHandler;
pub const localMemoryDetailHandler = @import("local_memories_detail.zig").localMemoryDetailHandler;
pub const localMemoryCreateHandler = @import("local_memories_create.zig").localMemoryCreateHandler;
pub const localMemoryUpdateHandler = @import("local_memories_update.zig").localMemoryUpdateHandler;
pub const localMemoryDeleteHandler = @import("local_memories_delete.zig").localMemoryDeleteHandler;

// Git API handlers
pub const gitStatusHandler = @import("git_status.zig").gitStatusHandler;
pub const gitChangesHandler = @import("git_changes.zig").gitChangesHandler;
pub const gitFileDiffHandler = @import("git_file_diff.zig").gitFileDiffHandler;
pub const gitFileReadHandler = @import("git_file_diff.zig").gitFileReadHandler;
pub const gitStageHandler = @import("git_file_stage.zig").gitStageHandler;
pub const gitUnstageHandler = @import("git_file_stage.zig").gitUnstageHandler;
pub const gitWorktreeInfoHandler = @import("git_worktree_info.zig").gitWorktreeInfoHandler;
pub const gitPrCreateHandler = @import("git_pr_create.zig").gitPrCreateHandler;

// Queue messages handlers
pub const queueMessagesGetHandler = @import("queue_messages_get.zig").queueMessagesGetHandler;

// Design-mode HTTP handlers (item_type='design') — v6 of the
// design-mode redesign. See
// docs/superpowers/plans/2026-07-08-design-mode-redesign.md
// (Chunk 3) for the full route table.
pub const designPagesListHandler = @import("design_pages_list.zig").designPagesListHandler;
pub const designPagesCreateHandler = @import("design_pages_create.zig").designPagesCreateHandler;
pub const designPagesGetHandler = @import("design_pages_get.zig").designPagesGetHandler;
pub const designElementsCreateHandler = @import("design_elements_create.zig").designElementsCreateHandler;
pub const designElementsUpdateHandler = @import("design_elements_update.zig").designElementsUpdateHandler;
pub const designElementsDeleteHandler = @import("design_elements_delete.zig").designElementsDeleteHandler;
pub const designElementsHtmlGetHandler = @import("design_elements_html_get.zig").designElementsHtmlGetHandler;
pub const designElementsHtmlUpdateHandler = @import("design_elements_html_update.zig").designElementsHtmlUpdateHandler;
pub const designElementsGeometryUpdateHandler = @import("design_elements_geometry_update.zig").designElementsGeometryUpdateHandler;

// Session to client IDs monitoring
pub const sessionToClientIdsHandler = @import("session_to_client_ids.zig").sessionToClientIdsHandler;

// Debug/inspection endpoint — returns the rendered system prompt for a
// session. See `system_prompt_get.zig` for the full contract.
pub const systemPromptGetHandler = @import("system_prompt_get.zig").systemPromptGetHandler;

// Nalar config handlers
pub const nalarConfigGetHandler = @import("nalar_config_get.zig").nalarConfigGetHandler;
pub const nalarConfigPutHandler = @import("nalar_config_put.zig").nalarConfigPutHandler;
pub const nalarConfigProfileDeleteHandler = @import("nalar_config_profile_delete.zig").nalarConfigProfileDeleteHandler;
// Use-case + domain types live in the same file as the handler. The
// handler is a thin orchestrator over the use-case; both are scoped
// under `nalarcore.http_handlers.*` (the convention for handler
// internals — see `nalar_config_profile_delete_test.zig`'s header).
pub const removeProfileFromConfig = @import("nalar_config_profile_delete.zig").removeProfileFromConfig;
pub const NalarConfigJsonForDelete = @import("nalar_config_profile_delete.zig").NalarConfigJsonForDelete;
// `ConfigInput` is the wire format for `PUT /api/config/nalar`. It is
// `pub` so the test file can re-parse the same body the handler would
// and lock in the parse-step tolerance (the on-disk object map vs the
// granular array-of-changes shape). Exposed alongside `parseConfigInput`
// for the same reason.
pub const ConfigInput = @import("nalar_config_put.zig").ConfigInput;
pub const parseConfigInput = @import("nalar_config_put.zig").parseConfigInput;

// OS notification test handler — fires a real OS notification so the
// user can verify their system can display them without running a
// full LLM stream. See /docs/superpowers/plans/2026-01-15-llm-completion-notification.md
pub const notifyTestHandler = @import("notify_test.zig").notifyTestHandler;

// Frontend error log handler — persists window.error /
// unhandledrejection / console.error / console.warn events to the
// `logs` table. See docs/plans/2026-07-17-frontend-error-logs-design.md.
pub const frontendLogPostHandler = @import("frontend_log_post.zig").frontendLogPostHandler;

// =============================================================================
// Shared Types & Helpers
// =============================================================================

/// Response format types
pub const ResponseFormat = enum { json, xml };

/// Determine response format from Accept header or query param
pub fn getResponseFormat(req: gserverz.HttpRequest) ResponseFormat {
    // First check Accept header (higher priority)
    if (req.header("accept")) |accept| {
        if (std.mem.indexOf(u8, accept, "text/xml") != null or
            std.mem.indexOf(u8, accept, "application/xml") != null)
        {
            return .xml;
        }
        if (std.mem.indexOf(u8, accept, "application/json") != null) {
            return .json;
        }
    }

    // Fallback to query parameter
    const query = req.query() catch return .json;
    const format_param = query.get("format") orelse return .json;

    if (std.mem.eql(u8, format_param, "xml")) {
        return .xml;
    }
    return .json;
}

/// Build error response based on format
pub fn buildErrorResponse(allocator: std.mem.Allocator, format: ResponseFormat, error_msg: []const u8) ![]u8 {
    if (format == .xml) {
        return std.fmt.allocPrint(allocator, "<error>{s}</error>", .{error_msg});
    } else {
        return http_response.makeErrorResponse(allocator, .{ .@"error" = error_msg });
    }
}

/// SSE stream context for persistent connections
pub const SseStreamCtx = struct {
    server: *nalarcore.gserverz.GinwaServer,
    session_id: []const u8,
};
