//! HTTP Handlers module - one file per endpoint for better organization
//!
//! This module exports all HTTP handlers used by the TUI HTTP server.
//! Each handler is in its own file for maintainability.

const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const nalarcore = root_mod;
const sqlite = nalarcore.sqlite;
const ai_workflow = nalarcore.ai_workflow;
const logger = nalarcore.logger;

const config = nalarcore.config;
const http_response = nalarcore.http_response;


const httpz = http_server.httpz;
const process = nalarcore.helpers.process;

// =============================================================================
// Re-exports
// =============================================================================

pub const MessageHandler = http_server.MessageHandler;
pub const SessionHandler = http_server.SessionHandler;

// Re-export all handlers
pub const corsPreflightHandler = @import("cors.zig").corsPreflightHandler;
pub const streamHandler = @import("stream.zig").streamHandler;
pub const sessionCreateHandler = @import("session_create.zig").session_create_handler;
pub const sessionListHandler = @import("session_list.zig").session_list_handler;
pub const session_get_handler = @import("session_get.zig").session_get_handler;
pub const session_exist_handler = @import("session_exist.zig").session_exist_handler;
pub const session_message_handler = @import("session_message.zig").session_message_handler;
pub const getLatestSessionByDirHandler = @import("session_latest.zig").session_latest_handler;
pub const sseDisconnectHandler = @import("sse_disconnect.zig").sseDisconnectHandler;
pub const ping_handler = @import("ping.zig").ping_handler;
pub const llmRunHandler = @import("llm_run.zig").llmRunHandler;
pub const sessionCancelHandler = @import("session_cancel.zig").sessionCancelHandler;
pub const sessionCompactHandler = @import("session_compact.zig").sessionCompactHandler;
pub const sessionQueueDeleteHandler = @import("session_queue_delete.zig").sessionQueueDeleteHandler;
pub const sessionQueueGetHandler = @import("session_queue_get.zig").sessionQueueGetHandler;
pub const systemFolderHandler = @import("system_folder.zig").system_folder_handler;
pub const healthHandler = @import("health.zig").healthHandler;

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
pub const worker_create_handler = @import("worker_create.zig").worker_create_handler;
pub const worker_get_handler = @import("worker_get.zig").worker_get_handler;
pub const workerListHandler = @import("worker_list.zig").workerListHandler;
pub const worker_list_handler = @import("worker_list.zig").workerListHandler;
pub const worker_cancel_handler = @import("worker_cancel.zig").worker_cancel_handler;

// Session stream handler
pub const sessionStreamHandler = @import("session_stream.zig").sessionStreamHandler;
pub const broadcastSessionCreated = @import("session_stream.zig").broadcastSessionCreated;

// =============================================================================
// Shared Types & Helpers
// =============================================================================

/// Response format types
pub const ResponseFormat = enum { json, xml };

/// Workflow arguments for async LLM execution
pub const WorkflowArgs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    sqlite_db: *sqlite.SqliteBackend,
    logger: *logger.Logger,
    llm_config: *const config.LlmConfig,
    session_id: []u8,
    message: []u8,
    cwd: []u8,
    body: []const u8 = "",
    allowed_tools: []const u8 = "", // empty string = no tools allowed, "all" = all tools allowed, comma-separated list = specific tools
    environment: ?*const std.process.Environ.Map,
};

/// Handler arguments for async message handling
pub const HandlerArgs = struct {
    allocator: std.mem.Allocator,
    body: []const u8,
    handler: MessageHandler,
    ctx: ?*anyopaque,
};

/// Hex digits for session ID generation
const hexDigits = process.hex_digits;

/// Cross-platform process ID getter
/// Returns the current process ID in a cross-platform compatible way
/// Uses helper from process.zig for cross-platform support
const getCurrentProcessId = process.getCurrentProcessId;

/// Generate a unique session ID using timestamp and random suffix
pub fn generateSessionId(self: *http_server.HttpServer.ServerHandler, allocator: std.mem.Allocator) ![]u8 {
    const ts = std.Io.Clock.now(.real, self.io);
    const timestamp: i64 = ts.toSeconds();
    const pid = getCurrentProcessId();
    // Use timestamp + PID + pointer for pseudo-random entropy
    const entropy: u64 = @intFromPtr(self) ^ (@as(u64, @intCast(pid)) << 32) ^ @as(u64, @intCast(timestamp));
    var random_bytes: [8]u8 = undefined;
    @as(*u64, @ptrCast(@alignCast(&random_bytes))).* = entropy;

    // Convert random bytes to hex string
    var hex_chars: [16]u8 = undefined;
    for (random_bytes, 0..) |b, i| {
        hex_chars[i * 2] = hexDigits[b >> 4];
        hex_chars[i * 2 + 1] = hexDigits[b & 0xF];
    }

    return std.fmt.allocPrint(allocator, "sess_{d}_{s}", .{ timestamp, hex_chars });
}

/// Determine response format from Accept header or query param
pub fn getResponseFormat(req: *httpz.Request) ResponseFormat {
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
    server: *http_server.HttpServer,
    session_id: []const u8,
};
