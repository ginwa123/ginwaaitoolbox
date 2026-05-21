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
const http_response = nalarcore.http_response;

// =============================================================================
// Re-exports
// =============================================================================

// Re-export all handlers
pub const corsPreflightHandler = @import("cors.zig").corsPreflightHandler;
pub const streamHandler = @import("stream.zig").streamHandler;
pub const sessionsStreamHandler = @import("sessions_sse.zig").sessionsStreamHandler;
pub const sessionCreateHandler = @import("session_create.zig").sessionCreateHandler;
pub const sessionListHandler = @import("session_list.zig").session_list_handler;
pub const sessionStopHandler = @import("session_stop.zig").sessionStopHandler;
pub const session_get_handler = @import("session_get.zig").session_get_handler;
pub const session_exist_handler = @import("session_exist.zig").session_exist_handler;
pub const session_message_handler = @import("session_message.zig").session_message_handler;
pub const getLatestSessionByDirHandler = @import("session_latest.zig").session_latest_handler;
pub const sseDisconnectHandler = @import("sse_disconnect.zig").sseDisconnectHandler;
pub const ping_handler = @import("ping.zig").ping_handler;
pub const sessionCompactHandler = @import("session_compact.zig").sessionCompactHandler;
pub const systemFolderHandler = @import("system_folder.zig").system_folder_handler;
pub const healthHandler = @import("health.zig").healthHandler;
pub const shutdownHandler = @import("shutdown.zig").shutdownHandler;

// Workspace handlers (stub implementations for desktop app compatibility)
pub const workspacesListHandler = @import("workspaces_list.zig").workspacesListHandler;
pub const workspacesCreateHandler = @import("workspaces_create.zig").workspacesCreateHandler;
pub const workspaceGetHandler = @import("workspace_get.zig").workspaceGetHandler;
pub const workspaceUpdateHandler = @import("workspace_update.zig").workspaceUpdateHandler;
pub const workspaceDeleteHandler = @import("workspace_delete.zig").workspaceDeleteHandler;
pub const workspaceItemCreateHandler = @import("workspace_item_create.zig").workspaceItemCreateHandler;
pub const workspaceItemDeleteHandler = @import("workspace_item_delete.zig").workspaceItemDeleteHandler;
pub const workspaceItemsCreateHandler = @import("workspace_items_create.zig").workspaceItemsCreateHandler;
pub const workspaceItemsListHandler = @import("workspace_items_get.zig").workspaceItemsListHandler;
pub const workspaceItemsGetHandler = @import("workspace_items_get.zig").workspaceItemsGetHandler;
pub const workspaceItemsUpdateHandler = @import("workspace_items_update.zig").workspaceItemsUpdateHandler;
pub const workspaceItemsDeleteHandler = @import("workspace_items_delete.zig").workspaceItemsDeleteHandler;
pub const tasksListHandler = @import("tasks_list.zig").tasksListHandler;
pub const tasksCreateHandler = @import("tasks_create.zig").tasksCreateHandler;
pub const tasksUpdateHandler = @import("tasks_update.zig").tasksUpdateHandler;
pub const tasksUpdateByIdHandler = @import("tasks_update.zig").tasksUpdateByIdHandler;
pub const tasksDeleteHandler = @import("tasks_delete.zig").tasksDeleteHandler;

// Worker API handlers
pub const worker_get_handler = @import("worker_get.zig").worker_get_handler;
pub const workerListHandler = @import("worker_list.zig").workerListHandler;
pub const worker_list_handler = @import("worker_list.zig").workerListHandler;

// Skills API handlers
pub const skillsListHandler = @import("skills_list.zig").skillsListHandler;
pub const skillDetailHandler = @import("skill_detail.zig").skillDetailHandler;
pub const skillDeleteHandler = @import("skill_delete.zig").skillDeleteHandler;

// Git API handlers
pub const gitStatusHandler = @import("git_status.zig").gitStatusHandler;
pub const gitChangesHandler = @import("git_changes.zig").gitChangesHandler;
pub const gitFileDiffHandler = @import("git_file_diff.zig").gitFileDiffHandler;
pub const gitFileReadHandler = @import("git_file_diff.zig").gitFileReadHandler;

// Queue messages handlers
pub const queueMessagesStreamHandler = @import("queue_messages_sse.zig").queueMessagesStreamHandler;
pub const queueMessagesGetHandler = @import("queue_messages_get.zig").queueMessagesGetHandler;

// Session to client IDs monitoring
pub const sessionToClientIdsHandler = @import("session_to_client_ids.zig").sessionToClientIdsHandler;

// Nalar config handlers
pub const nalarConfigGetHandler = @import("nalar_config_get.zig").nalarConfigGetHandler;
pub const nalarConfigPutHandler = @import("nalar_config_put.zig").nalarConfigPutHandler;

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
