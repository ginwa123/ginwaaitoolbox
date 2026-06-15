//! HTTP Handlers module - one file per endpoint for better organization
//!
//! This module exports all HTTP handlers used by the TUI HTTP server.
//! Each handler is in its own file for maintainability.

const std = @import("std");
const root_mod = @import("nalarcore");
const gserverz = root_mod.gserverz;
const nalarcore = root_mod;
const sqlite = nalarcore.sqlite;
const ai_workflow = nalarcore.ai_workflow;
const logger = nalarcore.logger;

const config = nalarcore.config;
pub const http_response = nalarcore.http_response;

// =============================================================================
// Re-exports
// =============================================================================

// Re-export all handlers
pub const corsPreflightHandler = @import("cors.zig").corsPreflightHandler;
pub const llmHistorySSE = @import("llm_history_sse.zig").llmHistorySSE;
pub const sessionsStreamHandler = @import("sessions_sse.zig").sessionsStreamHandler;
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
pub const tasksListHandler = @import("tasks_list.zig").tasksListHandler;
pub const tasksCreateHandler = @import("task_create.zig").tasksCreateHandler;
pub const tasksUpdateHandler = @import("task_update.zig").tasksUpdateHandler;
pub const tasksUpdateByIdHandler = @import("task_update.zig").tasksUpdateByIdHandler;
pub const tasksDeleteHandler = @import("task_delete.zig").tasksDeleteHandler;
pub const routinesRunHandler = @import("routines_run.zig").routinesRunHandler;
pub const routinesListHandler = @import("routines_list.zig").routinesListHandler;

// Worker API handlers
pub const workerGetHandler = @import("worker_get.zig").workerGetHandler;
pub const workerListHandler = @import("worker_list.zig").workerListHandler;
pub const workersStreamHandler = @import("worker_sse.zig").workersStreamHandler;

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

// Git API handlers
pub const gitStatusHandler = @import("git_status.zig").gitStatusHandler;
pub const gitChangesHandler = @import("git_changes.zig").gitChangesHandler;
pub const gitFileDiffHandler = @import("git_file_diff.zig").gitFileDiffHandler;
pub const gitFileReadHandler = @import("git_file_diff.zig").gitFileReadHandler;
pub const gitStageHandler = @import("git_file_stage.zig").gitStageHandler;
pub const gitUnstageHandler = @import("git_file_stage.zig").gitUnstageHandler;

// Queue messages handlers
pub const queueMessagesStreamHandler = @import("queue_messages_sse.zig").queueMessagesStreamHandler;
pub const queueMessagesGetHandler = @import("queue_messages_get.zig").queueMessagesGetHandler;

// Session to client IDs monitoring
pub const sessionToClientIdsHandler = @import("session_to_client_ids.zig").sessionToClientIdsHandler;

// Nalar config handlers
pub const nalarConfigGetHandler = @import("nalar_config_get.zig").nalarConfigGetHandler;
pub const nalarConfigPutHandler = @import("nalar_config_put.zig").nalarConfigPutHandler;
pub const nalarConfigProfileDeleteHandler = @import("nalar_config_profile_delete.zig").nalarConfigProfileDeleteHandler;
pub const removeProfileFromConfig = @import("nalar_config_profile_delete.zig").removeProfileFromConfig;
pub const NalarConfigJsonForDelete = @import("nalar_config_profile_delete.zig").NalarConfigJsonForDelete;

// OS notification test handler — fires a real OS notification so the
// user can verify their system can display them without running a
// full LLM stream. See /docs/superpowers/plans/2026-01-15-llm-completion-notification.md
pub const notifyTestHandler = @import("notify_test.zig").notifyTestHandler;

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
